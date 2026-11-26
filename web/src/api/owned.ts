// The run a PATCH or DELETE names, and whether the signing key is the one that published it.
import { RUN_ID } from "../db.ts";
import type { Env } from "../index.ts";
import type { SignedHeaders } from "./auth.ts";
import { ApiError } from "./errors.ts";

export interface OwnedRun {
  id: string;
  game_id: number;
  mac_key: string;
  setup_key: string;
  group_key: string;
}

export function notFound(): ApiError {
  return new ApiError(404, "not_found", "That run is not on metal-pt.com (it may have been removed already).");
}

/** 404 for an unknown run, 403 unless both the key id and the full public key are the publisher's. */
export async function ownedRun(env: Env, id: string, h: SignedHeaders): Promise<OwnedRun> {
  if (!RUN_ID.test(id)) throw notFound();
  const row = await env.DB.prepare(
    `SELECT r.id AS id, r.game_id AS game_id, r.mac_key AS mac_key, r.setup_key AS setup_key, r.group_key AS group_key,
            r.key_id AS key_id, m.public_key AS public_key
       FROM runs r JOIN macs m ON m.key_id = r.key_id WHERE r.id = ?`,
  )
    .bind(id)
    .first<OwnedRun & { key_id: string; public_key: string }>();
  if (row === null) throw notFound();
  if (row.key_id !== h.keyId || row.public_key !== h.publicKey) {
    throw new ApiError(403, "not_yours", "Only the Mac that published this run can change or remove it.");
  }
  return { id: row.id, game_id: row.game_id, mac_key: row.mac_key, setup_key: row.setup_key, group_key: row.group_key };
}
