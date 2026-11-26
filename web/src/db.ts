// D1 access for the API (spec §4.D, §4.E): game matching, key registration, runs, cached group statistics, and the
// hook every successful write ends with.
import { purge } from "./cache.ts";
import type { Env } from "./index.ts";
import { normalizeTitle, slugify } from "./lib/games.ts";
import { isUnknown } from "./lib/keys.ts";
import { capOf, groupStats, type StatRun } from "./lib/stats.ts";

/** ISO-8601 UTC to the second ("2026-11-25T12:00:00Z"), the schema's time format. */
export function isoSeconds(d: Date): string {
  return d.toISOString().replace(/\.\d{3}Z$/, "Z");
}

// MARK: - Run ids

const ID_ALPHABET = "abcdefghijkmnpqrstuvwxyz23456789"; // no 0/o/1/l: easy to read aloud and type
export const RUN_ID = /^[a-z0-9]{6,24}$/;

/** A short random URL-safe id: 10 characters from 32, 50 bits. */
export function newRunID(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(10));
  let s = "";
  for (const b of bytes) s += ID_ALPHABET[b & 31];
  return s;
}

// MARK: - Keys (Macs)

export interface MacRow {
  key_id: string;
  public_key: string;
  banned: number;
}

export async function findMac(env: Env, keyId: string): Promise<MacRow | null> {
  return env.DB.prepare("SELECT key_id, public_key, banned FROM macs WHERE key_id = ?").bind(keyId).first<MacRow>();
}

/** Runs this key published since `since` (the D1 fallback for the rate limit; see the report on Task 3). */
export async function runsSince(env: Env, keyId: string, since: string): Promise<number> {
  const r = await env.DB.prepare("SELECT count(*) AS n FROM runs WHERE key_id = ? AND published > ?")
    .bind(keyId, since)
    .first<{ n: number }>();
  return r?.n ?? 0;
}

export interface BundleRun {
  id: string;
  key_id: string;
  hidden: number;
}

export async function runByBundle(env: Env, sha256: string): Promise<BundleRun | null> {
  return env.DB.prepare("SELECT id, key_id, hidden FROM runs WHERE bundle_sha256 = ?").bind(sha256).first<BundleRun>();
}

// MARK: - Games

export interface GameMatch {
  id: number;
  title: string;
}

/** "steam:1151640" -> "1151640"; anything else null. */
export function steamID(storeAppID: string | null | undefined): string | null {
  const m = /^steam:(\d{1,12})$/.exec(storeAppID ?? "");
  return m ? m[1] : null;
}

/**
 * Spec §4.D: Steam ID first, else the normalised title via `game_aliases`, else a new game. The run's title becomes
 * an alias of the matched game (so a Steam match teaches the site another spelling), and a game matched by title
 * learns the run's Steam ID when it has none.
 */
export async function matchGame(env: Env, title: string, steam: string | null, now: string): Promise<GameMatch> {
  const norm = normalizeTitle(title);
  let game: GameMatch | null = null;
  if (steam !== null) {
    game = await env.DB.prepare("SELECT id, title FROM games WHERE steam_id = ?").bind(steam).first<GameMatch>();
  }
  if (game === null && norm !== "") {
    game = await env.DB.prepare(
      "SELECT g.id AS id, g.title AS title FROM game_aliases a JOIN games g ON g.id = a.game_id WHERE a.alias_norm = ?",
    )
      .bind(norm)
      .first<GameMatch>();
    if (game !== null && steam !== null) {
      await env.DB.prepare("UPDATE games SET steam_id = ? WHERE id = ? AND steam_id IS NULL").bind(steam, game.id).run();
    }
  }
  if (game === null) game = await createGame(env, title, steam, now);
  if (norm !== "") {
    await env.DB.prepare("INSERT OR IGNORE INTO game_aliases (alias_norm, game_id) VALUES (?, ?)").bind(norm, game.id).run();
  }
  return game;
}

