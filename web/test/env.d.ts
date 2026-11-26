import type { Env } from "../src/index.ts";
import type { D1Migration } from "cloudflare:test";

declare global {
  namespace Cloudflare {
    interface Env {
      DB: D1Database;
      RUNS: R2Bucket;
      TEST_MIGRATIONS: D1Migration[];
      /** Golden fixtures: name -> file name -> base64 of the file's bytes (vitest.config.ts). */
      FIXTURES: Record<string, Record<string, string>>;
    }
  }
}

export type { Env };
