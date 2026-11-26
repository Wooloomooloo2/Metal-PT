// The run page's FPS chart data (`runs.fps_series`, spec §4.D): at most 300 points, built once at upload from the
// already-parsed samples, so pages never read a CSV.
//
// Stored JSON: `{ "v": 1, "steadyStartS": number|null, "steadyEndS": number|null, "points": [[t, fps|null], …] }`,
// `t` = seconds since the start (the bucket's first elapsed_s), `fps` = the bucket's mean FPS (null when the bucket
// has none), both to 0.1. The steady window lets the chart shade the warm-up.
import type { Samples } from "./recheck.ts";

export const MAX_POINTS = 300;

export interface FPSSeries {
  v: 1;
  steadyStartS: number | null;
  steadyEndS: number | null;
  points: [number, number | null][];
}

const r1 = (x: number) => Math.round(x * 10) / 10;

/** Rows with an elapsed time, in even buckets of consecutive rows (one row per bucket when there are ≤ 300). */
export function fpsSeries(s: Samples, steadyStartS: number | null, steadyEndS: number | null): FPSSeries {
  const rows: number[] = [];
  for (let i = 0; i < s.rows; i++) {
    const e = s.elapsed[i];
    if (e != null && Number.isFinite(e)) rows.push(i);
  }
  const buckets = Math.min(MAX_POINTS, rows.length);
  const points: [number, number | null][] = [];
  for (let b = 0; b < buckets; b++) {
    const from = Math.floor((b * rows.length) / buckets);
    const to = Math.floor(((b + 1) * rows.length) / buckets);
    let sum = 0, n = 0;
    for (let k = from; k < to; k++) {
      const f = s.fps[rows[k]];
      if (f != null && Number.isFinite(f)) {
        sum += f;
        n += 1;
      }
    }
    points.push([r1(s.elapsed[rows[from]]!), n === 0 ? null : r1(sum / n)]);
  }
  return { v: 1, steadyStartS, steadyEndS, points };
}
