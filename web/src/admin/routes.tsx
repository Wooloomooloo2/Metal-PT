// /admin (spec §4.H), behind Cloudflare Access. Without ACCESS_TEAM_DOMAIN and ACCESS_AUD every /admin URL is the
// normal 404 page. With them, each request needs a valid Access JWT (access.ts); writes are POST forms that must
// come from this site (Origin check against CSRF, on top of Access's own cookie scope). Admin pages are never
// cached (no-store) and can't be framed.
import type { Context, Hono, MiddlewareHandler } from "hono";
import { RUN_ID } from "../db.ts";
import type { Deps } from "../deps.ts";
import type { Env } from "../index.ts";
import { accessConfig, verifyAccessJwt, type AccessIdentity } from "./access.ts";
import {
  addAlias,
  AdminError,
  banKey,
  findGame,
  mergeGames,
  recomputeStatistics,
  type RecomputeScope,
  removeAlias,
  removeVideo,
  renameGame,
  resolveRunReports,
  setReportResolved,
  setRunHidden,
  setSteamID,
  unbanKey,
  unlockVideo,
  type WriteContext,
} from "./actions.ts";
import {
  AdminErrorPage,
  AdminGamePage,
  AdminRunPage,
  GamesPage,
  loadAdminGame,
  loadAdminRun,
  loadGames,
  loadQueue,
  QueuePage,
  RecomputePage,
} from "./pages.tsx";

type AdminEnv = { Bindings: Env; Variables: { admin: AccessIdentity } };
type C = Context<AdminEnv>;

const SECURITY_HEADERS: Record<string, string> = {
  "Content-Type": "text/html; charset=utf-8",
  "Cache-Control": "no-store",
  "X-Content-Type-Options": "nosniff",
  "X-Frame-Options": "DENY",
  "Content-Security-Policy": "frame-ancestors 'none'",
  "Referrer-Policy": "same-origin",
};

async function page(node: { toString(): string | Promise<string> }, status = 200): Promise<Response> {
  return new Response("<!doctype html>" + (await node.toString()), { status, headers: SECURITY_HEADERS });
}

function plain(text: string, status: number): Response {
  return new Response(text, { status, headers: { ...SECURITY_HEADERS, "Content-Type": "text/plain; charset=utf-8" } });
}

/** Where an action returns to: an /admin path from the form, else `fallback`. */
function backTo(raw: unknown, fallback: string): string {
  const s = typeof raw === "string" ? raw : "";
  return /^\/admin(?:\/[A-Za-z0-9/_-]*)?(?:\?[A-Za-z0-9=&_-]*)?$/.test(s) ? s : fallback;
}

function withDone(path: string, done: string): string {
  return `${path}${path.includes("?") ? "&" : "?"}done=${done}`;
}

const DONE: Record<string, string> = {
  hidden: "Run hidden.",
  unhidden: "Run shown again.",
  video: "Video link removed and locked: the owner can't add one again.",
  unlocked: "The owner can add a video link again.",
  banned: "Key banned and its runs hidden.",
  unbanned: "Key unbanned.",
  resolved: "Report resolved.",
  reopened: "Report reopened.",
  reports: "All reports on this run resolved.",
  renamed: "Game saved.",
  steam: "Steam app ID saved.",
  alias: "Name added.",
  unalias: "Name removed.",
  merged: "Games merged.",
};

function who(c: C): string | null {
  const a = c.get("admin");
  return a.email ?? a.sub;
}

