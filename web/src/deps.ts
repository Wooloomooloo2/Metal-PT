// What the handlers take from the outside world, injectable for tests (a fixed clock for the fixtures' signed
// timestamps; a stub for YouTube's oEmbed; the edge cache, or none).
import type { Fetch } from "./oembed.ts";

export interface Deps {
  now: () => Date;
  fetch: Fetch;
  /** The edge cache for HTML pages (spec §4.F), or null for none. */
  cache: () => Cache | null;
}

export const defaultDeps: Deps = {
  now: () => new Date(),
  fetch: (input, init) => fetch(input, init),
  cache: () => (typeof caches === "undefined" ? null : caches.default),
};
