// Sanity checks (spec §4.C.4) and the run's power conditions, from the samples parsed once.
import type { Recheck, Samples } from "../lib/recheck.ts";
import { ApiError } from "./errors.ts";

export const FPS_RANGE = [1, 1000] as const;
export const SYSTEM_W_RANGE = [2, 400] as const;
export const MAX_GAP_S = 5;

function implausible(what: string): ApiError {
  return new ApiError(422, "implausible", `This run's numbers look impossible (${what}), so it can't be published.`);
}

/**
 * - the headline median FPS within 1–1000 and the mean system power within 2–400 W (the values that are published;
 *   single rows may legitimately stray, e.g. a loading hitch);
 * - elapsed_s strictly increases over the whole file;
 * - rows ≈ 1 Hz across the steady window: no gap over 5 s, and not more rows than seconds (+25 %).
 */
export function checkSanity(s: Samples, r: Recheck): void {
  const fps = r.medianFPS;
  if (fps === null || fps < FPS_RANGE[0] || fps > FPS_RANGE[1]) {
    throw implausible(`median ${fps === null ? "none" : Math.round(fps * 10) / 10} fps; expected 1–1000`);
  }
  if (r.powerSource === "system" && r.meanW !== null && (r.meanW < SYSTEM_W_RANGE[0] || r.meanW > SYSTEM_W_RANGE[1])) {
    throw implausible(`mean system power ${Math.round(r.meanW * 10) / 10} W; expected 2–400 W`);
  }

  let prev = -Infinity;
  for (let i = 0; i < s.rows; i++) {
    const e = s.elapsed[i];
    if (e == null) continue;
    if (!Number.isFinite(e) || e <= prev) throw implausible("the sample times go backwards");
    prev = e;
  }

  // The steady window's time span, from its first to its last steady row.
  let first = Infinity, last = -Infinity;
  for (const i of r.steady) {
    const e = s.elapsed[i];
    if (e == null) continue;
    if (e < first) first = e;
    if (e > last) last = e;
  }
  if (first === Infinity) return;
  let rows = 0;
  let before: number | null = null;
  for (let i = 0; i < s.rows; i++) {
    const e = s.elapsed[i];
    if (e == null || e < first || e > last) continue;
    if (before !== null && e - before > MAX_GAP_S) throw implausible(`a ${Math.round(e - before)} s gap between samples`);
    before = e;
    rows += 1;
  }
  if (rows > (last - first) * 1.25 + 2) throw implausible("more than one sample per second");
}

/**
 * On AC for the steady window: on battery only when more than half of its rows with an `on_ac` cell say "0" (as
 * the app's `LimiterAnalysis.powerManaged`); with no cells, the run's `onACAtStart`; else null (unknown).
 */
export function onACOf(s: Samples, steady: number[], onACAtStart: boolean | null | undefined): boolean | null {
  let known = 0, battery = 0;
  for (const i of steady) {
    const v = s.onAC[i];
    if (v === "1" || v === "0") {
      known += 1;
      if (v === "0") battery += 1;
    }
  }
  if (known > 0) return !(battery * 2 > known);
  return onACAtStart ?? null;
}
