// Request signatures (spec §4.B): ECDSA P-256 over SHA-256, the key a base64url raw X9.63 point, the signature a
// base64url raw 64-byte r‖s (WebCrypto's form). Message builders identical to `SiteSigning`
// (Sources/MPTCore/Bench/SiteSigning.swift); hash arguments are lowercase hex SHA-256.

export function publishMessage(h: { bundle: string; run: string; samples: string; summary: string; timestamp: string }): string {
  return ["metal-pt-run", h.bundle, h.run, h.samples, h.summary, h.timestamp].join("\n");
}

export function patchMessage(p: { id: string; bodySHA256: string; timestamp: string }): string {
  return ["metal-pt-patch", p.id, p.bodySHA256, p.timestamp].join("\n");
}

export function deleteMessage(d: { id: string; timestamp: string }): string {
  return ["metal-pt-delete", d.id, d.timestamp].join("\n");
}

const B64URL = /^[A-Za-z0-9_-]*$/;

/** Unpadded base64url (Swift `SiteSigning.base64url`). */
export function base64urlEncode(bytes: Uint8Array): string {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** Strict unpadded base64url; null for any other character or an impossible length. */
export function base64urlDecode(s: string): Uint8Array | null {
  if (!B64URL.test(s) || s.length % 4 === 1) return null;
  const b64 = s.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (s.length % 4)) % 4);
  let bin: string;
  try {
    bin = atob(b64);
  } catch {
    return null;
  }
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function hex(buf: ArrayBuffer): string {
  return Array.from(new Uint8Array(buf), (b) => b.toString(16).padStart(2, "0")).join("");
}

/** Lowercase hex SHA-256 of bytes (a string is hashed as UTF-8). */
export async function sha256Hex(data: Uint8Array | string): Promise<string> {
  const bytes = typeof data === "string" ? new TextEncoder().encode(data) : data;
  return hex(await crypto.subtle.digest("SHA-256", bytes));
}

/** The key id: first 16 hex characters of SHA-256 over the X9.63 key bytes; null for a key that is not base64url. */
export async function keyID(publicKeyB64url: string): Promise<string | null> {
  const raw = base64urlDecode(publicKeyB64url);
  return raw === null ? null : (await sha256Hex(raw)).slice(0, 16);
}

/** True only for a valid signature by that key over the UTF-8 message; any malformed input is false, never a throw. */
export async function verify(publicKeyB64url: string, message: string, sigB64url: string): Promise<boolean> {
  const raw = base64urlDecode(publicKeyB64url);
  const sig = base64urlDecode(sigB64url);
  // An uncompressed P-256 point is 65 bytes starting 0x04; a raw r‖s signature is 64 bytes.
  if (raw === null || sig === null || raw.length !== 65 || raw[0] !== 0x04 || sig.length !== 64) return false;
  try {
    const key = await crypto.subtle.importKey("raw", raw, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
    return await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, sig, new TextEncoder().encode(message));
  } catch {
    return false;
  }
}
