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
 * Cloudflare's documented test secrets (always pass / always fail / token already spent). Their replies carry an
 * empty action and the hostname "example.com", so only for them are those two checks relaxed.
 */
const TEST_SECRETS = new Set([
  "1x0000000000000000000000000000000AA",
  "2x0000000000000000000000000000000AA",
  "3x0000000000000000000000000000000AA",
]);

/**
 * True when siteverify accepts `token` for this form on `hostname` (the request's host). Network errors and timeouts
 * are false.
 */
export async function verifyTurnstile(
  token: string,
  secret: string,
  hostname: string,
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
    const r = (await res.json()) as { success?: unknown; action?: unknown; hostname?: unknown };
    if (r.success !== true) return false;
    if (TEST_SECRETS.has(secret)) return r.action === undefined || r.action === "" || r.action === REPORT_ACTION;
    return r.action === REPORT_ACTION && r.hostname === hostname;
  } catch {
    return false;
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }
}
