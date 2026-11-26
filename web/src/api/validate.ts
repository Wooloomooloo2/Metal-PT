// JSON shape and required fields of an upload (spec §4.C.1–2). Shape failures name the file and field; field
// failures name what the user has to fill in.
import { MIN_APP_VERSION } from "../config.ts";
import type { SummaryJson } from "../lib/recheck.ts";
import type { RunGraphics, RunJson } from "../lib/run-json.ts";
import { ISO } from "./auth.ts";
import { ApiError } from "./errors.ts";

type Obj = Record<string, unknown>;

const isObj = (v: unknown): v is Obj => typeof v === "object" && v !== null && !Array.isArray(v);
const isNum = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v);
const optional = (v: unknown, ok: (x: unknown) => boolean) => v === undefined || v === null || ok(v);
const isStr = (v: unknown): v is string => typeof v === "string";

function shapeError(file: string, field: string): ApiError {
  return new ApiError(422, "bad_json", `${file} is not in the expected form (${field}). Please update Metal-PT.`);
}

function parseJSON(file: string, text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    throw new ApiError(422, "bad_json", `${file} could not be read. Please update Metal-PT.`);
  }
}

export const GPU_CORES = [1, 256] as const;
export const MEMORY_GB = [1, 1024] as const;

/** RAM in GB within 1–1024, rounded; else null (shown as unknown, never a reason to refuse). */
export function boundedMemoryGB(v: number): number | null {
  return v >= MEMORY_GB[0] && v <= MEMORY_GB[1] ? Math.round(v) : null;
}

/** run.json: the types of every field the site reads (unknown fields are ignored). */
export function parseRunJson(text: string): RunJson {
  const f = "run.json";
  const r = parseJSON(f, text);
  if (!isObj(r)) throw shapeError(f, "top level");
  if (!isNum(r.schema)) throw shapeError(f, "schema");
  if (r.schema !== 1) {
    throw new ApiError(422, "unsupported_schema", "This run was recorded in a format metal-pt.com does not know yet. Please update Metal-PT.");
  }
  if (!optional(r.appVersion, isStr)) throw shapeError(f, "appVersion");
  const m = r.machine;
  if (!isObj(m)) throw shapeError(f, "machine");
  if (!isStr(m.chip) || !isStr(m.modelID) || !isStr(m.osVersion)) throw shapeError(f, "machine");
  if (!isNum(m.memoryGB) || !optional(m.gpuCores, (v) => Number.isInteger(v))) throw shapeError(f, "machine");
  const g = r.game;
  if (!isObj(g) || !isStr(g.exe) || !optional(g.title, isStr) || !optional(g.storeAppID, isStr)) throw shapeError(f, "game");
  if (r.stack !== undefined && r.stack !== null) {
    const s = r.stack;
    if (!isObj(s) || !optional(s.runtime, isStr) || !optional(s.runtimeVersion, isStr)) throw shapeError(f, "stack");
    if (!optional(s.graphics, (v) => Array.isArray(v) && v.every(isStr))) throw shapeError(f, "stack.graphics");
  }
  if (r.settings !== undefined && r.settings !== null) {
    const s = r.settings;
    if (!isObj(s) || !optional(s.powerMode, isStr) || !optional(s.onACAtStart, (v) => typeof v === "boolean")) {
      throw shapeError(f, "settings");
    }
  }
  if (!optional(r.graphics, isObj)) throw shapeError(f, "graphics");
  if (r.user !== undefined && r.user !== null) {
    const u = r.user;
    if (!isObj(u)) throw shapeError(f, "user");
    for (const k of ["label", "gameSettings", "notes", "videoURL"]) if (!optional(u[k], isStr)) throw shapeError(f, `user.${k}`);
  }
  if (!isStr(r.start)) throw shapeError(f, "start");
  if (!ISO.test(r.start) || Number.isNaN(Date.parse(r.start))) {
    throw new ApiError(422, "bad_json", "The run's start time in run.json could not be read, so it can't be published. Please update Metal-PT.");
  }
  // Out-of-range GPU core counts put the run in the unknown bucket (published, not counted) rather than refusing it.
  if (m.gpuCores != null && !((m.gpuCores as number) >= GPU_CORES[0] && (m.gpuCores as number) <= GPU_CORES[1])) {
    m.gpuCores = null;
  }
  if (!optional(r.steadyStartS, isNum) || !optional(r.steadyEndS, isNum)) throw shapeError(f, "steady window");
  if (!optional(r.fpsSource, isStr)) throw shapeError(f, "fpsSource");
  return r as unknown as RunJson;
}

const POWER_SOURCES = new Set(["system", "gpuOnly", "none"]);

