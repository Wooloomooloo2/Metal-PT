import { Hono } from "hono";

export type Env = {
  DB: D1Database;
  RUNS: R2Bucket;
};

const app = new Hono<{ Bindings: Env }>();

app.get("/healthz", (c) => c.text("ok"));

export default app;
