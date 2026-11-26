// D1 reads for the pages. Pages read rows and the cached group statistics only (never CSVs). Hidden runs (admin
// moderation, banned keys) are left out of every list; `key_id` is never selected for display.
import type { Env } from "../index.ts";
import { isUnknown } from "../lib/keys.ts";

/** The run columns lists and cards need. */
export interface RunRow {
  id: string;
  game_id: number;
  game_slug: string;
  game_title: string;
  published: string;
  recorded: string | null;
  chip: string | null;
  gpu_cores: number | null;
  mac_key: string;
  setup_key: string;
  setup_label: string;
  group_key: string;
  preset: string | null;
  width: number | null;
  height: number | null;
  upscaler: string | null;
  upscaler_mode: string | null;
  frame_gen: string | null;
  median_fps: number | null;
  fps_per_watt: number | null;
  power_source: string | null;
  on_ac: number | null;
  power_mode: string | null;
  limiter_primary: string | null;
  outlier: number;
  label: string | null;
}

export const RUN_COLS = `r.id, r.game_id, g.slug AS game_slug, g.title AS game_title, r.published, r.recorded, r.chip,
  r.gpu_cores, r.mac_key, r.setup_key, r.setup_label, r.group_key, r.preset, r.width, r.height, r.upscaler,
  r.upscaler_mode, r.frame_gen, r.median_fps, r.fps_per_watt, r.power_source, r.on_ac, r.power_mode, r.limiter_primary,
  r.outlier, r.label`;

/** A row of the cached statistics (`groups`). */
export interface GroupRow {
  group_key: string;
  game_id: number;
  mac_key: string;
  setup_key: string;
  runs: number;
  macs: number;
  typical_fps: number | null;
  p25_fps: number | null;
  p75_fps: number | null;
  typical_fpw: number | null;
  outliers: number;
  capped_at: number | null;
}

/** FPS/W shown only for whole-Mac (`system`) power (spec §4.E). */
export function systemFPW(r: { power_source: string | null; fps_per_watt: number | null }): number | null {
  return r.power_source === "system" ? r.fps_per_watt : null;
}

/**
 * Why a run is not in its group's typical / range, or null when it is counted (or would be, once the group has
 * enough runs). `uncappedInGroup`: the group has eligible runs without a frame cap, so capped runs are left out
 * (spec §4.E frame caps); pass false when unknown.
 */
export function notCountedReason(r: RunRow, uncappedInGroup: boolean): string | null {
  if (isUnknown(r.mac_key, r.setup_key)) return "unknown Mac or setup";
  if (r.median_fps === null) return "no FPS";
  if (r.on_ac === 0) return "on battery";
  if (r.power_mode === "low") return "Low Power mode";
  if (r.outlier !== 0) return "outlier";
  if (r.limiter_primary === "frameCap" && uncappedInGroup) return "frame-capped";
  return null;
}

/** Eligible and not capped: such a run in a group means its capped runs are left out. */
export function eligibleUncapped(r: RunRow): boolean {
  return (
    !isUnknown(r.mac_key, r.setup_key) &&
    r.median_fps !== null &&
    r.on_ac !== 0 &&
    r.power_mode !== "low" &&
    r.limiter_primary !== "frameCap"
  );
}

/** Group keys that have at least one eligible uncapped run. */
export function uncappedGroups(runs: RunRow[]): Set<string> {
  const s = new Set<string>();
  for (const r of runs) if (eligibleUncapped(r)) s.add(r.group_key);
  return s;
}

// MARK: - Settings combinations (the game page's pickers)

export interface Combo {
  preset: string;
  res: string;
  up: string;
  fg: string;
}

/** The picker values of a run: `high`, `2560x1440`, `metalfx-quality` / `off`, `on` / `off` ("-" when missing). */
export function comboOf(r: Pick<RunRow, "preset" | "width" | "height" | "upscaler" | "upscaler_mode" | "frame_gen">): Combo {
  const up =
    r.upscaler == null || r.upscaler === ""
      ? "-"
      : r.upscaler === "off"
        ? "off"
        : `${r.upscaler}-${r.upscaler_mode ?? "-"}`;
  return {
    preset: r.preset ?? "-",
    res: r.width != null && r.height != null ? `${r.width}x${r.height}` : "-",
    up,
    fg: r.frame_gen ?? "-",
  };
}

export function comboKey(c: Combo): string {
  return `${c.preset}|${c.res}|${c.up}|${c.fg}`;
}

export function comboQuery(c: Combo): string {
  const p = new URLSearchParams({ preset: c.preset, res: c.res, up: c.up, fg: c.fg });
  return p.toString();
}

// MARK: - Queries

export interface GameRow {
  id: number;
  slug: string;
  title: string;
  steam_id: string | null;
}

export async function gameBySlug(env: Env, slug: string): Promise<GameRow | null> {
  return env.DB.prepare("SELECT id, slug, title, steam_id FROM games WHERE slug = ?").bind(slug).first<GameRow>();
}

