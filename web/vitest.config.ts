import fs from "node:fs";
import path from "node:path";
import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

// The golden fixtures (test/fixtures/<name>/), read here in Node and handed to the Workers runtime as a binding:
// every file as base64 so the bytes (and so their SHA-256) are exactly the files'.
function readFixtures(): Record<string, Record<string, string>> {
  const root = path.join(import.meta.dirname, "test", "fixtures");
  const out: Record<string, Record<string, string>> = {};
  for (const name of fs.readdirSync(root).sort()) {
    const dir = path.join(root, name);
    if (!fs.statSync(dir).isDirectory()) continue;
    out[name] = {};
    for (const file of fs.readdirSync(dir).sort()) {
      out[name][file] = fs.readFileSync(path.join(dir, file)).toString("base64");
    }
  }
  return out;
}

export default defineConfig(async () => {
  const migrations = await readD1Migrations(path.join(import.meta.dirname, "migrations"));
  return {
    plugins: [
      cloudflareTest({
        // Read the Worker, its entrypoint and bindings from cloudflare.config.ts (mode "test"), run locally.
        config: true,
        miniflare: {
          bindings: { TEST_MIGRATIONS: migrations, FIXTURES: readFixtures() },
        },
      }),
    ],
    test: {
      setupFiles: ["./test/apply-migrations.ts"],
    },
  };
});
