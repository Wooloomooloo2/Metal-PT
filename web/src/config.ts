// Site settings (spec §4.B, §4.C). Changing one is a code change and a deploy.

/** Largest upload accepted, the whole multipart request (the app's `RunExport.maxBytes`, 25 MiB). */
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
/** YouTube oEmbed check timeout. */
export const OEMBED_TIMEOUT_MS = 3000;
