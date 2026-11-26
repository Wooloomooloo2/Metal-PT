// A seeded site for the page tests and the scratchpad render: games, keys and runs written straight to local D1
// (as the API stores them), then every group recomputed with the API's own code.
import { env } from "cloudflare:test";
import { isoSeconds, recomputeGroup } from "../src/db.ts";
import { normalizeTitle } from "../src/lib/games.ts";
import { groupKey } from "../src/lib/keys.ts";

export async function resetSite(): Promise<void> {
  await env.DB.batch(
    ["reports", "runs", '"groups"', "game_aliases", "games", "macs"].map((t) => env.DB.prepare(`DELETE FROM ${t}`)),
  );
  const objects = (await env.RUNS.list()).objects.map((o) => o.key);
  if (objects.length > 0) await env.RUNS.delete(objects);
}

export async function seedGame(id: number, slug: string, title: string, steam: string | null = null): Promise<number> {
  await env.DB.prepare("INSERT INTO games (id, slug, title, steam_id, created) VALUES (?, ?, ?, ?, ?)")
    .bind(id, slug, title, steam, "2026-11-01T00:00:00Z")
    .run();
  await env.DB.prepare("INSERT INTO game_aliases (alias_norm, game_id) VALUES (?, ?)").bind(normalizeTitle(title), id).run();
  return id;
}

export interface SeedRun {
  id: string;
  game: number;
  key: string;
  chip?: string;
  cores?: number | null;
  mac?: string;
  setup?: string;
  setupLabel?: string;
  runtime?: string | null;
  runtimeVersion?: string | null;
  layers?: string | null;
  preset?: string;
  width?: number;
  height?: number;
  upscaler?: string;
  mode?: string | null;
  fg?: "on" | "off";
  fps: number | null;
  p1?: number | null;
  fpw?: number | null;
  watts?: number | null;
  power?: "system" | "gpuOnly" | "none";
  onAC?: number | null;
  powerMode?: string | null;
  limiter?: string | null;
  verdict?: string | null;
  hidden?: number;
  published?: string;
  notes?: string | null;
  label?: string | null;
  settingsText?: string | null;
  video?: { id: string; title: string; channel: string } | null;
  series?: string | null;
}

let n = 0;

/** A 4-minute run's series: a warm-up from 20 fps, then steady around `fps`, with one gap. */
export function series(fps: number): string {
  const points: [number, number | null][] = [];
  for (let t = 0; t <= 252; t += 4) {
    const f = t < 20 ? 20 + t * ((fps - 20) / 20) : t === 120 ? null : fps + Math.sin(t / 9) * 2;
    points.push([t, f === null ? null : Math.round(f * 10) / 10]);
  }
  return JSON.stringify({ v: 1, steadyStartS: 20, steadyEndS: 240, points });
}

export async function seedRun(r: SeedRun): Promise<string> {
  n += 1;
  const mac = r.mac ?? "m4-max-40";
  const setup = r.setup ?? "native";
  const upscaler = r.upscaler ?? "metalfx";
  const mode = upscaler === "off" ? null : r.mode === undefined ? "quality" : r.mode;
  const preset = r.preset ?? "high";
  const width = r.width ?? 2560, height = r.height ?? 1440;
  const fg = r.fg ?? "off";
  const gk = groupKey({
    gameId: r.game, macKey: mac, setupKey: setup, preset, width, height, upscaler, upscalerMode: mode,
    frameGeneration: fg === "on",
  });
  await env.DB.prepare("INSERT OR IGNORE INTO macs (key_id, public_key, first_seen) VALUES (?, ?, ?)")
    .bind(r.key, `pk-${r.key}`, "2026-11-01T00:00:00Z")
    .run();
  const published = r.published ?? isoSeconds(new Date(Date.parse("2026-11-20T10:00:00Z") + n * 60_000));
  await env.DB.prepare(
    `INSERT INTO runs (id, game_id, key_id, bundle_sha256, published, recorded, app_version, chip, gpu_cores, memory_gb,
       model_id, os_version, mac_key, setup_key, setup_label, group_key, runtime, runtime_version, graphics_layers,
       recorded_app, preset, width, height, upscaler, upscaler_mode, frame_gen, median_fps, p1_low_fps, fps_per_watt,
       mean_system_w, power_source, on_ac, power_mode, limiter_primary, limiter_verdict, steady_s, notes,
       settings_text, label, video_id, video_title, video_channel, fps_series, hidden)
     VALUES (${Array(44).fill("?").join(", ")})`,
  )
    .bind(
      r.id, r.game, r.key, `sha-${r.id}-${n}`, published, "2026-11-19T09:30:00Z", "0.2.0", r.chip ?? "Apple M4 Max",
      r.cores === undefined ? 40 : r.cores, 64, "Mac16,6", "26.1", mac, setup, r.setupLabel ?? "Native", gk,
      r.runtime === undefined ? "native" : r.runtime, r.runtimeVersion ?? null, r.layers ?? null, "Game.exe", preset,
      width, height, upscaler, mode, fg, r.fps, r.p1 ?? null, r.fpw ?? null, r.watts ?? null, r.power ?? "system",
      r.onAC === undefined ? 1 : r.onAC, r.powerMode ?? "automatic", r.limiter ?? "gpu", r.verdict ?? "Mostly GPU", 220,
      r.notes ?? null, r.settingsText ?? null, r.label ?? null, r.video?.id ?? null, r.video?.title ?? null,
      r.video?.channel ?? null, r.series === undefined ? series(r.fps ?? 30) : r.series, r.hidden ?? 0,
    )
    .run();
  return gk;
}

