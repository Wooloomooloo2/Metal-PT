// Re-checks a published run's headline numbers from its samples.csv (spec §4.C.3): a line-for-line port of
// `RunSummary.init` (Sources/MPTCore/Bench/RunSummary.swift, steady-row selection lines 41–90, the power-column
// fallback and `fpsPerWatt`), and of how `SiteSummary` names the power source.
import { parseColumns } from "./csv.ts";
import type { RunJson } from "./run-json.ts";

/** The columns the re-check reads (spec §4.J also lists `on_ac`, read by the upload's sanity checks). */
export const RECHECK_COLUMNS = ["elapsed_s", "fps", "fps_app", "smc_PSTR_w", "gpu_w"] as const;

export type PowerSource = "system" | "gpuOnly" | "none";

export interface Recheck {
  medianFPS: number | null;
  fpsPerWatt: number | null;
  /** Mean of the power column used (`smc_PSTR_w` for system, `gpu_w` for gpuOnly); null for none. */
  meanW: number | null;
  powerSource: PowerSource;
  /** Steady rows (Swift `steadySeconds.count`). */
  steadyRows: number;
  /** Steady rows with an FPS value: rows are 1 Hz, so these are the steady seconds with FPS (spec §4.C.2). */
  steadySeconds: number;
}

/** summary.json (spec §4.A; Swift `SiteSummary`). */
export interface SummaryJson {
  summaryVersion: number;
  medianFPS: number | null;
  p1LowFPS: number | null;
  fpsPerWatt: number | null;
  meanSystemW: number | null;
  steadyStartS: number | null;
  steadyEndS: number | null;
  limiter: { primary: string | null; verdict: string } | null;
  powerSource: PowerSource;
}

