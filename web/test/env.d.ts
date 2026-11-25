import type { Env } from "../src/index.ts";
import type { D1Migration } from "cloudflare:test";

declare global {
  namespace Cloudflare {
    interface Env {
      DB: D1Database;
      RUNS: R2Bucket;
      TEST_MIGRATIONS: D1Migration[];
    }
  }
}

export type { Env };