async function createGame(env: Env, title: string, steam: string | null, now: string): Promise<GameMatch> {
  // A title with no Latin letters or digits (e.g. all CJK) has no slug of its own.
  const base = slugify(title) || `game-${newRunID().slice(0, 6)}`;
  const taken = await env.DB.prepare("SELECT slug FROM games WHERE slug = ? OR slug LIKE ? ESCAPE '\\'")
    .bind(base, `${base.replace(/[\\%_]/g, "\\$&")}-%`)
    .all<{ slug: string }>();
  const used = new Set(taken.results.map((r) => r.slug));
  let slug = base;
  for (let n = 2; used.has(slug); n++) slug = `${base}-${n}`;
  const row = await env.DB.prepare("INSERT INTO games (slug, title, steam_id, created) VALUES (?, ?, ?, ?) RETURNING id, title")
    .bind(slug, title, steam, now)
    .first<GameMatch>();
  return row!;
}

// MARK: - Groups (spec §4.E)

interface GroupRunRow {
  id: string;
  key_id: string;
  game_id: number;
  mac_key: string;
  setup_key: string;
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
  hidden: number;
}

export function statRun(r: GroupRunRow): StatRun {
  const cap = capOf(r.limiter_primary, r.median_fps);
  return {
    id: r.id,
    keyId: r.key_id,
    fps: r.median_fps ?? 0,
    fpw: r.power_source === "system" ? r.fps_per_watt : null,
    // Unknown (no on_ac cells and no onACAtStart, e.g. a desktop Mac) counts as on AC.
    onAC: r.on_ac !== 0,
    lowPower: r.power_mode === "low",
    capped: cap.capped,
    capFPS: cap.capFPS,
    hidden: r.hidden !== 0,
    unknown: isUnknown(r.mac_key, r.setup_key) || r.median_fps === null,
  };
}

/**
 * Groups recomputed per chunk. Each chunk is exactly one read and one batch of at most 4 statements (reset
 * outliers, upsert every counted group, mark outliers, delete groups with nothing counted), each binding one JSON
 * array (`json_each`), so a chunk costs ≤ 5 D1 statements whatever its size. The admin repair path
 * (`RECOMPUTE_CHUNK`) does one chunk per request.
 */
export const GROUP_CHUNK = 200;
/** D1 statements one `recomputeGroups` chunk costs at most. */
export const STATEMENTS_PER_CHUNK = 5;

function chunks<T>(xs: T[], n: number): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < xs.length; i += n) out.push(xs.slice(i, i + n));
  return out;
}

const GROUP_RUN_COLS = `id, key_id, game_id, mac_key, setup_key, preset, width, height, upscaler, upscaler_mode, frame_gen,
            median_fps, fps_per_watt, power_source, on_ac, power_mode, limiter_primary, hidden, group_key`;

/** The `groups` columns written by the upsert, in the order of each JSON row. */
const GROUP_COLS = [
  "group_key", "game_id", "mac_key", "setup_key", "preset", "width", "height", "upscaler", "upscaler_mode", "frame_gen",
  "runs", "macs", "typical_fps", "p25_fps", "p75_fps", "typical_fpw", "outliers", "capped_at", "updated",
] as const;
const GROUP_UPDATED = ["game_id", "runs", "macs", "typical_fps", "p25_fps", "p75_fps", "typical_fpw", "outliers", "capped_at", "updated"];

/** One statement upserting every row of the bound JSON array (`[[group_key, game_id, …], …]`). */
const UPSERT_GROUPS = `INSERT INTO "groups" (${GROUP_COLS.join(", ")})
  SELECT ${GROUP_COLS.map((_, i) => `json_extract(value, '$[${i}]')`).join(", ")}
  FROM json_each(?1) WHERE true
  ON CONFLICT (group_key) DO UPDATE SET ${GROUP_UPDATED.map((c) => `${c} = excluded.${c}`).join(", ")}`;

/** Recomputes one group (see `recomputeGroups`). */
export async function recomputeGroup(env: Env, groupKey: string, now: string): Promise<void> {
  await recomputeGroups(env, [groupKey], now);
}

/**
 * Recomputes the cached statistics of every group in `groupKeys`: marks outliers on their runs and upserts each
 * `groups` row, or deletes it when no run is counted any more (so a game page never shows a stale typical).
 * Cost: per chunk of `GROUP_CHUNK` groups, one read of their runs and one batch of ≤ 4 statements (D1's
 * per-request query limit on the Free plan makes a per-group statement unsafe for bans and merges).
 */
