// Admin writes (spec §4.H): hide/unhide a run, remove (and lock) its video link, ban a key, resolve reports,
// rename games, set or clear a game's Steam ID, edit aliases, merge games. Each write recomputes the groups it
// touches and ends with `afterWrite` (cache purge), like the API's writes.
import { afterWrite, isoSeconds, recomputeGroups, type Affected, type PurgeTarget } from "../db.ts";
import { purge } from "../cache.ts";
import type { Env } from "../index.ts";
import { normalizeTitle } from "../lib/games.ts";

/** A refusal the admin page shows as is. */
export class AdminError extends Error {}

export const GAME_SLUG = /^[a-z0-9][a-z0-9-]{0,120}$/;
const MAX_TITLE = 200;
/** Run pages purged per write; the rest expire within the cache's 60 s (each purge is a subrequest). */
const MAX_PURGED_RUNS = 30;

export interface WriteContext {
  env: Env;
  now: Date;
  target: PurgeTarget;
}

interface RunRef {
  id: string;
  game_id: number;
  mac_key: string;
  setup_key: string;
  group_key: string;
}

const RUN_REF = "id, game_id, mac_key, setup_key, group_key";

async function runRef(env: Env, id: string): Promise<RunRef> {
  const r = await env.DB.prepare(`SELECT ${RUN_REF} FROM runs WHERE id = ?`).bind(id).first<RunRef>();
  if (r === null) throw new AdminError("That run doesn't exist (it may have been removed by its owner).");
  return r;
}

function affectedBy(runs: RunRef[], extraGames: number[] = []): Affected {
  const uniq = <T,>(xs: T[]) => [...new Set(xs)];
  return {
    gameIds: uniq([...runs.map((r) => r.game_id), ...extraGames]),
    runIds: uniq(runs.map((r) => r.id)).slice(0, MAX_PURGED_RUNS),
    macKeys: uniq(runs.map((r) => r.mac_key)),
    setupKeys: uniq(runs.map((r) => r.setup_key)),
  };
}

/** Recompute every group in `groupKeys` (bulk: a few D1 calls whatever the count), then purge what `affected` names. */
async function finish(ctx: WriteContext, groupKeys: string[], affected: Affected): Promise<void> {
  if (groupKeys.length > 0) await recomputeGroups(ctx.env, groupKeys, isoSeconds(ctx.now));
  await afterWrite(ctx.env, affected, ctx.target);
}

// MARK: - Runs

export async function setRunHidden(ctx: WriteContext, id: string, hidden: boolean): Promise<void> {
  const r = await runRef(ctx.env, id);
  await ctx.env.DB.prepare("UPDATE runs SET hidden = ? WHERE id = ?").bind(hidden ? 1 : 0, id).run();
  await finish(ctx, [r.group_key], affectedBy([r]));
}

/** Clears the video link and locks it, so the owner's PATCH can't put one back (403 `video_locked`). */
export async function removeVideo(ctx: WriteContext, id: string): Promise<void> {
  const r = await runRef(ctx.env, id);
  await ctx.env.DB.prepare(
    "UPDATE runs SET video_id = NULL, video_title = NULL, video_channel = NULL, video_locked = 1 WHERE id = ?",
  )
    .bind(id)
    .run();
  await finish(ctx, [r.group_key], affectedBy([r]));
}

export async function unlockVideo(ctx: WriteContext, id: string): Promise<void> {
  const r = await runRef(ctx.env, id);
  await ctx.env.DB.prepare("UPDATE runs SET video_locked = 0 WHERE id = ?").bind(id).run();
  await finish(ctx, [r.group_key], affectedBy([r]));
}

// MARK: - Keys

async function runsOfKey(env: Env, keyId: string): Promise<RunRef[]> {
  const { results } = await env.DB.prepare(`SELECT ${RUN_REF} FROM runs WHERE key_id = ?`).bind(keyId).all<RunRef>();
  return results;
}

async function requireKey(env: Env, keyId: string): Promise<void> {
  const k = await env.DB.prepare("SELECT key_id FROM macs WHERE key_id = ?").bind(keyId).first();
  if (k === null) throw new AdminError("That key doesn't exist.");
}

/** Bans the key (new uploads and edits refused) and hides all its runs. */
export async function banKey(ctx: WriteContext, keyId: string): Promise<number> {
  await requireKey(ctx.env, keyId);
  const runs = await runsOfKey(ctx.env, keyId);
  await ctx.env.DB.batch([
    ctx.env.DB.prepare("UPDATE macs SET banned = 1 WHERE key_id = ?").bind(keyId),
    ctx.env.DB.prepare("UPDATE runs SET hidden = 1 WHERE key_id = ?").bind(keyId),
  ]);
  await finish(ctx, runs.map((r) => r.group_key), affectedBy(runs));
  return runs.length;
}

