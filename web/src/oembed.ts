// YouTube oEmbed check (spec §4.C.6): does the video exist and is it public? Only the 11-character ID, the title
// and the channel name are kept; the submitted URL is never stored or echoed.
import { OEMBED_TIMEOUT_MS } from "./config.ts";
import { canonicalURL, videoID } from "./lib/youtube.ts";

export type Fetch = (input: string, init?: RequestInit) => Promise<Response>;

export interface Video {
  id: string;
  title: string;
  channel: string;
}

/** A video, or why there is none (a message for the app to show as is; it never repeats the URL). */
export type VideoCheck = { ok: true; video: Video } | { ok: false; reason: "not_youtube" | "unavailable" | "unreachable"; message: string };

export const VIDEO_MESSAGES = {
  not_youtube:
    "Only YouTube links can be added (youtube.com/watch?v=…, youtu.be/…, youtube.com/shorts/… or youtube.com/live/…).",
  unavailable: "YouTube says the video is private, deleted or does not exist.",
  unreachable: "YouTube could not be reached to check the video. You can add the link again later.",
} as const;

const MAX_TEXT = 200;

function text(v: unknown): string | null {
  if (typeof v !== "string") return null;
  const s = v.trim();
  return s === "" ? null : s.slice(0, MAX_TEXT);
}

/** `https://www.youtube.com/oembed?url=<canonical watch URL>&format=json`, with a timeout. */
export async function checkVideo(url: string, fetchFn: Fetch, timeoutMs = OEMBED_TIMEOUT_MS): Promise<VideoCheck> {
  const id = videoID(url);
  if (id === null) return { ok: false, reason: "not_youtube", message: VIDEO_MESSAGES.not_youtube };
  const endpoint = `https://www.youtube.com/oembed?url=${encodeURIComponent(canonicalURL(id))}&format=json`;
  const controller = new AbortController();
  let timer: ReturnType<typeof setTimeout> | null = null;
  const timeout = new Promise<"timeout">((resolve) => {
    timer = setTimeout(() => {
      controller.abort();
      resolve("timeout");
    }, timeoutMs);
  });
  try {
    const res = await Promise.race([fetchFn(endpoint, { signal: controller.signal, headers: { accept: "application/json" } }), timeout]);
    if (res === "timeout") return { ok: false, reason: "unreachable", message: VIDEO_MESSAGES.unreachable };
    // 400 / 401 / 403 / 404: no such public video (private, deleted, never existed).
    if (res.status >= 400 && res.status < 500) return { ok: false, reason: "unavailable", message: VIDEO_MESSAGES.unavailable };
    if (!res.ok) return { ok: false, reason: "unreachable", message: VIDEO_MESSAGES.unreachable };
    const body = (await Promise.race([res.json(), timeout])) as Record<string, unknown> | "timeout";
    if (body === "timeout" || body === null || typeof body !== "object") {
      return { ok: false, reason: "unreachable", message: VIDEO_MESSAGES.unreachable };
    }
    return { ok: true, video: { id, title: text(body.title) ?? "YouTube video", channel: text(body.author_name) ?? "" } };
  } catch {
    return { ok: false, reason: "unreachable", message: VIDEO_MESSAGES.unreachable };
  } finally {
    if (timer !== null) clearTimeout(timer);
  }
}
