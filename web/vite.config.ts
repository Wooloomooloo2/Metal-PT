// Used by `cf dev`, `cf build` and `cf deploy`; the plugin reads cloudflare.config.ts.
// Tests use vitest.config.ts instead.
import { cloudflare } from "@cloudflare/vite-plugin";
import { defineConfig } from "vite";

export default defineConfig({
  plugins: [cloudflare()],
});
