// DELETE /api/v1/runs/:id (spec §4.B): only the key that published the run. Signed over
// "metal-pt-delete\n" + id + "\n" + timestamp. Removes the run from pages and statistics and deletes its zip.
import { afterWrite, isoSeconds, recomputeGroup } from "../db.ts";
import type { Deps } from "../deps.ts";
import type { Env } from "../index.ts";
import { deleteMessage } from "../lib/signing.ts";
import { requireSignature, signedHeaders } from "./auth.ts";
import { json } from "./errors.ts";
import { ownedRun } from "./owned.ts";

export async function deleteRun(req: Request, env: Env, deps: Deps, id: string): Promise<Response> {
  const now = deps.now();
  const h = await signedHeaders(req, now);
  await requireSignature(h, deleteMessage({ id, timestamp: h.timestamp }));
  const run = await ownedRun(env, id, h);

  await env.DB.batch([
    env.DB.prepare("DELETE FROM reports WHERE run_id = ?").bind(id),
    env.DB.prepare("DELETE FROM runs WHERE id = ?").bind(id),
  ]);
  await env.RUNS.delete(`runs/${id}.zip`);
  await recomputeGroup(env, run.group_key, isoSeconds(now));
  await afterWrite(env, { gameIds: [run.game_id], runIds: [id], macKeys: [run.mac_key], setupKeys: [run.setup_key] });
  return json({ id, deleted: true });
}
