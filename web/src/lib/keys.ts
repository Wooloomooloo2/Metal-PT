// Grouping keys (spec §4.D, §4.E): Mac key, setup key and label, and the group key.
import { normalizeTitle, slugify } from "./games.ts";
import type { RunMachine, RunJson, RunStack } from "./run-json.ts";

export const UNKNOWN = "unknown";

/** Chip + GPU cores, e.g. "Apple M4 Max" + 40 -> `m4-max-40`; `unknown` without GPU cores or a chip. RAM is ignored. */
export function macKey(machine: Pick<RunMachine, "chip"> & { gpuCores?: number | null }): string {
  const cores = machine.gpuCores;
  if (cores == null || !Number.isInteger(cores) || cores <= 0) return UNKNOWN;
  const chip = slugify((machine.chip ?? "").replace(/^\s*apple\s+/i, ""));
  return chip === "" ? UNKNOWN : `${chip}-${cores}`;
}

/** Layers sorted (case-insensitively, then by code unit for a stable order). */
function sortedLayers(stack: RunStack | undefined): string[] {
  return [...(stack?.graphics ?? [])]
    .filter((g) => g !== "")
    .sort((a, b) => {
      const x = a.toLowerCase(), y = b.toLowerCase();
      return x < y ? -1 : x > y ? 1 : a < b ? -1 : a > b ? 1 : 0;
    });
}

/** All detected graphics layers, sorted, joined: the `runs.graphics_layers` column and the label's layer part. */
export function graphicsLayers(stack: RunStack | undefined): string {
  return sortedLayers(stack).join(" + ");
}

/** "25.1.0" -> "25"; null when the version has no leading number. */
function majorVersion(v: string | null | undefined): string | null {
  const m = /^\D*?(\d+)/.exec(v ?? "");
  return m ? m[1] : null;
}

/** The recorded app's name without a trailing `.app` / `.exe`. */
function appName(exe: string): string {
  return exe.replace(/\.(app|exe)$/i, "");
}

type Setup =
  | { kind: "unknown" }
  | { kind: "native"; via: string | null }
  | { kind: "wine"; runtime: string; major: string | null; layers: string[] };

function setup(run: RunJson, title: string): Setup {
  const runtime = run.stack?.runtime;
  if (runtime == null || runtime === "" || runtime === "Wine (unknown)") return { kind: "unknown" };
  if (runtime === "native") {
    // `-via-<app>` only when the recorded app differs from the game (an emulator or launcher), compared as
    // normalised titles so case or punctuation alone is not a different app.
    const app = appName(run.game.exe ?? "");
    const differs = app !== "" && normalizeTitle(app) !== normalizeTitle(title) && slugify(app) !== "";
    return { kind: "native", via: differs ? app : null };
  }
  return { kind: "wine", runtime, major: majorVersion(run.stack?.runtimeVersion), layers: sortedLayers(run.stack) };
}

/**
 * `native` (plus `-via-<recorded app slug>` for a native run whose recorded app is not the game), else runtime +
 * major version + graphics layers (`crossover-25-d3dmetal`; Wine runs never get a via: their exe is the game), else
 * `unknown` (no runtime, or `Wine (unknown)`). `title` is the game's title as matched (else the recorded app).
 */
export function setupKey(run: RunJson, title: string): string {
  const s = setup(run, title);
  switch (s.kind) {
    case "unknown":
      return UNKNOWN;
    case "native":
      return s.via === null ? "native" : `native-via-${slugify(s.via)}`;
    case "wine": {
      const key = [slugify(s.runtime), s.major, ...s.layers.map(slugify)].filter((p) => p !== null && p !== "").join("-");
      return key === "" ? UNKNOWN : key;
    }
  }
}

/** "CrossOver 25 · D3DMetal", "Native · via ARMSX2", "Native", "Unknown setup". */
export function setupLabel(run: RunJson, title: string): string {
  const s = setup(run, title);
  switch (s.kind) {
    case "unknown":
      return "Unknown setup";
    case "native":
      return s.via === null ? "Native" : `Native · via ${s.via}`;
    case "wine": {
      const head = s.major === null ? s.runtime : `${s.runtime} ${s.major}`;
      return s.layers.length === 0 ? head : `${head} · ${s.layers.join(" + ")}`;
    }
  }
}

/** Runs in the unknown bucket are published and visible but never counted in groups (spec §4.D). */
export function isUnknown(macKey: string, setupKey: string): boolean {
  return macKey === UNKNOWN || setupKey === UNKNOWN;
}

export interface GroupParts {
  gameId: number;
  macKey: string;
  setupKey: string;
  preset: string | null | undefined;
  width: number | null | undefined;
  height: number | null | undefined;
  upscaler: string | null | undefined;
  upscalerMode: string | null | undefined;
  frameGeneration: boolean | null | undefined;
}

/**
 * Group = game × Mac key × setup key × preset × resolution × upscaler (+ mode) × frame generation (spec §4.E), e.g.
 * `7|m4-max-40|crossover-25-d3dmetal|high|2560x1440|metalfx-quality|fg-off`. The mode only counts when an upscaler
 * is on. Missing parts are written as "-" (publishing requires them, so this is only for robustness).
 */
export function groupKey(g: GroupParts): string {
  const part = (v: string | number | null | undefined) => (v == null || v === "" ? "-" : String(v));
  const up = g.upscaler == null || g.upscaler === "" ? "-" : g.upscaler === "off" ? "off" : `${g.upscaler}-${part(g.upscalerMode)}`;
  const fg = g.frameGeneration == null ? "fg-" : g.frameGeneration ? "fg-on" : "fg-off";
  return [g.gameId, g.macKey, g.setupKey, part(g.preset), `${part(g.width)}x${part(g.height)}`, up, fg].join("|");
}
