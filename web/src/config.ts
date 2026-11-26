// Site settings (spec §4.B, §4.C). Changing one is a code change and a deploy.

/** Largest upload accepted, the whole multipart request (the app's `PublishLimits.maxUploadBytes` and `RunExport.maxBytes`, 25 MiB). */
export const MAX_UPLOAD_BYTES = 25 * 1024 * 1024;
/** Largest PATCH body (`{ "videoURL": … }`). */
export const MAX_PATCH_BYTES = 4096;
/** MPT-Timestamp must be within this of the server's clock. */
export const TIMESTAMP_SKEW_MS = 10 * 60 * 1000;
/** Uploads per key id per rolling hour. */
export const UPLOADS_PER_HOUR = 30;
/** The first app version that signs runs (spec §4.B "minimum app version accepted"). */
export const MIN_APP_VERSION = "0.2.0";
/** Seconds of steady FPS a run needs (spec §4.C.2). */
export const MIN_STEADY_SECONDS = 60;
/**
 * Longest steady window accepted (90 minutes): the larger of the steady seconds with FPS and the steady rows'
 * elapsed span. Keeps the parse and re-check within the Free plan's per-request CPU budget.
 * Same number in the app: `PublishLimits.maxSteadySeconds` (Sources/MPTCore/Bench/PublishPayload.swift).
 */
export const MAX_STEADY_SECONDS = 90 * 60;
/**
 * Largest samples.csv part. The app's real runs write ~230 bytes per 1 Hz row (36 columns; measured on
 * 2026-11-26: 61,002 bytes / 270 rows for the widest), so 90 steady minutes plus warm-up (~6,000 rows) is
 * ~1.4 MB; 2 MiB leaves ~45 % margin (about 150 minutes of rows) for long app names in the text columns.
 * Same number in the app: `PublishLimits.maxSamplesBytes`.
 */
export const MAX_SAMPLES_BYTES = 2 * 1024 * 1024;
/** YouTube oEmbed check timeout. */
export const OEMBED_TIMEOUT_MS = 3000;
