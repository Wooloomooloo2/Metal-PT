// Display text for the pages: numbers, dates, settings and Mac names. Pure; every page formats through here so the
// same value reads the same everywhere.

export const DASH = "—";

/** FPS: whole numbers from 10 up (as the mockups), one decimal below. */
export function fps(v: number | null | undefined): string {
  if (v == null || !Number.isFinite(v)) return DASH;
  return Math.abs(v) >= 10 ? String(Math.round(v)) : v.toFixed(1);
}

/** FPS per watt, two decimals. */
export function fpw(v: number | null | undefined): string {
  if (v == null || !Number.isFinite(v)) return DASH;
  return v.toFixed(2);
}

/** Watts, whole. */
export function watts(v: number | null | undefined): string {
  if (v == null || !Number.isFinite(v)) return DASH;
  return `${Math.round(v)} W`;
}

/** Milliseconds per frame from an FPS value, one decimal. */
export function frameMs(fpsValue: number | null | undefined): string {
  if (fpsValue == null || !Number.isFinite(fpsValue) || fpsValue <= 0) return DASH;
  return `${(1000 / fpsValue).toFixed(1)} ms`;
}

/** Whole percent of `value` against `base` ("79"), or null. */
export function percentOf(value: number | null | undefined, base: number | null | undefined): number | null {
  if (value == null || base == null || !Number.isFinite(value) || !Number.isFinite(base) || base <= 0) return null;
  return Math.round((value / base) * 100);
}

/**
 * The app's `CompareReport.efficiencyChange` (Sources/MPTCore/Bench/CompareReport.swift), word for word: "31 % more
 * frames per watt", "24 % fewer frames per watt", "the same frames per watt" (under 0.5 %); null when either is
 * unknown or the baseline ≤ 0.
 */
export function efficiencyChange(value: number | null | undefined, baseline: number | null | undefined): string | null {
  if (value == null || baseline == null || !Number.isFinite(value) || !Number.isFinite(baseline)) return null;
  if (baseline <= 0 || value < 0) return null;
  const pct = Math.round(Math.abs(value / baseline - 1) * 100);
  if (pct === 0) return "the same frames per watt";
  return `${pct} % ${value > baseline ? "more" : "fewer"} frames per watt`;
}

/** The app's `CompareReport.efficiencyPhrase`: "31 % more frames per watt than the baseline", "the same frames per
 * watt as the baseline". */
export function efficiencyPhrase(value: number | null | undefined, baseline: number | null | undefined): string | null {
  const change = efficiencyChange(value, baseline);
  if (change === null) return null;
  return change.startsWith("the same") ? `${change} as the baseline` : `${change} than the baseline`;
}

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

/** "23 Nov 2026" (UTC) from the schema's ISO text; "" when unreadable. */
export function date(iso: string | null | undefined): string {
  const t = Date.parse(iso ?? "");
  if (!Number.isFinite(t)) return "";
  const d = new Date(t);
  return `${d.getUTCDate()} ${MONTHS[d.getUTCMonth()]} ${d.getUTCFullYear()}`;
}

/** "4 min 12 s", "45 s", "1 h 3 min". */
export function duration(seconds: number | null | undefined): string {
  if (seconds == null || !Number.isFinite(seconds) || seconds < 0) return DASH;
  const s = Math.round(seconds);
  if (s < 60) return `${s} s`;
  if (s < 3600) return s % 60 === 0 ? `${s / 60} min` : `${Math.floor(s / 60)} min ${s % 60} s`;
  const m = Math.round(s / 60);
  return m % 60 === 0 ? `${m / 60} h` : `${Math.floor(m / 60)} h ${m % 60} min`;
}

/** "4:12" for chart axes. */
export function clock(seconds: number): string {
  const s = Math.max(0, Math.round(seconds));
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), r = s % 60;
  const mm = h > 0 ? String(m).padStart(2, "0") : String(m);
  return `${h > 0 ? `${h}:` : ""}${mm}:${String(r).padStart(2, "0")}`;
}

export function plural(n: number, one: string, many = `${one}s`): string {
  return `${n} ${n === 1 ? one : many}`;
}

// MARK: - Settings

