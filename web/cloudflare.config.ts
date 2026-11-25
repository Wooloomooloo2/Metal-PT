// Metal-PT website Worker. Configured for `cf` (no Wrangler file).
//
// Only the staging Worker exists in this plan. Production (metal-pt.com, D1 `metal-pt`, R2 `metal-pt-runs`)
// is created later, only when the user says so; until then a production build or deploy fails here on
// purpose, so `cf deploy` can never auto-provision production resources by accident.
//
// Deploy staging:  cf deploy --mode staging
import { bindings, defineConfig } from "cf/config";

const ACCOUNT_ID = "c064d4ca0b22c682f5910b919c3d022c";

export default defineConfig(({ mode }) => {
  if (mode === "production") {
    throw new Error("Metal-PT production is not set up yet. Use --mode staging.");
  }
  // staging, plus local modes (cf dev: "development", Vitest: "test") which run on local D1/R2.
  return {
    accountId: ACCOUNT_ID,
    worker: {
      name: "metal-pt-staging",
      compatibilityDate: "2026-11-10",
      entrypoint: "./src/index.ts",
      workersDev: true,
      env: {
        DB: bindings.d1({ id: "3c0451a9-1b96-446d-94f8-005aa3f606db", name: "metal-pt-staging" }),
        RUNS: bindings.r2({ name: "metal-pt-runs-staging" }),
      },
    },
  };
});
