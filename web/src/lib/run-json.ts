// What the site reads from a run's `run.json` (Swift: `RunInfo`, Sources/MPTCore/Bench/RunInfo.swift, and `Stack`,
// Sources/MPTCore/Bench/StackDetector.swift). Optional fields may be absent or null in older or partial files.

export type Preset = "low" | "medium" | "high" | "veryHigh" | "ultra" | "custom";
export type Upscaler = "off" | "metalfx" | "fsr" | "xess" | "dlss" | "other";
export type UpscalerMode = "quality" | "balanced" | "performance" | "ultraPerformance" | "native";

export interface RunMachine {
  modelID: string;
  chip: string;
  gpuCores?: number | null;
  memoryGB: number;
  osVersion: string;
  osBuild: string;
  gpuMaxMHz?: number | null;
  gpuClockTableMHz?: number[] | null;
}

export interface RunGame {
  /** The recorded app (process name or exe). */
  exe: string;
  /** The user's title; empty means none. */
  title?: string | null;
  /** "steam:<id>" when known. */
  storeAppID?: string | null;
}

export interface RunStack {
  /** "Protium", "CrossOver", "Whisky", "Kegworks", "GPTK", "Wine (unknown)", "native"; absent when unknown. */
  runtime?: string | null;
  runtimeVersion?: string | null;
  wineArch?: string | null;
  translator?: string | null;
  /** Graphics layers, e.g. ["DXMT", "vkd3d"], in detection order. */
  graphics?: string[];
  graphicsVersions?: Record<string, string> | null;
}

export interface RunSettings {
  powerMode?: string | null;
  onACAtStart?: boolean | null;
  displayWidth?: number | null;
  displayHeight?: number | null;
  refreshHz?: number | null;
}

export interface RunGraphics {
  preset?: Preset | null;
  width?: number | null;
  height?: number | null;
  upscaler?: Upscaler | null;
  upscalerMode?: UpscalerMode | null;
  frameGeneration?: boolean | null;
}

export interface RunUser {
  label?: string;
  gameSettings?: string;
  notes?: string;
  videoURL?: string | null;
}

export interface RunJson {
  schema: number;
  appVersion?: string;
  machine: RunMachine;
  game: RunGame;
  stack?: RunStack;
  settings?: RunSettings;
  graphics?: RunGraphics | null;
  user?: RunUser;
  /** ISO-8601. */
  start: string;
  end?: string | null;
  steadyStartS?: number | null;
  steadyEndS?: number | null;
  /** "log", "stderr" or "none". */
  fpsSource?: string;
  warnings?: string[];
}

/** The game's title, else the recorded app (Swift `game.titleText ?? game.exe`). */
export function gameName(run: RunJson): string {
  const t = run.game.title ?? "";
  return t !== "" ? t : run.game.exe;
}
