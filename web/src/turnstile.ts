// Cloudflare Turnstile on the report form (spec §4.H): the widget's token is checked server-side with siteverify.
// The visitor's IP address is never sent (`remoteip` is optional and left out: the site uses no IP addresses).
import type { Fetch } from "./oembed.ts";

export const TURNSTILE_SCRIPT = "https://challenges.cloudflare.com/turnstile/v0/api.js";
const SITEVERIFY = "https://challenges.cloudflare.com/turnstile/v0/siteverify";
/** The widget's `data-action`, checked in the reply so a token made for another form doesn't pass. */
export const REPORT_ACTION = "report";

export interface TurnstileEnv {
  TURNSTILE_SITE_KEY?: string;
  TURNSTILE_SECRET?: string;
  /** "1" in tests only: skip the widget and the check. */
  TURNSTILE_DISABLED?: string;
}

export type TurnstileMode = { kind: "disabled" } | { kind: "on"; siteKey: string; secret: string } | { kind: "unconfigured" };

/** Off only with TURNSTILE_DISABLED=1; without a site key and secret the form is closed (fail closed). */
export function turnstileMode(env: TurnstileEnv): TurnstileMode {
  if (env.TURNSTILE_DISABLED === "1") return { kind: "disabled" };
  const siteKey = (env.TURNSTILE_SITE_KEY ?? "").trim();
  const secret = (env.TURNSTILE_SECRET ?? "").trim();
  return siteKey !== "" && secret !== "" ? { kind: "on", siteKey, secret } : { kind: "unconfigured" };
}

/**
 * True when siteverify accepts `token` for this form. Network errors and timeouts are false. (The hostname isn't
 * compared: the site key is limited to the site's hostnames in the Turnstile settings.)
 */
export async function verifyTurnstile(
  token: string,
  secret: string,
  fetchFn: Fetch,
  timeoutMs = 5000,
): Promise<boolean> {
  if (token === "" || token.length > 2048) return false;
  const body = new FormData();
  body.set("secret", secret);
  body.set("response", token);
  const abort = new AbortController();
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    const res = await Promise.race([
      fetchFn(SITEVERIFY, { method: "POST", body, signal: abort.signal }),
      new Promise<never>((_, reject) => {
        timer = setTimeout(() => {
          abort.abort();
          reject(new Error("timeout"));
        }, timeoutMs);
      }),
    ]);
    if (!res.ok) return false;
    const r = (await res.json()) as { success?: unknown; action?: unknown };
    if (r.success !== true) return false;
    // Cloudflare's test keys answer with an empty action; a real token carries the widget's.
    if (typeof r.action === "string" && r.action !== "" && r.action !== REPORT_ACTION) return false;
    return true;
  } catch {
    return false;
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }
}