export function parseSummaryJson(text: string): SummaryJson {
  const f = "summary.json";
  const s = parseJSON(f, text);
  if (!isObj(s)) throw shapeError(f, "top level");
  if (s.summaryVersion !== 1) {
    throw new ApiError(422, "unsupported_schema", "This run's summary is in a format metal-pt.com does not know yet. Please update Metal-PT.");
  }
  for (const k of ["medianFPS", "p1LowFPS", "fpsPerWatt", "meanSystemW", "steadyStartS", "steadyEndS"]) {
    if (!optional(s[k], isNum)) throw shapeError(f, k);
  }
  if (!isStr(s.powerSource) || !POWER_SOURCES.has(s.powerSource)) throw shapeError(f, "powerSource");
  const l = s.limiter;
  if (!optional(l, (v) => isObj(v) && optional(v.primary, isStr) && isStr(v.verdict))) throw shapeError(f, "limiter");
  const n = (v: unknown) => (isNum(v) ? v : null);
  return {
    summaryVersion: 1,
    medianFPS: n(s.medianFPS),
    p1LowFPS: n(s.p1LowFPS),
    fpsPerWatt: n(s.fpsPerWatt),
    meanSystemW: n(s.meanSystemW),
    steadyStartS: n(s.steadyStartS),
    steadyEndS: n(s.steadyEndS),
    limiter: isObj(l) ? { primary: isStr(l.primary) ? l.primary : null, verdict: l.verdict as string } : null,
    powerSource: s.powerSource as SummaryJson["powerSource"],
  };
}

/** "0.10.2" > "0.9" numerically; non-numeric parts count as 0. */
export function versionAtLeast(v: string, min: string): boolean {
  const a = v.split(".").map((p) => parseInt(p, 10) || 0);
  const b = min.split(".").map((p) => parseInt(p, 10) || 0);
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    const x = a[i] ?? 0, y = b[i] ?? 0;
    if (x !== y) return x > y;
  }
  return true;
}

const PRESETS = new Set(["low", "medium", "high", "veryHigh", "ultra", "custom"]);
const UPSCALERS = new Set(["off", "metalfx", "fsr", "xess", "dlss", "other"]);
const MODES = new Set(["quality", "balanced", "performance", "ultraPerformance", "native"]);
const isSide = (v: unknown) => Number.isInteger(v) && (v as number) >= 160 && (v as number) <= 16384;

/** The graphics settings with unknown values dropped (as the app decodes them), and what is missing. */
export function graphicsOf(g: RunGraphics | null | undefined): { graphics: RunGraphics; missing: string[] } {
  const x = (g ?? {}) as Obj;
  const graphics: RunGraphics = {
    preset: isStr(x.preset) && PRESETS.has(x.preset) ? (x.preset as RunGraphics["preset"]) : null,
    width: isSide(x.width) ? (x.width as number) : null,
    height: isSide(x.height) ? (x.height as number) : null,
    upscaler: isStr(x.upscaler) && UPSCALERS.has(x.upscaler) ? (x.upscaler as RunGraphics["upscaler"]) : null,
    upscalerMode: isStr(x.upscalerMode) && MODES.has(x.upscalerMode) ? (x.upscalerMode as RunGraphics["upscalerMode"]) : null,
    frameGeneration: typeof x.frameGeneration === "boolean" ? x.frameGeneration : null,
  };
  // As the app's `Graphics.isComplete`: a mode only when an upscaler is on.
  if (graphics.upscaler === "off") graphics.upscalerMode = null;
  const missing: string[] = [];
  if (graphics.preset === null) missing.push("preset");
  if (graphics.width === null || graphics.height === null) missing.push("resolution");
  if (graphics.upscaler === null) missing.push("upscaler");
  else if (graphics.upscaler !== "off" && graphics.upscalerMode === null) missing.push("upscaler mode");
  if (graphics.frameGeneration === null) missing.push("frame generation");
  return { graphics, missing };
}

/** Required fields (spec §4.C.2), except the steady seconds, which come from the re-check. */
export function requireFields(run: RunJson): RunGraphics {
  if (!versionAtLeast(run.appVersion ?? "0", MIN_APP_VERSION)) {
    throw new ApiError(422, "app_too_old", `Publishing needs Metal-PT ${MIN_APP_VERSION} or later. Please update Metal-PT.`);
  }
  const { graphics, missing } = graphicsOf(run.graphics);
  if (missing.length > 0) {
    throw new ApiError(
      422,
      "missing_graphics",
      `Fill in the graphics settings before publishing: ${missing.join(", ")}.`,
      { missing },
    );
  }
  if ((run.game.title ?? "").trim() === "" && run.game.exe.trim() === "") {
    throw new ApiError(422, "missing_game", "Give the run a game title before publishing.");
  }
  if (run.fpsSource === undefined || run.fpsSource === "none") {
    throw new ApiError(422, "no_fps", "This run has no frame rate (the Metal HUD was not reporting), so it can't be published.");
  }
  return graphics;
}
