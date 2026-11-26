// The public, read-only pages (spec §4.F), each cached at the edge for 60 s (cache.ts), plus the stylesheet, the
// small optional script, the run download and the 404 page.
import type { Context, Hono } from "hono";
import { cachedPage } from "../cache.ts";
import { RUN_ID } from "../db.ts";
import type { Deps } from "../deps.ts";
import type { Env } from "../index.ts";
import { compareIds, ComparePage, loadCompare } from "./compare.tsx";
import { sortKey } from "./data.ts";
import { GamePage, loadGame } from "./game.tsx";
import { HomePage, loadHome } from "./home.tsx";
import { loadMac, loadMacs, MacPage, MacsPage } from "./mac.tsx";
import { NotFoundPage } from "./notfound.tsx";
import { PrivacyPage } from "./privacy.tsx";
import { reportForm, submitReport } from "./report.tsx";
import { loadRun, RunPage } from "./run.tsx";
import { loadSearch, SearchPage } from "./search.tsx";
import { loadSetup, loadSetups, SetupPage, SetupsPage } from "./setup.tsx";
import { SITE_CSS, SITE_JS } from "./static.ts";

type C = Context<{ Bindings: Env }>;

const KEY = /^[a-z0-9][a-z0-9-]{0,80}$/;
const SLUG = /^[a-z0-9][a-z0-9-]{0,120}$/;

async function html(node: { toString(): string | Promise<string> }, status = 200): Promise<Response> {
  const body = "<!doctype html>" + (await node.toString());
  return new Response(body, {
    status,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "X-Content-Type-Options": "nosniff",
      "Referrer-Policy": "strict-origin-when-cross-origin",
    },
  });
}

export function notFound(what?: string): Promise<Response> {
  return html(<NotFoundPage what={what} />, 404);
}

/** The page URL as served (for Open Graph and canonical links): origin + path, plus the query when it matters. */
function pageURL(c: C, withQuery = false): string {
  const u = new URL(c.req.url);
  return u.origin + u.pathname + (withQuery ? u.search : "");
}

export function registerPages(app: Hono<{ Bindings: Env }>, d: Deps) {
  const cached = (c: C, render: () => Promise<Response>) =>
    cachedPage(d.cache(), c.req.url, (p) => c.executionCtx.waitUntil(p), render);

  app.get("/static/site.css", () =>
    new Response(SITE_CSS, { headers: { "Content-Type": "text/css; charset=utf-8", "Cache-Control": "public, max-age=86400" } }),
  );
  app.get("/static/site.js", () =>
    new Response(SITE_JS, {
      headers: { "Content-Type": "text/javascript; charset=utf-8", "Cache-Control": "public, max-age=86400" },
    }),
  );

  app.get("/", (c) => cached(c, async () => html(<HomePage d={await loadHome(c.env)} />)));

  app.get("/game/:slug", (c) =>
    cached(c, async () => {
      const slug = c.req.param("slug");
      if (!SLUG.test(slug)) return notFound("No game has this address.");
      const d = await loadGame(c.env, slug, c.req.query(), pageURL(c));
      return d === null ? notFound("No game has this address.") : html(<GamePage d={d} />);
    }),
  );

  app.get("/run/:id", (c) =>
    cached(c, async () => {
      const id = c.req.param("id");
      if (!RUN_ID.test(id)) return notFound("No run has this address.");
      const r = await loadRun(c.env, id);
      return r === null ? notFound("No run has this address.") : html(<RunPage run={r.run} uncapped={r.uncapped} url={pageURL(c)} />);
    }),
  );

  // The uploaded zip, streamed from R2 (not cached here: R2 serves it).
  app.get("/run/:id/download", async (c) => {
    const id = c.req.param("id");
    if (!RUN_ID.test(id)) return notFound("No run has this address.");
    const row = await c.env.DB.prepare(
      "SELECT g.slug AS slug FROM runs r JOIN games g ON g.id = r.game_id WHERE r.id = ? AND r.hidden = 0",
    )
      .bind(id)
      .first<{ slug: string }>();
    if (row === null) return notFound("No run has this address.");
    const obj = await c.env.RUNS.get(`runs/${id}.zip`);
    if (obj === null) return notFound("This run's file is not available.");
    return new Response(obj.body, {
      headers: {
        "Content-Type": "application/zip",
        "Content-Length": String(obj.size),
        // Slug and id are [a-z0-9-] only, so the filename needs no quoting rules beyond the quotes.
        "Content-Disposition": `attachment; filename="${row.slug}-${id}.mptrun.zip"`,
        // Not cached anywhere shared: a run removed by its owner or a moderator must stop downloading at once.
        "Cache-Control": "private, no-cache",
        "X-Content-Type-Options": "nosniff",
      },
    });
  });

  // Report a problem (never cached; Turnstile on the form).
  app.get("/run/:id/report", (c) => reportForm(c.env, c.req.param("id"), () => notFound("No run has this address.")));
  app.post("/run/:id/report", (c) =>
    submitReport(c.req.raw, c.env, d, c.req.param("id"), () => notFound("No run has this address.")),
  );

  app.get("/compare", (c) =>
    cached(c, async () => {
      const d = await loadCompare(c.env, compareIds(c.req.query("runs")), c.req.query("find") ?? "");
      return d === null ? notFound("None of these runs exist.") : html(<ComparePage d={d} />);
    }),
  );

  app.get("/macs", (c) => cached(c, async () => html(<MacsPage macs={await loadMacs(c.env)} />)));
  app.get("/mac/:key", (c) =>
    cached(c, async () => {
      const key = c.req.param("key");
      if (!KEY.test(key)) return notFound("No runs from this Mac.");
      const d = await loadMac(c.env, key, sortKey(c.req.query("sort")));
      return d === null ? notFound("No runs from this Mac.") : html(<MacPage d={d} />);
    }),
  );

  app.get("/setups", (c) => cached(c, async () => html(<SetupsPage setups={await loadSetups(c.env)} />)));
  app.get("/setup/:key", (c) =>
    cached(c, async () => {
      const key = c.req.param("key");
      if (!KEY.test(key)) return notFound("No runs with this setup.");
      const d = await loadSetup(c.env, key, sortKey(c.req.query("sort")));
      return d === null ? notFound("No runs with this setup.") : html(<SetupPage d={d} />);
    }),
  );

  app.get("/search", (c) => cached(c, async () => {
    const d = await loadSearch(c.env, c.req.query("q") ?? "");
    return html(<SearchPage d={d} />);
  }));

  app.get("/privacy", (c) => cached(c, async () => html(<PrivacyPage />)));
}
