// Cloudflare Access for /admin (spec §4.H): every admin request must carry a valid `Cf-Access-Jwt-Assertion`, an
// RS256 JWT signed by one of the team's keys (https://<team>.cloudflareaccess.com/cdn-cgi/access/certs), for this
// application (`aud` = ACCESS_AUD), issued by the team, and within its `nbf`/`exp`. The Worker checks it itself, so
// a request that reaches the Worker some other way (workers.dev, a misconfigured route) is still refused.
import type { Fetch } from "../oembed.ts";
import { base64urlDecode } from "../lib/signing.ts";

/** Allowed clock difference for `exp` / `nbf`. */
const LEEWAY_S = 60;
/** How long the team's keys are kept in memory. A key id not in the cache refetches (at most every 30 s). */
const JWKS_TTL_MS = 10 * 60 * 1000;
const JWKS_REFETCH_MS = 30 * 1000;

export interface AccessConfig {
  /** "https://<team>.cloudflareaccess.com", from ACCESS_TEAM_DOMAIN ("<team>", "<team>.cloudflareaccess.com" or a URL). */
  issuer: string;
  aud: string;
}

/** The Access settings from the environment, or null when either is unset (then /admin is a 404). */
export function accessConfig(env: { ACCESS_TEAM_DOMAIN?: string; ACCESS_AUD?: string }): AccessConfig | null {
  const team = (env.ACCESS_TEAM_DOMAIN ?? "").trim().replace(/^https?:\/\//i, "").replace(/\/+$/, "").toLowerCase();
  const aud = (env.ACCESS_AUD ?? "").trim();
  if (team === "" || aud === "") return null;
  const host = team.includes(".") ? team : `${team}.cloudflareaccess.com`;
  if (!/^[a-z0-9.-]+$/.test(host)) return null;
  return { issuer: `https://${host}`, aud };
}

export interface AccessIdentity {
  email: string | null;
  sub: string | null;
}

interface Jwks {
  url: string;
  keys: Map<string, CryptoKey>;
  fetchedAt: number;
}

let cache: Jwks | null = null;

/** Tests: forget the cached keys. */
export function clearJwksCache(): void {
  cache = null;
}

async function loadKeys(url: string, fetchFn: Fetch, now: number): Promise<Jwks> {
  const res = await fetchFn(url);
  if (!res.ok) throw new Error(`access certs: HTTP ${res.status}`);
  const body = (await res.json()) as { keys?: JsonWebKey[] };
  const keys = new Map<string, CryptoKey>();
  for (const jwk of body.keys ?? []) {
    const kid = (jwk as { kid?: unknown }).kid;
    if (typeof kid !== "string" || jwk.kty !== "RSA") continue;
    try {
      keys.set(
        kid,
        await crypto.subtle.importKey("jwk", { kty: "RSA", n: jwk.n, e: jwk.e, alg: "RS256", ext: true }, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["verify"]),
      );
    } catch {
      // A key that doesn't import is skipped; tokens signed by it fail.
    }
  }
  return { url, keys, fetchedAt: now };
}

async function keyFor(kid: string, url: string, fetchFn: Fetch, now: number): Promise<CryptoKey | null> {
  if (cache === null || cache.url !== url || now - cache.fetchedAt > JWKS_TTL_MS) {
    cache = await loadKeys(url, fetchFn, now);
  } else if (!cache.keys.has(kid) && now - cache.fetchedAt > JWKS_REFETCH_MS) {
    // Access rotates its keys: an unknown key id may be a new one.
    cache = await loadKeys(url, fetchFn, now);
  }
  return cache.keys.get(kid) ?? null;
}

function decodeJSON(part: string): Record<string, unknown> | null {
  try {
    const bytes = base64urlDecode(part);
    if (bytes === null) return null;
    const v = JSON.parse(new TextDecoder().decode(bytes));
    return typeof v === "object" && v !== null && !Array.isArray(v) ? (v as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

/**
 * The identity in a valid Access token, else null (malformed, wrong algorithm, unknown key, bad signature, wrong
 * audience or issuer, expired or not yet valid). Never throws for a bad token; a failed certs fetch is a null too.
 */
export async function verifyAccessJwt(
  token: string | null | undefined,
  cfg: AccessConfig,
  opts: { fetch: Fetch; now: Date },
): Promise<AccessIdentity | null> {
  if (!token) return null;
  const parts = token.split(".");
  if (parts.length !== 3 || parts.some((p) => !/^[A-Za-z0-9_-]+$/.test(p))) return null;
  const header = decodeJSON(parts[0]);
  const payload = decodeJSON(parts[1]);
  if (header === null || payload === null) return null;
  if (header.alg !== "RS256" || typeof header.kid !== "string") return null;

  const nowS = opts.now.getTime() / 1000;
  const aud = payload.aud;
  const auds = typeof aud === "string" ? [aud] : Array.isArray(aud) ? aud : [];
  if (!auds.includes(cfg.aud)) return null;
  if (payload.iss !== cfg.issuer) return null;
  if (typeof payload.exp !== "number" || payload.exp + LEEWAY_S < nowS) return null;
  if (payload.nbf !== undefined && (typeof payload.nbf !== "number" || payload.nbf - LEEWAY_S > nowS)) return null;

  let key: CryptoKey | null;
  try {
    key = await keyFor(header.kid, `${cfg.issuer}/cdn-cgi/access/certs`, opts.fetch, opts.now.getTime());
  } catch {
    console.error("access: certs unavailable");
    return null;
  }
  if (key === null) return null;
  const sig = base64urlDecode(parts[2]);
  if (sig === null) return null;
  const ok = await crypto.subtle.verify(
    "RSASSA-PKCS1-v1_5",
    key,
    sig,
    new TextEncoder().encode(`${parts[0]}.${parts[1]}`),
  );
  if (!ok) return null;
  return {
    email: typeof payload.email === "string" ? payload.email : null,
    sub: typeof payload.sub === "string" ? payload.sub : null,
  };
}
