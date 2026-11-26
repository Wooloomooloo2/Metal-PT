import { Hono } from "hono";
import { deleteRun } from "./api/delete.ts";
import { handle } from "./api/errors.ts";
import { patchRun } from "./api/patch.ts";
import { publish } from "./api/publish.ts";
import { defaultDeps, type Deps } from "./deps.ts";
import { notFound, registerPages } from "./pages/routes.tsx";

export type Env = {
  DB: D1Database;
  RUNS: R2Bucket;
};

/** The site; `deps` replaces the clock and outgoing fetch in tests. */
export function createApp(deps: Partial<Deps> = {}) {
  const d: Deps = { ...defaultDeps, ...deps };
  const app = new Hono<{ Bindings: Env }>();

  app.get("/healthz", (c) => c.text("ok"));

  app.post("/api/v1/runs", (c) => handle(() => publish(c.req.raw, c.env, d)));
  app.patch("/api/v1/runs/:id", (c) => handle(() => patchRun(c.req.raw, c.env, d, c.req.param("id"))));
  app.delete("/api/v1/runs/:id", (c) => handle(() => deleteRun(c.req.raw, c.env, d, c.req.param("id"))));

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
