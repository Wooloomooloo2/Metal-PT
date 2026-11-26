// The run page's FPS chart: an SVG string built only from numbers (no text: the axis labels are HTML, since the
// SVG stretches to the width) (the stored `fps_series`, spec §4.D), so it is the
// one piece of markup a page inserts unescaped. Every value written into it passes `Number.isFinite` and is printed
// with `toFixed`; no stored text reaches it.
import { clock, fps as fmtFPS } from "./format.ts";

export interface Series {
  steadyStartS: number | null;
  steadyEndS: number | null;
  points: [number, number | null][];
}

/** The stored JSON (`{ v: 1, steadyStartS, steadyEndS, points }`), checked value by value; null when unusable. */
export function parseSeries(text: string | null | undefined): Series | null {
  if (text == null || text === "") return null;
  let j: unknown;
  try {
    j = JSON.parse(text);
  } catch {
    return null;
  }
  if (typeof j !== "object" || j === null) return null;
  const o = j as Record<string, unknown>;
  if (o.v !== 1 || !Array.isArray(o.points)) return null;
  const num = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? v : null);
  const points: [number, number | null][] = [];
  for (const p of o.points) {
    if (!Array.isArray(p) || p.length !== 2) return null;
    const t = num(p[0]);
    if (t === null) return null;
    points.push([t, num(p[1])]);
  }
  if (points.length === 0) return null;
  return { steadyStartS: num(o.steadyStartS), steadyEndS: num(o.steadyEndS), points };
}

const W = 1000;
const H = 220;
const TOP = 12;
const BOTTOM = 200;

/** A round axis top a little above `max` (10, 20, 30, 60, 90, 120, 150, 240 …). */
export function niceMax(max: number): number {
  if (!(max > 0)) return 10;
  const target = max * 1.1;
  const steps = [10, 20, 30, 40, 60, 90, 120, 150, 180, 240, 300, 360, 480, 600, 1000];
  for (const s of steps) if (s >= target) return s;
  return Math.ceil(target / 100) * 100;
}

export interface Chart {
  /** `<svg …>…</svg>`, numbers only. */
  svg: string;
  /** Axis labels under the chart ("0:00", "1:00", …, end) at their position, percent of the width. */
  ticks: { at: number; label: string }[];
  /** Total time covered, seconds. */
  endS: number;
  /** The top of the FPS axis (the bottom is 0). */
  yMax: number;
}

/** The SVG for `series`, with the warm-up (and any cool-down after the steady window) shaded and the median dashed. */
export function fpsChart(series: Series, median: number | null): Chart {
  const pts = series.points;
  const t0 = pts[0][0];
  const end = Math.max(pts[pts.length - 1][0], t0 + 1);
  const span = end - t0;
  let maxFPS = 0;
  for (const [, f] of pts) if (f !== null && f > maxFPS) maxFPS = f;
  const yMax = niceMax(maxFPS);
  const x = (t: number) => (((t - t0) / span) * W).toFixed(1);
  const y = (f: number) => (BOTTOM - (Math.min(f, yMax) / yMax) * (BOTTOM - TOP)).toFixed(1);

  const parts: string[] = [];
  const shade = (from: number, to: number) => {
    const a = Math.max(from, t0), b = Math.min(to, end);
    if (b > a) parts.push(`<rect x="${x(a)}" y="0" width="${(Number(x(b)) - Number(x(a))).toFixed(1)}" height="${BOTTOM}" fill="#EEF1F5"></rect>`);
  };
  if (series.steadyStartS !== null) shade(t0, series.steadyStartS);
  if (series.steadyEndS !== null) shade(series.steadyEndS, end);

  parts.push(`<line x1="0" y1="${BOTTOM}" x2="${W}" y2="${BOTTOM}" stroke="#D0D5DD" stroke-width="1"></line>`);
  if (median !== null && Number.isFinite(median) && median > 0) {
    parts.push(
      `<line x1="0" y1="${y(median)}" x2="${W}" y2="${y(median)}" stroke="#AFC4F5" stroke-width="1" stroke-dasharray="4 4" vector-effect="non-scaling-stroke"></line>`,
    );
  }
  // A gap (bucket without FPS) breaks the line.
  let run: string[] = [];
  const flush = () => {
    if (run.length === 1) run.push(run[0]);
    if (run.length > 0) {
      parts.push(
        `<polyline fill="none" stroke="#2457D6" stroke-width="2" vector-effect="non-scaling-stroke" points="${run.join(" ")}"></polyline>`,
      );
    }
    run = [];
  };
  for (const [t, f] of pts) {
    if (f === null) flush();
    else run.push(`${x(t)},${y(f)}`);
  }
  flush();

  const label = median !== null ? `FPS over the run, median ${fmtFPS(median)}, axis 0 to ${yMax} fps` : `FPS over the run, axis 0 to ${yMax} fps`;
  const svg =
    `<svg class="chart" viewBox="0 0 ${W} ${H}" preserveAspectRatio="none" role="img" aria-label="${label}">` +
    parts.join("") +
    `</svg>`;

  // Ticks: whole minutes (or 30 s for short runs), at most 6, plus the end.
  const total = end - t0;
  const step = [30, 60, 120, 300, 600, 900, 1800].find((s) => total / s <= 5) ?? 3600;
  const ticks: { at: number; label: string }[] = [];
  for (let s = 0; s < total - step / 3; s += step) ticks.push({ at: (s / total) * 100, label: clock(s) });
  ticks.push({ at: 100, label: clock(total) });
  return { svg, ticks, endS: total, yMax };
}