export async function recomputeAll(): Promise<void> {
  const { results } = await env.DB.prepare("SELECT DISTINCT group_key FROM runs").all<{ group_key: string }>();
  for (const g of results) await recomputeGroup(env, g.group_key, "2026-11-25T12:00:00Z");
}

export const EVIL = "<script>alert(1)</script>";

/**
 * The page-test site. Cyberpunk 2077 at High · 1440p · MetalFX Quality · FG off:
 * - M4 Max native: 6 runs from 5 keys (one 20 fps outlier) -> typical 62 (61.5), range 61–64 (60.5–63.5).
 * - M4 Max CrossOver 25 · D3DMetal: one run, 49 fps, 0.39 FPS/W (compare against the 62 fps / 0.52 native run).
 * - M4 (10-core): 2 runs from one key -> "Not enough runs yet (2)".
 * - M2 Max CrossOver: 4 frame-capped runs from 2 keys -> "Capped at 60".
 * - M1 Pro: 3 runs, GPU-only power -> FPS/W "—".
 * - M3 Pro: one run on battery (no group row) -> "Not counted: on battery".
 * - An unknown-setup run; a hidden run.
 * Plus a Medium · 1080p · no upscaler · FG on run, and a game whose title and texts are HTML.
 */
export async function seedSite(): Promise<void> {
  await resetSite();
  await seedGame(1, "cyberpunk-2077", "Cyberpunk 2077", "1091520");
  await seedGame(2, "script-alert-1-script", `${EVIL} Game`);
  // M4 Max native
  await seedRun({ id: "native62aa", game: 1, key: "k1", fps: 62, p1: 51, fpw: 0.52, watts: 119 });
  await seedRun({ id: "native63aa", game: 1, key: "k1", fps: 63, fpw: 0.53, watts: 119 });
  await seedRun({ id: "native60aa", game: 1, key: "k2", fps: 60, fpw: 0.5, watts: 120 });
  await seedRun({ id: "native61aa", game: 1, key: "k3", fps: 61, fpw: 0.51, watts: 120 });
  await seedRun({ id: "native64aa", game: 1, key: "k4", fps: 64, fpw: 0.54, watts: 118 });
  await seedRun({ id: "outlier20a", game: 1, key: "k5", fps: 20, fpw: 0.2, watts: 100 });
  // M4 Max CrossOver
  await seedRun({
    id: "crossover49", game: 1, key: "k1", fps: 49, p1: 38, fpw: 0.39, watts: 126, setup: "crossover-25-d3dmetal",
    setupLabel: "CrossOver 25 · D3DMetal", runtime: "CrossOver", runtimeVersion: "25.1", layers: "D3DMetal",
  });
  // M4 10-core: not enough
  await seedRun({ id: "m4base30a", game: 1, key: "k6", chip: "Apple M4", cores: 10, mac: "m4-10", fps: 30, fpw: 1.1, watts: 27 });
  await seedRun({ id: "m4base31a", game: 1, key: "k6", chip: "Apple M4", cores: 10, mac: "m4-10", fps: 31, fpw: 1.12, watts: 27 });
  // M2 Max CrossOver: capped
  for (const [id, key] of [["cap60aaa", "k7"], ["cap60bbb", "k7"], ["cap60ccc", "k8"], ["cap60ddd", "k8"]] as const) {
    await seedRun({
      id, game: 1, key, chip: "Apple M2 Max", cores: 38, mac: "m2-max-38", fps: 60, fpw: 0.9, watts: 66,
      setup: "crossover-25-d3dmetal", setupLabel: "CrossOver 25 · D3DMetal", runtime: "CrossOver", runtimeVersion: "25.1",
      layers: "D3DMetal", limiter: "frameCap", verdict: "Mostly a frame cap",
    });
  }
  // M1 Pro: GPU-only power
  for (const [id, key, f] of [["m1pro24a", "k9", 24], ["m1pro25a", "k10", 25], ["m1pro23a", "k11", 23]] as const) {
    await seedRun({ id, game: 1, key, chip: "Apple M1 Pro", cores: 16, mac: "m1-pro-16", fps: f, fpw: 4.2, power: "gpuOnly" });
  }
  // M3 Pro on battery
  await seedRun({ id: "battery35a", game: 1, key: "k12", chip: "Apple M3 Pro", cores: 18, mac: "m3-pro-18", fps: 35, fpw: 0.73, watts: 48, onAC: 0 });
  // Unknown setup, hidden
  await seedRun({ id: "unknown40a", game: 1, key: "k13", fps: 40, setup: "unknown", setupLabel: "Unknown setup", runtime: null });
  await seedRun({ id: "hidden99aa", game: 1, key: "k14", fps: 99, hidden: 1, label: "HIDDEN RUN" });
  // Another combination
  await seedRun({ id: "medium90aa", game: 1, key: "k2", fps: 90, preset: "medium", width: 1920, height: 1080, upscaler: "off", fg: "on" });
  // HTML in every free-text field
  await seedRun({
    id: "evilrun1aa", game: 2, key: "k1", fps: 45, fpw: 0.4, watts: 110, notes: `${EVIL} notes`,
    label: `<img src=x onerror=alert(2)> label`, settingsText: `${EVIL} settings`,
    video: { id: "dQw4w9WgXcQ", title: `<b>bold</b> ${EVIL}`, channel: `${EVIL} channel` },
    setup: "native-via-evil", setupLabel: `Native · via ${EVIL}`,
  });
  await recomputeAll();
  await env.RUNS.put("runs/native62aa.zip", new TextEncoder().encode("PK fake zip bytes"));
}