/** The most recent visible runs, newest first (optionally of one game). */
export async function recentRuns(env: Env, limit: number, gameId?: number): Promise<RunRow[]> {
  const where = gameId === undefined ? "r.hidden = 0" : "r.hidden = 0 AND r.game_id = ?";
  const stmt = env.DB.prepare(
    `SELECT ${RUN_COLS} FROM runs r JOIN games g ON g.id = r.game_id WHERE ${where} ORDER BY r.published DESC, r.id LIMIT ?`,
  );
  const { results } = await (gameId === undefined ? stmt.bind(limit) : stmt.bind(gameId, limit)).all<RunRow>();
  return results;
}

/** One row per game for the Mac and setup pages: the game's most-run group under `where`, with its statistics. */
export interface GameAtSettings {
  game_slug: string;
  game_title: string;
  group_key: string;
  mac_key: string;
  setup_key: string;
  setup_label: string;
  preset: string | null;
  width: number | null;
  height: number | null;
  upscaler: string | null;
  upscaler_mode: string | null;
  frame_gen: string | null;
  /** Visible runs in this group (the Runs column and the default order). */
  n: number;
  /** Visible runs of this game under `where`, all settings. */
  total: number;
  typical_fps: number | null;
  p25_fps: number | null;
  p75_fps: number | null;
  typical_fpw: number | null;
  counted: number | null;
  capped_at: number | null;
  /** Some run in the group had whole-Mac power. */
  has_system: number;
}

export async function gamesWhere(env: Env, column: "mac_key" | "setup_key", value: string): Promise<GameAtSettings[]> {
  const { results } = await env.DB.prepare(
    `SELECT g.slug AS game_slug, g.title AS game_title, r.group_key, r.mac_key, r.setup_key,
            max(r.setup_label) AS setup_label, r.preset, r.width, r.height, r.upscaler, r.upscaler_mode, r.frame_gen,
            count(*) AS n, max(r.published) AS last,
            max(CASE WHEN r.power_source = 'system' THEN 1 ELSE 0 END) AS has_system,
            gr.typical_fps, gr.p25_fps, gr.p75_fps, gr.typical_fpw, gr.runs AS counted, gr.capped_at
       FROM runs r JOIN games g ON g.id = r.game_id LEFT JOIN "groups" gr ON gr.group_key = r.group_key
      WHERE r.${column} = ? AND r.hidden = 0
      GROUP BY r.group_key`,
  )
    .bind(value)
    .all<GameAtSettings & { last: string }>();
  // Per game: the group with the most runs (ties: the most recent), and the game's total.
  const best = new Map<string, GameAtSettings & { last: string }>();
  const totals = new Map<string, number>();
  for (const r of results) {
    totals.set(r.game_slug, (totals.get(r.game_slug) ?? 0) + r.n);
    const b = best.get(r.game_slug);
    if (b === undefined || r.n > b.n || (r.n === b.n && r.last > b.last)) best.set(r.game_slug, r);
  }
  return [...best.values()].map((r) => ({ ...r, total: totals.get(r.game_slug) ?? r.n }));
}

export type SortKey = "runs" | "fps" | "fpw" | "name";

export function sortGames(rows: GameAtSettings[], sort: SortKey): GameAtSettings[] {
  const byName = (a: GameAtSettings, b: GameAtSettings) => a.game_title.localeCompare(b.game_title);
  const desc = (f: (r: GameAtSettings) => number | null) => (a: GameAtSettings, b: GameAtSettings) => {
    const x = f(a), y = f(b);
    if (x === null && y === null) return byName(a, b);
    if (x === null) return 1;
    if (y === null) return -1;
    return y - x || byName(a, b);
  };
  const sorted = [...rows];
  switch (sort) {
    case "name":
      return sorted.sort(byName);
    case "fps":
      return sorted.sort(desc((r) => r.typical_fps));
    case "fpw":
      return sorted.sort(desc((r) => r.typical_fpw));
    default:
      return sorted.sort((a, b) => b.n - a.n || b.total - a.total || byName(a, b));
  }
}

export function sortKey(v: string | undefined): SortKey {
  return v === "fps" || v === "fpw" || v === "name" ? v : "runs";
}

/** Every Mac key / setup key with visible runs, most runs first (chips and index pages). */
export async function keysWithRuns(
  env: Env,
  column: "mac_key" | "setup_key",
): Promise<{ key: string; label: string; runs: number; games: number }[]> {
  const { results } = await env.DB.prepare(
    `SELECT ${column} AS key, max(setup_label) AS label, count(*) AS runs, count(DISTINCT game_id) AS games
       FROM runs WHERE hidden = 0 GROUP BY ${column} ORDER BY runs DESC, key LIMIT 200`,
  ).all<{ key: string; label: string; runs: number; games: number }>();
  return results;
}