/** Lifts a ban; `unhide` also shows all the key's runs again (including any hidden one by one). */
export async function unbanKey(ctx: WriteContext, keyId: string, unhide: boolean): Promise<void> {
  await requireKey(ctx.env, keyId);
  const runs = unhide ? await runsOfKey(ctx.env, keyId) : [];
  const stmts = [ctx.env.DB.prepare("UPDATE macs SET banned = 0 WHERE key_id = ?").bind(keyId)];
  if (unhide) stmts.push(ctx.env.DB.prepare("UPDATE runs SET hidden = 0 WHERE key_id = ?").bind(keyId));
  await ctx.env.DB.batch(stmts);
  await finish(ctx, runs.map((r) => r.group_key), affectedBy(runs));
}

// MARK: - Reports (no page shows them: nothing to recompute or purge)

export async function setReportResolved(env: Env, reportId: number, resolved: boolean): Promise<void> {
  const r = await env.DB.prepare("UPDATE reports SET resolved = ? WHERE id = ?").bind(resolved ? 1 : 0, reportId).run();
  if ((r.meta.changes ?? 0) === 0) throw new AdminError("That report doesn't exist.");
}

export async function resolveRunReports(env: Env, runId: string): Promise<void> {
  await env.DB.prepare("UPDATE reports SET resolved = 1 WHERE run_id = ?").bind(runId).run();
}

// MARK: - Games

interface GameRow {
  id: number;
  slug: string;
  title: string;
  steam_id: string | null;
}

async function game(env: Env, id: number): Promise<GameRow> {
  const g = await env.DB.prepare("SELECT id, slug, title, steam_id FROM games WHERE id = ?").bind(id).first<GameRow>();
  if (g === null) throw new AdminError("That game doesn't exist (it may have been merged).");
  return g;
}

async function runsOfGame(env: Env, gameId: number): Promise<RunRef[]> {
  const { results } = await env.DB.prepare(`SELECT ${RUN_REF} FROM runs WHERE game_id = ?`).bind(gameId).all<RunRef>();
  return results;
}

