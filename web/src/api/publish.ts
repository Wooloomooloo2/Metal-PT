// POST /api/v1/runs (spec §4.B), with the checks of §4.C in this order: size, headers, timestamp, signature (over
// the small parts' hashes computed here and the signed bundle hash), key standing (banned, duplicate, rate limit),
// JSON shape, required fields, re-check, sanity, scrub. The bundle is never opened: it goes to R2 with the signed
// SHA-256, which R2 enforces on write.
import { MAX_SAMPLES_BYTES, MAX_STEADY_SECONDS, MAX_UPLOAD_BYTES, MIN_STEADY_SECONDS, UPLOADS_PER_HOUR } from "../config.ts";
import {
  afterWrite,
  findMac,
  isoSeconds,
  matchGame,
  type GameMatch,
  newRunID,
  recomputeGroup,
  runByBundle,
  runsSince,
  steamID,
} from "../db.ts";
import type { Deps } from "../deps.ts";
import type { Env } from "../index.ts";
import { groupKey, graphicsLayers, macKey, setupKey, setupLabel } from "../lib/keys.ts";
import { matches, parseSamples, recheckSamples } from "../lib/recheck.ts";
import type { RunJson } from "../lib/run-json.ts";
import { scrub, scrubPaths } from "../lib/scrub.ts";
import { fpsSeries } from "../lib/series.ts";
import { publishMessage, sha256Hex } from "../lib/signing.ts";
import { checkVideo, type Video } from "../oembed.ts";
import { requireSignature, signedHeaders } from "./auth.ts";
import { ApiError, json } from "./errors.ts";
import { checkSanity, onACOf } from "./sanity.ts";
import { boundedMemoryGB, parseRunJson, parseSummaryJson, requireFields } from "./validate.ts";

export const PARTS = ["bundle", "run.json", "samples.csv", "summary.json"] as const;

/** Per-part caps (the bundle is capped by the whole upload's 25 MB). */
export const PART_CAPS: Partial<Record<(typeof PARTS)[number], { bytes: number; label: string }>> = {
  "run.json": { bytes: 256 * 1024, label: "256 KB" },
  "summary.json": { bytes: 16 * 1024, label: "16 KB" },
  "samples.csv": { bytes: MAX_SAMPLES_BYTES, label: "2 MB" },
};

function tooLarge(): ApiError {
  return new ApiError(413, "too_large", "This run is larger than metal-pt.com accepts (25 MB).");
}

/** A form part as a Blob (a plain string field becomes its UTF-8 bytes); null when absent. */
function partBlob(v: File | string | null): Blob | null {
  if (v === null) return null;
  return typeof v === "string" ? new Blob([new TextEncoder().encode(v)]) : v;
}

async function bytesOf(b: Blob): Promise<Uint8Array> {
  return new Uint8Array(await b.arrayBuffer());
}

/** R2's refusal of a put whose bytes don't match the `sha256` given (error 10037 "BadDigest"). */
export function isDigestMismatch(e: unknown): boolean {
  const m = e instanceof Error ? e.message : String(e);
  return /sha-?256|checksum|digest|10037/i.test(m);
}

export function runURL(req: Request, id: string): string {
  return new URL(`/run/${id}`, req.url).href;
}

/**
 * The same bundle is already on the site. Its page is given back only when it is visible and was published by the
 * same key; a hidden run or another key's run gets a 409 without an id or URL (nothing to link to or record).
 */
function alreadyPublished(req: Request, existing: { id: string; key_id: string; hidden: number }, keyId: string): ApiError {
  if (existing.key_id !== keyId) {
    return new ApiError(409, "already_published_elsewhere", "This exact run was already published from another Mac.");
  }
  if (existing.hidden) {
    return new ApiError(
      409,
      "already_published_hidden",
      "This run was already published and has been hidden by a moderator.",
    );
  }
  return new ApiError(409, "already_published", "This run is already published.", {
    id: existing.id,
    url: runURL(req, existing.id),
  });
}

/** Trimmed, scrubbed text, cut to `max` characters; null when empty. */
function text(v: string | null | undefined, max: number, paths = false): string | null {
  if (v == null) return null;
  const s = (paths ? scrubPaths(v) : scrub(v)).trim();
  return s === "" ? null : s.slice(0, max);
}

/** The run's text fields re-scrubbed (spec §4.C.5); everything stored or used for keys comes from this copy. */
function scrubbed(run: RunJson): RunJson {
  const t = (v: string | null | undefined, max: number) => text(v, max) ?? "";
  return {
    ...run,
    appVersion: text(run.appVersion, 40, true) ?? undefined,
    machine: {
      ...run.machine,
      chip: text(run.machine.chip, 80, true) ?? "",
      modelID: text(run.machine.modelID, 80, true) ?? "",
      osVersion: text(run.machine.osVersion, 40, true) ?? "",
    },
    game: { ...run.game, exe: t(run.game.exe, 200), title: text(run.game.title, 200) },
    stack: run.stack && {
      ...run.stack,
      runtime: text(run.stack.runtime, 80),
      runtimeVersion: text(run.stack.runtimeVersion, 80),
      graphics: (run.stack.graphics ?? []).map((g) => t(g, 80)).filter((g) => g !== ""),
    },
    settings: run.settings && { ...run.settings, powerMode: text(run.settings.powerMode, 40) },
    user: run.user && {
      label: t(run.user.label, 200),
      gameSettings: t(run.user.gameSettings, 2000),
      // The app empties the notes unless "include notes" is ticked, so non-empty notes were meant to be public.
      notes: t(run.user.notes, 5000),
      videoURL: run.user.videoURL,
    },
  };
}

