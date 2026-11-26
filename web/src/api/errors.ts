// API error replies: `{ code, message }`, the message written for the app to show as is (spec §4.B).

export type ErrorCode =
  | "too_large"
  | "bad_request"
  | "missing_header"
  | "missing_part"
  | "bad_key"
  | "bad_timestamp"
  | "stale_timestamp"
  | "bad_signature"
  | "banned"
  | "key_conflict"
  | "rate_limited"
  | "already_published"
  | "already_published_hidden"
  | "already_published_elsewhere"
  | "bad_json"
  | "unsupported_schema"
  | "app_too_old"
  | "missing_graphics"
  | "missing_game"
  | "no_fps"
  | "too_short"
  | "too_long"
  | "numbers_mismatch"
  | "implausible"
  | "bundle_mismatch"
  | "not_found"
  | "not_yours"
  | "bad_video_link"
  | "video_unavailable"
  | "video_locked"
  | "storage_unavailable"
  | "server_error";

export class ApiError extends Error {
  constructor(
    readonly status: number,
    readonly code: ErrorCode,
    message: string,
    readonly extra: Record<string, unknown> = {},
  ) {
    super(message);
  }
}

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
  });
}

export function errorResponse(e: ApiError): Response {
  return json({ code: e.code, message: e.message, ...e.extra }, e.status);
}

/** Runs a handler, turning an ApiError into its reply and anything else into a 500 (logged without the request). */
export async function handle(f: () => Promise<Response>): Promise<Response> {
  try {
    return await f();
  } catch (e) {
    if (e instanceof ApiError) return errorResponse(e);
    // Only the error itself is logged: never the request or its headers (spec §4.B).
    console.error("api error", e instanceof Error ? e.stack ?? e.message : String(e));
    return errorResponse(new ApiError(500, "server_error", "Something went wrong on metal-pt.com. Please try again later."));
  }
}