export async function recomputeGroups(env: Env, groupKeys: string[], now: string): Promise<void> {
  const keys = [...new Set(groupKeys)];
  for (const part of chunks(keys, GROUP_CHUNK)) {
    const partJSON = JSON.stringify(part);
    const { results } = await env.DB.prepare(
      `SELECT ${GROUP_RUN_COLS} FROM runs WHERE group_key IN (SELECT value FROM json_each(?1))`,
    )
      .bind(partJSON)
      .all<GroupRunRow & { group_key: string }>();
    const byGroup = new Map<string, GroupRunRow[]>(part.map((k) => [k, []]));
    for (const r of results) byGroup.get(r.group_key)?.push(r);

    const rows: unknown[][] = [];
    const outliers: string[] = [];
    const gone: string[] = [];
    for (const [groupKey, runs] of byGroup) {
      const s = groupStats(runs.map(statRun));
      outliers.push(...s.outlierIds);
      if (s.counted === 0) {
        gone.push(groupKey);
        continue;
      }
      const g = runs[0];
      rows.push([
        groupKey, g.game_id, g.mac_key, g.setup_key, g.preset, g.width, g.height, g.upscaler, g.upscaler_mode,
        g.frame_gen, s.counted, s.macs, s.typical, s.p25, s.p75, s.typicalFPW, s.outlierIds.length, s.cappedAt, now,
      ]);
    }
    const stmts: D1PreparedStatement[] = [
      env.DB.prepare(
        "UPDATE runs SET outlier = 0 WHERE outlier <> 0 AND group_key IN (SELECT value FROM json_each(?1))",
      ).bind(partJSON),
    ];
    if (rows.length > 0) stmts.push(env.DB.prepare(UPSERT_GROUPS).bind(JSON.stringify(rows)));
    if (outliers.length > 0) {
      stmts.push(
        env.DB.prepare("UPDATE runs SET outlier = 1 WHERE id IN (SELECT value FROM json_each(?1))").bind(JSON.stringify(outliers)),
      );
    }
    if (gone.length > 0) {
      stmts.push(
        env.DB.prepare(`DELETE FROM "groups" WHERE group_key IN (SELECT value FROM json_each(?1))`).bind(JSON.stringify(gone)),
      );
    }
    await env.DB.batch(stmts);
  }
}

// MARK: - After every write

export interface Affected {
  gameIds: number[];
  runIds: string[];
  macKeys: string[];
  setupKeys: string[];
}

/** Where the purge happens: the request's origin and the page cache (null: none). */
export interface PurgeTarget {
  origin: string;
  cache: Cache | null;
}

/** The page paths a write touches (spec §4.F): home, the Mac and setup lists, and the game, run, Mac and setup pages. */
export async function affectedPaths(env: Env, affected: Affected): Promise<string[]> {
  const paths = ["/", "/macs", "/setups"];
  if (affected.gameIds.length > 0) {
    const { results } = await env.DB.prepare(
      `SELECT slug FROM games WHERE id IN (${affected.gameIds.map(() => "?").join(", ")})`,
    )
      .bind(...affected.gameIds)
      .all<{ slug: string }>();
    for (const g of results) paths.push(`/game/${g.slug}`);
  }
  for (const id of affected.runIds) paths.push(`/run/${id}`);
  for (const k of affected.macKeys) paths.push(`/mac/${k}`);
  for (const k of affected.setupKeys) paths.push(`/setup/${k}`);
  return paths;
}

/**
 * Called after every successful POST, PATCH and DELETE with what the write touched: purges those pages from the
 * edge cache (see cache.ts for what is and isn't purged). Never fails the write.
 */
export async function afterWrite(env: Env, affected: Affected, target: PurgeTarget): Promise<void> {
  if (target.cache === null) return;
  try {
    await purge(target.cache, target.origin, await affectedPaths(env, affected));
  } catch {
    console.error("afterWrite: purge failed");
  }
}