export async function publish(req: Request, env: Env, deps: Deps): Promise<Response> {
  const now = deps.now();

  // 1. Size.
  const length = Number(req.headers.get("content-length") ?? "0");
  if (Number.isFinite(length) && length > MAX_UPLOAD_BYTES) throw tooLarge();

  // 2–3. Headers, timestamp.
  const h = await signedHeaders(req, now, true);

  let form: FormData;
  try {
    form = await req.formData();
  } catch {
    throw new ApiError(400, "bad_request", "The upload could not be read. Please update Metal-PT.");
  }
  const blobs = PARTS.map((p) => partBlob(form.get(p)));
  const missing = PARTS.filter((_, i) => blobs[i] === null);
  if (missing.length > 0) {
    throw new ApiError(400, "missing_part", `The upload is missing ${missing.join(", ")}. Please update Metal-PT.`);
  }
  const [bundle, runBlob, samplesBlob, summaryBlob] = blobs as Blob[];
  // Sizes from the parts themselves, before anything is read, hashed or parsed.
  if (blobs.reduce((n, b) => n + b!.size, 0) > MAX_UPLOAD_BYTES) throw tooLarge();
  for (const [i, part] of PARTS.entries()) {
    const cap = PART_CAPS[part];
    if (cap !== undefined && blobs[i]!.size > cap.bytes) {
      throw new ApiError(413, "too_large", `This run's ${part} is larger than metal-pt.com accepts (${cap.label}).`);
    }
  }
  const [runBytes, samplesBytes, summaryBytes] = await Promise.all([runBlob, samplesBlob, summaryBlob].map(bytesOf));

  // 4. Signature: the small parts are hashed here; the bundle's hash is the signed header, enforced by R2 below.
  const [runHash, samplesHash, summaryHash] = await Promise.all([runBytes, samplesBytes, summaryBytes].map((b) => sha256Hex(b)));
  await requireSignature(
    h,
    publishMessage({ bundle: h.bundleSHA256, run: runHash, samples: samplesHash, summary: summaryHash, timestamp: h.timestamp }),
  );

  // The key's standing.
  const mac = await findMac(env, h.keyId);
  if (mac !== null && mac.public_key !== h.publicKey) {
    throw new ApiError(
      403,
      "key_conflict",
      "Your Mac's publishing key clashes with another — please report this on GitHub.",
    );
  }
  if (mac !== null && mac.banned) {
    throw new ApiError(403, "banned", "Runs from this Mac are no longer accepted on metal-pt.com.");
  }
  const existing = await runByBundle(env, h.bundleSHA256);
  if (existing !== null) throw alreadyPublished(req, existing, h.keyId);
  // Rate limit, D1 fallback: the Workers rate-limiting binding only has 10 s / 60 s periods, not an hour.
  const hourAgo = isoSeconds(new Date(now.getTime() - 3600_000));
  if ((await runsSince(env, h.keyId, hourAgo)) >= UPLOADS_PER_HOUR) {
    throw new ApiError(429, "rate_limited", `This Mac has published ${UPLOADS_PER_HOUR} runs in the last hour. Try again later.`);
  }

  // 5. JSON shape.
  const decoder = new TextDecoder();
  const rawRun = parseRunJson(decoder.decode(runBytes));
  const summary = parseSummaryJson(decoder.decode(summaryBytes));

  // 6. Required fields.
  const graphics = requireFields(rawRun, summary);

  // 7. Re-check (samples.csv parsed once, its numbers reused below).
  const samples = parseSamples(decoder.decode(samplesBytes));
  const r = recheckSamples(rawRun, samples);
  if (r.steadySeconds < MIN_STEADY_SECONDS) {
    throw new ApiError(
      422,
      "too_short",
      `A run needs at least ${MIN_STEADY_SECONDS} seconds of steady play with a frame rate; this one has ${r.steadySeconds}.`,
    );
  }
  if (Math.max(r.steadySeconds, r.steadySpanSeconds) > MAX_STEADY_SECONDS) {
    throw new ApiError(
      422,
      "too_long",
      "Runs longer than 90 minutes can't be published yet — record a shorter run.",
    );
  }
  const mismatch = matches(summary, r);
  if (mismatch !== null) throw new ApiError(422, "numbers_mismatch", mismatch);

  // 8. Sanity.
  checkSanity(samples, r);

  // 9. Scrub.
  const run = scrubbed(rawRun);

  // Video link: never fails the upload (spec §4.C.6).
  let video: Video | null = null;
  let notice: string | undefined;
  const videoURL = (rawRun.user?.videoURL ?? "").trim();
  if (videoURL !== "") {
    const v = await checkVideo(videoURL, deps.fetch);
    if (v.ok) video = v.video;
    else notice = `Published without the video link: ${v.message}`;
  }

  // The bundle, unopened, to R2 with the signed hash (R2 refuses the write if the bytes don't match it).
  const id = newRunID();
  const object = `runs/${id}.zip`;
  try {
    // The Blob goes as is (no copy of up to 25 MB); R2 checks its SHA-256 against the signed one.
    await env.RUNS.put(object, bundle, { sha256: h.bundleSHA256, httpMetadata: { contentType: "application/zip" } });
  } catch (e) {
    if (!isDigestMismatch(e)) {
      throw new ApiError(503, "storage_unavailable", "metal-pt.com couldn't store the run just now — try again in a few minutes.");
    }
    throw new ApiError(
      422,
      "bundle_mismatch",
      "The run's zip did not match its signature, so nothing was published. Try again; if it keeps happening, the file may have changed while uploading.",
    );
  }

  // Game, keys and the run's rows. Any failure removes the stored zip again.
  const nowText = isoSeconds(now);
  const title = (run.game.title ?? "") !== "" ? run.game.title! : run.game.exe.replace(/\.(app|exe)$/i, "");
  const mk = macKey(run.machine);
  let game: GameMatch, sk: string, gk: string;
  try {
    game = await matchGame(env, title, steamID(run.game.storeAppID), nowText);
    sk = setupKey(run, game.title);
    gk = groupKey({
      gameId: game.id,
      macKey: mk,
      setupKey: sk,
      preset: graphics.preset,
      width: graphics.width,
      height: graphics.height,
      upscaler: graphics.upscaler,
      upscalerMode: graphics.upscalerMode,
      frameGeneration: graphics.frameGeneration,
    });
    const p1 = summary.p1LowFPS;
    const series = fpsSeries(samples, rawRun.steadyStartS ?? null, rawRun.steadyEndS ?? null);
    await env.DB.batch([
      env.DB.prepare("INSERT OR IGNORE INTO macs (key_id, public_key, first_seen) VALUES (?, ?, ?)").bind(
        h.keyId,
        h.publicKey,
        nowText,
      ),
      env.DB.prepare(
        `INSERT INTO runs (id, game_id, key_id, bundle_sha256, published, recorded, app_version, chip, gpu_cores, memory_gb,
           model_id, os_version, mac_key, setup_key, setup_label, group_key, runtime, runtime_version, graphics_layers,
           recorded_app, preset, width, height, upscaler, upscaler_mode, frame_gen, median_fps, p1_low_fps, fps_per_watt,
           mean_system_w, power_source, on_ac, power_mode, limiter_primary, limiter_verdict, steady_s, notes,
           settings_text, label, video_id, video_title, video_channel, fps_series)
         VALUES (${Array(43).fill("?").join(", ")})`,
      ).bind(
        id,
        game.id,
        h.keyId,
        h.bundleSHA256,
        nowText,
        isoSeconds(new Date(Date.parse(run.start))),
        run.appVersion ?? null,
        run.machine.chip || null,
        run.machine.gpuCores ?? null,
        boundedMemoryGB(run.machine.memoryGB),
        run.machine.modelID || null,
        run.machine.osVersion || null,
        mk,
        sk,
        setupLabel(run, game.title),
        gk,
        run.stack?.runtime ?? null,
        run.stack?.runtimeVersion ?? null,
        graphicsLayers(run.stack) || null,
        run.game.exe || null,
        graphics.preset,
        graphics.width,
        graphics.height,
        graphics.upscaler,
        graphics.upscalerMode ?? null,
        graphics.frameGeneration ? "on" : "off",
        r.medianFPS,
        p1 !== null && p1 >= 0 && r.medianFPS !== null && p1 <= r.medianFPS + 0.5 ? p1 : null,
        r.fpsPerWatt,
        r.powerSource === "system" ? r.meanW : null,
        r.powerSource,
        ((ac) => (ac === null ? null : ac ? 1 : 0))(onACOf(samples, r.steady, run.settings?.onACAtStart)),
        run.settings?.powerMode ?? null,
        text(summary.limiter?.primary, 40),
        text(summary.limiter?.verdict, 200),
        r.steadySeconds,
        run.user?.notes || null,
        run.user?.gameSettings || null,
        run.user?.label || null,
        video?.id ?? null,
        video?.title ?? null,
        video?.channel ?? null,
        JSON.stringify(series),
      ),
    ]);
  } catch (e) {
    await env.RUNS.delete(object);
    // Two uploads of the same bundle at once: the second loses the UNIQUE race.
    const dup = await runByBundle(env, h.bundleSHA256);
    if (dup !== null) throw alreadyPublished(req, dup, h.keyId);
    throw e;
  }

  await recomputeGroup(env, gk, nowText);
  await afterWrite(env, { gameIds: [game.id], runIds: [id], macKeys: [mk], setupKeys: [sk] }, {
    origin: new URL(req.url).origin,
    cache: deps.cache(),
  });
  return json({ id, url: runURL(req, id), ...(notice !== undefined ? { notice } : {}) }, 201);
}