const DECIMAL = /^[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?$/;
const SPECIAL = /^[+-]?(?:nan|inf|infinity)$/i;

/**
 * Swift's `Double(String)`: the whole string must be a number (no spaces), "nan"/"inf"/"infinity" allowed (the
 * stats then drop them as non-finite). Hex floats, which Swift also reads, are not accepted: the app never writes
 * them (`CSV.number` is fixed-point).
 */
export function swiftDouble(s: string | undefined): number | null {
  if (s === undefined || s === "") return null;
  if (DECIMAL.test(s)) return Number(s);
  if (SPECIAL.test(s)) {
    const neg = s[0] === "-";
    return /nan/i.test(s) ? NaN : neg ? -Infinity : Infinity;
  }
  return null;
}

/** Swift `RunSummary.median` over an ascending array. */
function median(sorted: number[]): number {
  const n = sorted.length;
  return n % 2 === 1 ? sorted[n >> 1] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2;
}

const ascending = (a: number, b: number) => a - b;

/** Swift: `steady.compactMap { Double(...) }.filter(\.isFinite).sorted()`, then mean (summed in sorted order) and median. */
function columnStats(values: (string | undefined)[], steady: number[]): { mean: number; median: number; count: number } | null {
  const vals: number[] = [];
  for (const i of steady) {
    const v = swiftDouble(values[i]);
    if (v !== null && Number.isFinite(v)) vals.push(v);
  }
  if (vals.length === 0) return null;
  vals.sort(ascending);
  let sum = 0;
  for (const v of vals) sum += v;
  return { mean: sum / vals.length, median: median(vals), count: vals.length };
}

export function recheck(run: RunJson, samples: string): Recheck {
  const cols = parseColumns(samples, [...RECHECK_COLUMNS]);
  const n = cols.elapsed_s.length;
  const indices = Array.from({ length: n }, (_, i) => i);
  const elapsed = (i: number): number | null => swiftDouble(cols.elapsed_s[i]);
  // Swift `fps(i)`: nil for a missing or empty cell, else `Double(s)` (which may itself be nil).
  const fps = (i: number): number | null => swiftDouble(cols.fps[i]);
  const app = (i: number): string | undefined => cols.fps_app[i];

  let steady: number[];
  const end = run.steadyEndS ?? Infinity;
  const start = run.steadyStartS;
  if (start != null && start > 0) {
    steady = indices.filter((i) => {
      const e = elapsed(i);
      return e !== null ? e >= start && e <= end : false;
    });
  } else {
    // No warm-up: trimmed automatically, but never past the recorded end (a sleep ends it early).
    const inWindow = indices.filter((i) => {
      const e = elapsed(i);
      return e !== null ? e <= end : true;
    });
    const withFPS = inWindow.filter((i) => fps(i) !== null);
    if (withFPS.length === 0) {
      steady = inWindow;
    } else {
      const counts = new Map<string, number>();
      for (const i of withFPS) {
        const a = app(i) ?? "";
        if (a !== "") counts.set(a, (counts.get(a) ?? 0) + 1);
      }
      // Most common app; ties broken by name (the smallest name wins) so the result is deterministic.
      let followed: string | null = null;
      let best = -1;
      for (const [a, c] of counts) {
        if (c > best || (c === best && followed !== null && a < followed)) {
          followed = a;
          best = c;
        }
      }
      const candidates = withFPS.filter((i) => followed === null || app(i) === followed);
      let t0: number | null = null;
      for (const i of candidates) {
        const e = elapsed(i);
        if (e !== null) {
          t0 = e;
          break;
        }
      }
      if (t0 !== null) {
        const from = t0 + 10;
        const trimmed = candidates.filter((i) => (elapsed(i) ?? 0) >= from);
        const sorted = trimmed.map(fps).filter((v): v is number => v !== null).sort(ascending);
        if (sorted.length === 0) {
          steady = [];
        } else {
          const med = median(sorted);
          steady = trimmed.filter((i) => (fps(i) ?? 0) <= 2 * med);
        }
      } else {
        steady = candidates;
      }
    }
  }

  const fpsStats = columnStats(cols.fps, steady);
  const system = columnStats(cols.smc_PSTR_w, steady);
  const gpu = system === null ? columnStats(cols.gpu_w, steady) : null;
  const powerSource: PowerSource = system !== null ? "system" : gpu !== null ? "gpuOnly" : "none";
  const power = system ?? gpu;
  const medianFPS = fpsStats?.median ?? null;
  const fpsPerWatt = medianFPS !== null && power !== null && power.mean > 0 ? medianFPS / power.mean : null;

  return {
    medianFPS,
    fpsPerWatt,
    meanW: power?.mean ?? null,
    powerSource,
    steadyRows: steady.length,
    steadySeconds: fpsStats?.count ?? 0,
  };
}

/** Tolerances of spec §4.C.3. */
export const FPS_TOLERANCE = 0.5;
export const RELATIVE_TOLERANCE = 0.02;

function fmt(v: number | null): string {
  return v === null ? "none" : String(Math.round(v * 1000) / 1000);
}

function withinRelative(a: number, b: number): boolean {
  return Math.abs(a - b) <= RELATIVE_TOLERANCE * Math.abs(b);
}

/**
 * Whether summary.json agrees with the re-check from samples.csv: null when it does, else a message naming the
 * first problem (shown to the app as is). Median FPS within 0.5 fps; FPS/W (both power sources) and mean system
 * power (system only) within 2 % of the re-checked value; the power source must be the same.
 */
export function matches(summary: SummaryJson, r: Recheck): string | null {
  const said = (what: string, s: number | null, got: number | null) =>
    `${what} in summary.json (${fmt(s)}) does not match samples.csv (${fmt(got)}).`;

  if (summary.powerSource !== r.powerSource) {
    return `The power source in summary.json (${summary.powerSource}) does not match samples.csv (${r.powerSource}).`;
  }
  const m = summary.medianFPS, rm = r.medianFPS;
  if ((m === null) !== (rm === null) || (m !== null && rm !== null && !(Math.abs(m - rm) <= FPS_TOLERANCE))) {
    return said("The median FPS", m, rm);
  }
  const f = summary.fpsPerWatt, rf = r.fpsPerWatt;
  if ((f === null) !== (rf === null) || (f !== null && rf !== null && !withinRelative(f, rf))) {
    return said("FPS/W", f, rf);
  }
  const w = summary.meanSystemW, rw = r.powerSource === "system" ? r.meanW : null;
  if ((w === null) !== (rw === null) || (w !== null && rw !== null && !withinRelative(w, rw))) {
    return said("The mean system power", w, rw);
  }
  return null;
}