/** Looks a game up by id, slug or game-page URL (the merge form's target). */
export async function findGame(env: Env, ref: string): Promise<GameRow | null> {
  const s = ref.trim();
  const fromURL = /\/game\/([a-z0-9-]+)\/?(?:[?#].*)?$/.exec(s)?.[1];
  if (/^\d{1,12}$/.test(s)) {
    return env.DB.prepare("SELECT id, slug, title, steam_id FROM games WHERE id = ?").bind(Number(s)).first<GameRow>();
  }
  const slug = fromURL ?? s;
  if (!GAME_SLUG.test(slug)) return null;
  return env.DB.prepare("SELECT id, slug, title, steam_id FROM games WHERE slug = ?").bind(slug).first<GameRow>();
}

async function aliasOwner(env: Env, norm: string): Promise<GameRow | null> {
  return env.DB.prepare(
    "SELECT g.id AS id, g.slug AS slug, g.title AS title, g.steam_id AS steam_id FROM game_aliases a JOIN games g ON g.id = a.game_id WHERE a.alias_norm = ?",
  )
    .bind(norm)
    .first<GameRow>();
}

/**
 * New title (and, when given, a new slug). The new title becomes an alias of the game; a title that is already
 * another game's alias is refused (merge the games instead).
 */
export async function renameGame(ctx: WriteContext, id: number, title: string, slug: string): Promise<void> {
  const g = await game(ctx.env, id);
  const t = title.trim().replace(/\s+/g, " ");
  if (t === "" || t.length > MAX_TITLE) throw new AdminError(`A title needs 1 to ${MAX_TITLE} characters.`);
  const newSlug = slug.trim() === "" ? g.slug : slug.trim();
  if (!GAME_SLUG.test(newSlug)) throw new AdminError("An address may use only a–z, 0–9 and hyphens, starting with a letter or digit.");
  if (newSlug !== g.slug) {
    const taken = await ctx.env.DB.prepare("SELECT id FROM games WHERE slug = ?").bind(newSlug).first();
    if (taken !== null) throw new AdminError(`The address /game/${newSlug} is already used by another game.`);
  }
  const norm = normalizeTitle(t);
  if (norm !== "") {
    const owner = await aliasOwner(ctx.env, norm);
    if (owner !== null && owner.id !== id) {
      throw new AdminError(`"${t}" is already a name of ${owner.title} (/game/${owner.slug}). Merge the games instead.`);
    }
  }
  const stmts = [ctx.env.DB.prepare("UPDATE games SET title = ?, slug = ? WHERE id = ?").bind(t, newSlug, id)];
  if (norm !== "") {
    stmts.push(ctx.env.DB.prepare("INSERT OR IGNORE INTO game_aliases (alias_norm, game_id) VALUES (?, ?)").bind(norm, id));
  }
  await ctx.env.DB.batch(stmts);
  // Statistics don't depend on the title: purge only (the game's run pages show the title).
  const runs = await runsOfGame(ctx.env, id);
  if (newSlug !== g.slug) await purge(ctx.target.cache, ctx.target.origin, [`/game/${g.slug}`]);
  await finish(ctx, [], affectedBy(runs, [id]));
}

/** Sets (digits only) or clears (empty) the game's Steam ID; one game per Steam ID. */
export async function setSteamID(ctx: WriteContext, id: number, steam: string): Promise<void> {
  await game(ctx.env, id);
  const s = steam.trim().replace(/^steam:/i, "");
  if (s !== "" && !/^\d{1,12}$/.test(s)) throw new AdminError("A Steam app ID is digits only, e.g. 1091520.");
  if (s !== "") {
    const other = await ctx.env.DB.prepare("SELECT id, slug, title FROM games WHERE steam_id = ? AND id <> ?")
      .bind(s, id)
      .first<GameRow>();
    if (other !== null) {
      throw new AdminError(`Steam app ${s} belongs to ${other.title} (/game/${other.slug}). Clear it there or merge the games.`);
    }
  }
  await ctx.env.DB.prepare("UPDATE games SET steam_id = ? WHERE id = ?").bind(s === "" ? null : s, id).run();
  // Only the game page shows the Steam ID: nothing to recompute.
  await finish(ctx, [], affectedBy([], [id]));
}

export async function addAlias(ctx: WriteContext, id: number, text: string): Promise<string> {
  await game(ctx.env, id);
  const norm = normalizeTitle(text);
  if (norm === "" || norm.length > MAX_TITLE) throw new AdminError("That name has no letters or digits to match on.");
  const owner = await aliasOwner(ctx.env, norm);
  if (owner !== null && owner.id !== id) {
    throw new AdminError(`"${norm}" already points to ${owner.title} (/game/${owner.slug}). Remove it there first or merge the games.`);
  }
  await ctx.env.DB.prepare("INSERT OR IGNORE INTO game_aliases (alias_norm, game_id) VALUES (?, ?)").bind(norm, id).run();
  await finish(ctx, [], affectedBy([], [id]));
  return norm;
}

export async function removeAlias(ctx: WriteContext, id: number, norm: string): Promise<void> {
  const r = await ctx.env.DB.prepare("DELETE FROM game_aliases WHERE alias_norm = ? AND game_id = ?").bind(norm, id).run();
  if ((r.meta.changes ?? 0) === 0) throw new AdminError("That name isn't on this game.");
  await finish(ctx, [], affectedBy([], [id]));
}

export interface MergeResult {
  runs: number;
  aliases: number;
  /** The source's Steam ID, when it was dropped because the target already had one. */
  droppedSteamID: string | null;
}

/**
 * Merges `sourceId` into `targetId`: the source's runs move (their group keys rewritten to the target's id), its
 * aliases move, its Steam ID moves when the target has none (else it is dropped and reported), its cached groups
 * and the game itself are deleted, and the target's groups are recomputed. One D1 batch (a transaction).
 */
export async function mergeGames(ctx: WriteContext, sourceId: number, targetId: number): Promise<MergeResult> {
  if (sourceId === targetId) throw new AdminError("Pick a different game to merge into.");
  const src = await game(ctx.env, sourceId);
  const dst = await game(ctx.env, targetId);
  const before = await runsOfGame(ctx.env, sourceId);
  const aliases = await ctx.env.DB.prepare("SELECT count(*) AS n FROM game_aliases WHERE game_id = ?")
    .bind(sourceId)
    .first<{ n: number }>();
  const moveSteam = src.steam_id !== null && dst.steam_id === null;
  const db = ctx.env.DB;
  // Group keys start with the game id ("7|m4-max-40|…", lib/keys.ts groupKey): swap that first part.
  const stmts = [
    db
      // The id prefix is bound as text: a JS number binds as REAL and would concatenate as "1.0".
      .prepare("UPDATE runs SET game_id = ?1, group_key = ?3 || substr(group_key, instr(group_key, '|')) WHERE game_id = ?2")
      .bind(targetId, sourceId, String(targetId)),
    db.prepare("UPDATE game_aliases SET game_id = ? WHERE game_id = ?").bind(targetId, sourceId),
    db.prepare(`DELETE FROM "groups" WHERE game_id = ?`).bind(sourceId),
    db.prepare("UPDATE games SET steam_id = NULL WHERE id = ?").bind(sourceId),
  ];
  if (moveSteam) stmts.push(db.prepare("UPDATE games SET steam_id = ? WHERE id = ?").bind(src.steam_id, targetId));
  stmts.push(db.prepare("DELETE FROM games WHERE id = ?").bind(sourceId));
  // The source's title keeps matching (to the target) even if its alias had been removed.
  const norm = normalizeTitle(src.title);
  if (norm !== "") stmts.push(db.prepare("INSERT OR IGNORE INTO game_aliases (alias_norm, game_id) VALUES (?, ?)").bind(norm, targetId));
  await db.batch(stmts);

  const moved = new Set(before.map((r) => r.id));
  const movedNow = (await runsOfGame(ctx.env, targetId)).filter((r) => moved.has(r.id));
  await purge(ctx.target.cache, ctx.target.origin, [`/game/${src.slug}`]);
  // The moved runs' new groups (some shared with the target's own runs) get recomputed; the source's are gone.
  await finish(ctx, movedNow.map((r) => r.group_key), affectedBy(movedNow, [targetId]));
  return { runs: before.length, aliases: aliases?.n ?? 0, droppedSteamID: src.steam_id !== null && !moveSteam ? src.steam_id : null };
}

// MARK: - Recompute statistics (the repair path)

/** Groups recomputed per request by "Recompute statistics"; the page offers "run again" while any are left. */
export const RECOMPUTE_CHUNK = 200;

export type RecomputeScope = { kind: "all" } | { kind: "game"; id: number } | { kind: "key"; keyId: string };

export interface RecomputeResult {
  done: number;
  left: number;
  /** The last group key done: the next request continues after it. Null when none was done. */
  last: string | null;
}

/** Every group key in scope: from the runs, plus `groups` rows (a stale row whose runs are gone is deleted). */
function scopeKeys(scope: RecomputeScope): { sql: string; params: (string | number)[] } {
  switch (scope.kind) {
    case "all":
      return { sql: `SELECT group_key FROM runs UNION SELECT group_key FROM "groups"`, params: [] };
    case "game":
      return {
        sql: `SELECT group_key FROM runs WHERE game_id = ?1 UNION SELECT group_key FROM "groups" WHERE game_id = ?1`,
        params: [scope.id],
      };
    case "key":
      return { sql: "SELECT DISTINCT group_key FROM runs WHERE key_id = ?1", params: [scope.keyId] };
  }
}

/**
 * Recomputes up to RECOMPUTE_CHUNK groups in scope, in group-key order after `after`. Idempotent: running it again
 * (or from the start) only rewrites the same rows. Purges the scope's pages.
 */
export async function recomputeStatistics(ctx: WriteContext, scope: RecomputeScope, after: string): Promise<RecomputeResult> {
  if (scope.kind === "game") await game(ctx.env, scope.id);
  if (scope.kind === "key") await requireKey(ctx.env, scope.keyId);
  const { sql, params } = scopeKeys(scope);
  const n = params.length;
  const { results } = await ctx.env.DB.prepare(
    `SELECT group_key FROM (${sql}) WHERE group_key > ?${n + 1} ORDER BY group_key LIMIT ?${n + 2}`,
  )
    .bind(...params, after, RECOMPUTE_CHUNK)
    .all<{ group_key: string }>();
  const keys = results.map((r) => r.group_key);
  const last = keys.length > 0 ? keys[keys.length - 1] : null;
  const left = await ctx.env.DB.prepare(`SELECT count(*) AS n FROM (${sql}) WHERE group_key > ?${n + 1}`)
    .bind(...params, last ?? after)
    .first<{ n: number }>();
  const affected: Affected =
    scope.kind === "game"
      ? affectedBy([], [scope.id])
      : scope.kind === "key"
        ? affectedBy((await runsOfKey(ctx.env, scope.keyId)).slice(0, MAX_PURGED_RUNS))
        : affectedBy([]);
  await finish(ctx, keys, affected);
  return { done: keys.length, left: left?.n ?? 0, last };
}
