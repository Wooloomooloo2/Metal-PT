// What the handlers take from the outside world, injectable for tests (a fixed clock for the fixtures' signed
// timestamps; a stub for YouTube's oEmbed).
import type { Fetch } from "./oembed.ts";

export interface Deps {
  now: () => Date;
  fetch: Fetch;
}

export const defaultDeps: Deps = {
  now: () => new Date(),
  fetch: (input, init) => fetch(input, init),
};
