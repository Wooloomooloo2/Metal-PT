import { Hono } from "hono";
import { registerAdmin } from "./admin/routes.tsx";
import { deleteRun } from "./api/delete.ts";
import { handle } from "./api/errors.ts";
import { patchRun } from "./api/patch.ts";
import { publish } from "./api/publish.ts";
import { defaultDeps, type Deps } from "./deps.ts";
import { notFound, registerPages } from "./pages/routes.tsx";

export type Env = {
  DB: D1Database;
  RUNS: R2Bucket;
  /** Cloudflare Access for /admin: the team ("<team>" or "<team>.cloudflareaccess.com") and the application's AUD tag.
   *  Either unset: /admin is a 404. */
  ACCESS_TEAM_DOMAIN?: string;
  ACCESS_AUD?: string;
  /** Turnstile on the report form. Unset: reports are closed. TURNSTILE_DISABLED=1 (tests only) skips the check. */
  TURNSTILE_SITE_KEY?: string;
  TURNSTILE_SECRET?: string;
  TURNSTILE_DISABLED?: string;
};

/** The site; `deps` replaces the clock and outgoing fetch in tests. */
export function createApp(deps: Partial<Deps> = {}) {
  const d: Deps = { ...defaultDeps, ...deps };
  const app = new Hono<{ Bindings: Env }>();

  app.get("/healthz", (c) => c.text("ok"));

  app.post("/api/v1/runs", (c) => handle(() => publish(c.req.raw, c.env, d)));
  app.patch("/api/v1/runs/:id", (c) => handle(() => patchRun(c.req.raw, c.env, d, c.req.param("id"))));
  app.delete("/api/v1/runs/:id", (c) => handle(() => deleteRun(c.req.raw, c.env, d, c.req.param("id"))));

  registerAdmin(app, d, () => notFound());
  registerPages(app, d);
  app.notFound(() => notFound());
  app.onError((err) => {
    console.error(err instanceof Error ? (err.stack ?? err.message) : "page error");
    return new Response("Something went wrong on metal-pt.com. Try again in a minute.", {
      status: 500,
      headers: { "Content-Type": "text/plain; charset=utf-8" },
    });
  });

  return app;
}

export default createApp();