export function registerAdmin(app: Hono<{ Bindings: Env }>, d: Deps, notFound: () => Promise<Response>) {
  const admin = app as unknown as Hono<AdminEnv>;

  const guard: MiddlewareHandler<AdminEnv> = async (c, next) => {
    const cfg = accessConfig(c.env);
    if (cfg === null) return notFound();
    const id = await verifyAccessJwt(c.req.header("Cf-Access-Jwt-Assertion"), cfg, { fetch: d.fetch, now: d.now() });
    if (id === null) return plain("Sign in through Cloudflare Access to use this page.", 403);
    if (c.req.method !== "GET" && c.req.method !== "HEAD") {
      // CSRF: a write must come from a page on this site.
      const origin = c.req.header("Origin");
      if (origin !== new URL(c.req.url).origin) return plain("This change must be made from the admin pages.", 403);
    }
    c.set("admin", id);
    await next();
  };
  admin.use("/admin", guard);
  admin.use("/admin/*", guard);

  const ctx = (c: C): WriteContext => ({
    env: c.env,
    now: d.now(),
    target: { origin: new URL(c.req.url).origin, cache: d.cache() },
  });
  const notice = (c: C) => DONE[c.req.query("done") ?? ""] ?? null;

  /** Runs `act`; then 303 back with a notice, or the error page for a refusal. */
  async function act(c: C, fallback: string, done: string, f: (form: Record<string, unknown>) => Promise<void>): Promise<Response> {
    const form = (await c.req.parseBody()) as Record<string, unknown>;
    const back = backTo(form.back, fallback);
    try {
      await f(form);
    } catch (e) {
      if (e instanceof AdminError) return page(<AdminErrorPage message={e.message} back={back} who={who(c)} />, 400);
      throw e;
    }
    return c.redirect(withDone(back, done), 303);
  }

  const str = (v: unknown) => (typeof v === "string" ? v : "");

  // MARK: - Pages

  admin.get("/admin", async (c) => {
    const d = await loadQueue(c.env, c.req.query("show") === "resolved");
    return page(<QueuePage d={d} who={who(c)} notice={notice(c)} />);
  });

  // The "Open run" box: an id or a run URL.
  admin.get("/admin/run", (c) => {
    const raw = (c.req.query("id") ?? "").trim();
    const id = /\/run\/([a-z0-9]+)/.exec(raw)?.[1] ?? raw;
    return RUN_ID.test(id) ? c.redirect(`/admin/run/${id}`, 303) : notFound();
  });

  admin.get("/admin/run/:id", async (c) => {
    const id = c.req.param("id");
    const data = RUN_ID.test(id) ? await loadAdminRun(c.env, id) : null;
    return data === null ? notFound() : page(<AdminRunPage d={data} who={who(c)} notice={notice(c)} />);
  });

  admin.get("/admin/games", async (c) => {
    const q = c.req.query("q") ?? "";
    return page(<GamesPage games={await loadGames(c.env, q)} q={q} who={who(c)} />);
  });

  admin.get("/admin/game/:id", async (c) => {
    const id = Number(c.req.param("id"));
    const data = Number.isSafeInteger(id) ? await loadAdminGame(c.env, id) : null;
    return data === null ? notFound() : page(<AdminGamePage d={data} who={who(c)} notice={notice(c)} />);
  });

  // MARK: - Run actions

  const runAction = (path: string, done: string, f: (w: WriteContext, id: string) => Promise<void>) =>
    admin.post(`/admin/run/:id/${path}`, (c) => {
      const id = c.req.param("id");
      if (!RUN_ID.test(id)) return notFound();
      return act(c, `/admin/run/${id}`, done, () => f(ctx(c), id));
    });
  runAction("hide", "hidden", (w, id) => setRunHidden(w, id, true));
  runAction("unhide", "unhidden", (w, id) => setRunHidden(w, id, false));
  runAction("remove-video", "video", removeVideo);
  runAction("unlock-video", "unlocked", unlockVideo);
  runAction("resolve-reports", "reports", (w, id) => resolveRunReports(w.env, id));

  // MARK: - Keys

  admin.post("/admin/key/ban", (c) =>
    act(c, "/admin", "banned", async (form) => {
      await banKey(ctx(c), str(form.key_id));
    }),
  );
  admin.post("/admin/key/unban", (c) =>
    act(c, "/admin", "unbanned", (form) => unbanKey(ctx(c), str(form.key_id), str(form.unhide) === "1")),
  );

  // MARK: - Reports

  for (const [path, resolved, done] of [["resolve", true, "resolved"], ["reopen", false, "reopened"]] as const) {
    admin.post(`/admin/report/:rid/${path}`, (c) => {
      const rid = Number(c.req.param("rid"));
      if (!Number.isSafeInteger(rid)) return notFound();
      return act(c, "/admin", done, () => setReportResolved(c.env, rid, resolved));
    });
  }

  // MARK: - Games

  const gameAction = (path: string, done: string, f: (w: WriteContext, id: number, form: Record<string, unknown>) => Promise<unknown>) =>
    admin.post(`/admin/game/:id/${path}`, (c) => {
      const id = Number(c.req.param("id"));
      if (!Number.isSafeInteger(id)) return notFound();
      return act(c, `/admin/game/${id}`, done, async (form) => {
        await f(ctx(c), id, form);
      });
    });
  gameAction("rename", "renamed", (w, id, f) => renameGame(w, id, str(f.title), str(f.slug)));
  gameAction("steam", "steam", (w, id, f) => setSteamID(w, id, str(f.steam_id)));
  gameAction("alias/add", "alias", (w, id, f) => addAlias(w, id, str(f.alias)));
  gameAction("alias/remove", "unalias", (w, id, f) => removeAlias(w, id, str(f.alias)));

  // Merge returns to the target game (the source is gone).
  admin.post("/admin/game/:id/merge", async (c) => {
    const id = Number(c.req.param("id"));
    if (!Number.isSafeInteger(id)) return notFound();
    const form = (await c.req.parseBody()) as Record<string, unknown>;
    const back = `/admin/game/${id}`;
    try {
      if (str(form.confirm) !== "1") throw new AdminError("Tick “I'm sure” to merge.");
      const target = await findGame(c.env, str(form.target));
      if (target === null) throw new AdminError("No game matches that id, address or URL.");
      await mergeGames(ctx(c), id, target.id);
      return c.redirect(withDone(`/admin/game/${target.id}`, "merged"), 303);
    } catch (e) {
      if (e instanceof AdminError) return page(<AdminErrorPage message={e.message} back={back} who={who(c)} />, 400);
      throw e;
    }
  });

  // MARK: - Recompute statistics (repair path; idempotent, ≤ 200 groups per request)

  admin.post("/admin/recompute", async (c) => {
    const form = (await c.req.parseBody()) as Record<string, unknown>;
    const back = backTo(form.back, "/admin/games");
    const kind = str(form.scope);
    let scope: RecomputeScope | null = null;
    const fields: Record<string, string> = { scope: kind };
    if (kind === "all") scope = { kind: "all" };
    if (kind === "game" && /^\d{1,12}$/.test(str(form.id))) {
      scope = { kind: "game", id: Number(form.id) };
      fields.id = str(form.id);
    }
    if (kind === "key" && str(form.key_id) !== "") {
      scope = { kind: "key", keyId: str(form.key_id) };
      fields.key_id = str(form.key_id);
    }
    try {
      if (scope === null) throw new AdminError("Choose what to recompute.");
      const r = await recomputeStatistics(ctx(c), scope, str(form.after));
      return page(<RecomputePage who={who(c)} done={r.done} left={r.left} last={r.last} fields={fields} back={back} />);
    } catch (e) {
      if (e instanceof AdminError) return page(<AdminErrorPage message={e.message} back={back} who={who(c)} />, 400);
      throw e;
    }
  });

  // Any other /admin URL (after the guard): the 404 page.
  admin.all("/admin/*", () => notFound());
}