const PRESETS: Record<string, string> = {
  low: "Low", medium: "Medium", high: "High", veryHigh: "Very high", ultra: "Ultra", custom: "Custom",
};
const UPSCALERS: Record<string, string> = {
  off: "Off", metalfx: "MetalFX", fsr: "FSR", xess: "XeSS", dlss: "DLSS", other: "Other upscaler",
};
const MODES: Record<string, string> = {
  quality: "Quality", balanced: "Balanced", performance: "Performance", ultraPerformance: "Ultra performance",
  native: "Native",
};

export function preset(p: string | null | undefined): string {
  if (p == null || p === "") return DASH;
  return PRESETS[p] ?? p;
}

/** "2560 × 1440". */
export function resolution(w: number | null | undefined, h: number | null | undefined): string {
  if (w == null || h == null) return DASH;
  return `${w} × ${h}`;
}

/** "1440p" for compact lines. */
export function shortResolution(w: number | null | undefined, h: number | null | undefined): string {
  if (w == null || h == null) return DASH;
  return `${h}p`;
}

/** "MetalFX · Quality", "Off". */
export function upscaler(u: string | null | undefined, mode: string | null | undefined): string {
  if (u == null || u === "") return DASH;
  const name = UPSCALERS[u] ?? u;
  if (u === "off" || mode == null || mode === "") return name;
  return `${name} · ${MODES[mode] ?? mode}`;
}

export function frameGen(fg: string | null | undefined): string {
  return fg === "on" ? "Frame gen on" : fg === "off" ? "Frame gen off" : "Frame gen —";
}

/** "High · 1440p · MetalFX Quality" (one line on cards and tables). */
export function settingsLine(r: {
  preset: string | null; width: number | null; height: number | null; upscaler: string | null;
  upscaler_mode: string | null; frame_gen: string | null;
}): string {
  const up = r.upscaler == null ? null : upscaler(r.upscaler, r.upscaler_mode).replace(" · ", " ");
  const parts = [preset(r.preset), shortResolution(r.width, r.height), up === "Off" ? "No upscaler" : up];
  if (r.frame_gen === "on") parts.push("Frame gen");
  return parts.filter((p) => p != null && p !== DASH).join(" · ");
}

// MARK: - Macs and setups

/** "Apple M4 Max" -> "M4 Max". */
export function chipName(chip: string | null | undefined): string {
  const c = (chip ?? "").replace(/^\s*apple\s+/i, "").trim();
  return c === "" ? "Unknown Mac" : c;
}

/** `m4-max-40` -> { chip: "M4 Max", gpu: "40-core GPU" }; `unknown` -> "Unknown Mac". */
export function macName(macKey: string): { chip: string; gpu: string } {
  const m = /^(.*)-(\d+)$/.exec(macKey);
  if (macKey === "unknown" || m === null) return { chip: "Unknown Mac", gpu: "" };
  const chip = m[1]
    .split("-")
    .map((p) => (/^m\d+$/.test(p) ? p.toUpperCase() : p.charAt(0).toUpperCase() + p.slice(1)))
    .join(" ");
  return { chip, gpu: `${m[2]}-core GPU` };
}

/** "M4 Max · 40-core GPU". */
export function macTitle(macKey: string): string {
  const n = macName(macKey);
  return n.gpu === "" ? n.chip : `${n.chip} · ${n.gpu}`;
}

/** "CrossOver 25 · D3DMetal" -> "CrossOver 25" (headings and cards; the full label shows in tables). */
export function setupShort(label: string): string {
  return label.split(" · ")[0] || label;
}

/** Power mode as macOS names it. */
export function powerMode(m: string | null | undefined): string | null {
  if (m == null || m === "") return null;
  if (m === "low") return "Low Power";
  if (m === "high") return "High Power";
  if (m === "automatic") return "Automatic";
  return m;
}

/** "Mains, High Power", "Battery", "Unknown". */
export function powerSourceLine(onAC: number | null, mode: string | null): string {
  const src = onAC === 0 ? "Battery" : onAC === 1 ? "Mains" : "Not recorded";
  const pm = powerMode(mode);
  return pm === null ? src : `${src}, ${pm}`;
}
