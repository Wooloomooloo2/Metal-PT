// PATCH /api/v1/runs/:id (spec §4.B): change or clear the run's video link; only the publishing key. Signed over
// "metal-pt-patch\n" + id + "\n" + sha256(body) + "\n" + timestamp. Body `{ "videoURL": string | null }`.
import { MAX_PATCH_BYTES } from "../config.ts";
import { afterWrite } from "../db.ts";
import type { Deps } from "../deps.ts";
import type { Env } from "../index.ts";
import { patchMessage, sha256Hex } from "../lib/signing.ts";
import { checkVideo, type Video } from "../oembed.ts";
import { requireSignature, signedHeaders } from "./auth.ts";
import { ApiError, json } from "./errors.ts";
import { ownedRun } from "./owned.ts";
import { runURL } from "./publish.ts";

export async function patchRun(req: Request, env: Env, deps: Deps, id: string): Promise<Response> {
  const length = Number(req.headers.get("content-length") ?? "0");
  if (Number.isFinite(length) && length > MAX_PATCH_BYTES) {
    throw new ApiError(413, "too_large", "The change is larger than metal-pt.com accepts.");
  }
  const h = await signedHeaders(req, deps.now());
  const body = new Uint8Array(await req.arrayBuffer());
  if (body.length > MAX_PATCH_BYTES) throw new ApiError(413, "too_large", "The change is larger than metal-pt.com accepts.");
  await requireSignature(h, patchMessage({ id, bodySHA256: await sha256Hex(body), timestamp: h.timestamp }));
  const run = await ownedRun(env, id, h);

  let parsed: unknown;
  try {
    parsed = JSON.parse(new TextDecoder().decode(body));
  } catch {
    parsed = undefined;
  }
  const url = (parsed as { videoURL?: unknown } | null)?.videoURL;
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed) || !(url === null || typeof url === "string")) {
    throw new ApiError(400, "bad_json", "The change could not be read. Please update Metal-PT.");
  }

  let video: Video | null = null;
  if (typeof url === "string" && url.trim() !== "") {
    const v = await checkVideo(url, deps.fetch);
    if (!v.ok) {
      // Nothing changes; the reply says why (and never repeats the link).
      throw new ApiError(422, v.reason === "not_youtube" ? "bad_video_link" : "video_unavailable", `The video link was not saved: ${v.message}`);
    }
    video = v.video;
  }
  await env.DB.prepare("UPDATE runs SET video_id = ?, video_title = ?, video_channel = ? WHERE id = ?")
    .bind(video?.id ?? null, video?.title ?? null, video?.channel ?? null, id)
    .run();
  await afterWrite(env, { gameIds: [run.game_id], runIds: [id], macKeys: [run.mac_key], setupKeys: [run.setup_key] });
  return json({ id, url: runURL(req, id), video });
}
