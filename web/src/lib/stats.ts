// Group statistics (spec §4.E).

export interface StatRun {
  id: string;
  /** The publishing key: "one Mac counts once" weights by it. */
  keyId: string;
  /** The run's median FPS. */
  fps: number;
  /** FPS/W, only when the run's power source is `system`; else null. */
  fpw: number | null;
  onAC: boolean;
  lowPower: boolean;
  /** The limiter's primary is `frameCap`. */
  capped: boolean;
  capFPS: number | null;
  hidden: boolean;
  /** In the unknown bucket (`mac_key` or `setup_key` unknown). */
  unknown: boolean;
}

export interface GroupStats {
  /** Runs that feed typical / range: eligible, not outliers, and not capped when uncapped runs exist. */
  counted: number;
  /** Distinct keys among the counted runs. */
  macs: number;
  /** Weighted median / 25th / 75th percentile of fps over the counted runs; null unless `enough`. */
  typical: number | null;
  p25: number | null;
  p75: number | null;
  /** Weighted median FPS/W over the counted runs that have it; null unless `enough` or when none has it. */
  typicalFPW: number | null;
  /** Runs outside the Tukey fences (only with ≥ 5 runs in the pool). */
  outlierIds: string[];
  /** "Capped at N" when ≥ 75 % of the eligible runs are capped: the median of their caps, rounded. */
  cappedAt: number | null;
  /** ≥ 3 counted runs from ≥ 2 keys: typical and range may be shown; else "Not enough runs yet (n)". */
  enough: boolean;
}

export interface Weighted {
  value: number;
  weight: number;
}

/** Cumulative weights within this much of the target count as reaching it (1/3 + 1/3 + 1/3 is not exactly 1). */
const EPS = 1e-9;

/**
 * Weighted percentile: the smallest value whose cumulative weight (values ascending) is ≥ q · total weight.
 * (An exact data value, never interpolated; with equal weights q = 0.5 is the lower median.)
 */
export function weightedPercentile(values: Weighted[], q: number): number | null {
  if (values.length === 0) return null;
  const sorted = [...values].sort((a, b) => a.value - b.value);
  let total = 0;
  for (const v of sorted) total += v.weight;
  const target = q * total;
  let cum = 0;
  for (const v of sorted) {
    cum += v.weight;
    if (cum >= target - EPS * Math.max(1, total)) return v.value;
  }
  return sorted[sorted.length - 1].value;
}

/** Each run weighs 1 / (runs from its key in `runs`), so a key's runs together weigh 1. */
function weigh<T extends { keyId: string }>(runs: T[], value: (r: T) => number): Weighted[] {
  const per = new Map<string, number>();
  for (const r of runs) per.set(r.keyId, (per.get(r.keyId) ?? 0) + 1);
  return runs.map((r) => ({ value: value(r), weight: 1 / per.get(r.keyId)! }));
}

function plainMedian(values: number[]): number {
  const s = [...values].sort((a, b) => a - b);
  const n = s.length;
  return n % 2 === 1 ? s[n >> 1] : (s[n / 2 - 1] + s[n / 2]) / 2;
}

/** The limiter's frame-cap verdict for one run: capped at its median FPS, rounded. */
export function capOf(limiterPrimary: string | null | undefined, medianFPS: number | null): { capped: boolean; capFPS: number | null } {
  if (limiterPrimary !== "frameCap") return { capped: false, capFPS: null };
  return { capped: true, capFPS: medianFPS === null ? null : Math.round(medianFPS) };
}

export const MIN_RUNS = 3;
export const MIN_MACS = 2;
export const OUTLIER_MIN_RUNS = 5;
export const CAPPED_SHARE = 0.75;

/**
 * Order of the rules:
 * 1. Eligible = not on battery, not Low Power, not hidden, not in the unknown bucket.
 * 2. Frame caps: if ≥ 75 % of eligible runs are capped, `cappedAt` = median of their caps. The pool for typical /
 *    range is the uncapped eligible runs when there are any, else all eligible runs (all capped).
 * 3. Outliers: with ≥ 5 runs in the pool, runs outside [Q1 − 1.5·IQR, Q3 + 1.5·IQR] (weighted quartiles of fps
 *    over the pool) are outliers. Capped runs left out in step 2 are never marked.
 * 4. Counted = pool − outliers; weights recomputed over the counted runs (and over those with FPS/W for typicalFPW).
 */
export function groupStats(runs: StatRun[]): GroupStats {
  const eligible = runs.filter((r) => r.onAC && !r.lowPower && !r.hidden && !r.unknown);

  const capped = eligible.filter((r) => r.capped);
  const caps = capped.map((r) => r.capFPS).filter((c): c is number => c !== null);
  const cappedAt =
    eligible.length > 0 && capped.length >= CAPPED_SHARE * eligible.length && caps.length > 0
      ? Math.round(plainMedian(caps))
      : null;
  const uncapped = eligible.filter((r) => !r.capped);
  const pool = uncapped.length > 0 ? uncapped : eligible;

  let outlierIds: string[] = [];
  if (pool.length >= OUTLIER_MIN_RUNS) {
    const w = weigh(pool, (r) => r.fps);
    const q1 = weightedPercentile(w, 0.25)!;
    const q3 = weightedPercentile(w, 0.75)!;
    const iqr = q3 - q1;
    const lo = q1 - 1.5 * iqr, hi = q3 + 1.5 * iqr;
    outlierIds = pool.filter((r) => r.fps < lo || r.fps > hi).map((r) => r.id);
  }
  const out = new Set(outlierIds);
  const counted = pool.filter((r) => !out.has(r.id));
  const macs = new Set(counted.map((r) => r.keyId)).size;
  const enough = counted.length >= MIN_RUNS && macs >= MIN_MACS;

  let typical: number | null = null, p25: number | null = null, p75: number | null = null;
  let typicalFPW: number | null = null;
  if (enough) {
    const w = weigh(counted, (r) => r.fps);
    typical = weightedPercentile(w, 0.5);
    p25 = weightedPercentile(w, 0.25);
    p75 = weightedPercentile(w, 0.75);
    const withFPW = counted.filter((r) => r.fpw !== null);
    typicalFPW = weightedPercentile(weigh(withFPW, (r) => r.fpw!), 0.5);
  }
  return { counted: counted.length, macs, typical, p25, p75, typicalFPW, outlierIds, cappedAt, enough };
}
