// Request signing checks shared by POST, PATCH and DELETE (spec §4.B, §4.C.1): headers, timestamp, signature.
// Only the three MPT-* headers (and MPT-Bundle-SHA256 on POST) are read; no other header is read or logged, and
// never any client address (spec §4.I).
import { TIMESTAMP_SKEW_MS } from "../config.ts";
import { base64urlDecode, base64urlEncode, sha256Hex, verify } from "../lib/signing.ts";
import { ApiError } from "./errors.ts";

export interface SignedHeaders {
  /** The public key re-encoded from its decoded bytes (canonical unpadded base64url), never the submitted text. */
  publicKey: string;
  /** First 16 hex characters of SHA-256 over the key bytes. */
  keyId: string;
  timestamp: string;
  signature: string;
  /** MPT-Bundle-SHA256 (POST only), else "". */
  bundleSHA256: string;
}

/** Strict ISO-8601 date-time with a zone (what Swift's ISO8601DateFormatter writes, fractions allowed). */
export const ISO = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$/;

const SHA256_HEX = /^[0-9a-f]{64}$/;

/**
 * Reads and checks MPT-Key, MPT-Timestamp and MPT-Signature (presence, key shape, timestamp freshness), and with
 * `bundle` also MPT-Bundle-SHA256 (the signed bundle hash, lowercase hex, which R2 enforces on write).
 */
export async function signedHeaders(req: Request, now: Date, bundle = false): Promise<SignedHeaders> {
  const key = req.headers.get("MPT-Key");
  const timestamp = req.headers.get("MPT-Timestamp");
  const signature = req.headers.get("MPT-Signature");
  const bundleHash = bundle ? req.headers.get("MPT-Bundle-SHA256") : null;
  const missing = [
    key ? null : "MPT-Key",
    timestamp ? null : "MPT-Timestamp",
    signature ? null : "MPT-Signature",
    !bundle || bundleHash ? null : "MPT-Bundle-SHA256",
  ].filter((m) => m !== null);
  if (missing.length > 0) {
    throw new ApiError(400, "missing_header", `The upload is missing ${missing.join(", ")}. Please update Metal-PT.`);
  }
  if (bundle && !SHA256_HEX.test(bundleHash!)) {
    throw new ApiError(400, "bad_request", "The upload's bundle hash could not be read. Please update Metal-PT.");
  }
  const raw = base64urlDecode(key!);
  if (raw === null || raw.length !== 65 || raw[0] !== 0x04) {
    throw new ApiError(400, "bad_key", "This Mac's signing key was not recognised. Please update Metal-PT.");
  }
  const t = ISO.test(timestamp!) ? Date.parse(timestamp!) : NaN;
  if (Number.isNaN(t)) {
    throw new ApiError(400, "bad_timestamp", "The upload's time stamp could not be read. Please update Metal-PT.");
  }
  if (Math.abs(t - now.getTime()) > TIMESTAMP_SKEW_MS) {
    throw new ApiError(
      401,
      "stale_timestamp",
      "This Mac's clock is more than 10 minutes away from metal-pt.com's. Check the date and time in System Settings, then try again.",
    );
  }
  return {
    publicKey: base64urlEncode(raw),
    keyId: (await sha256Hex(raw)).slice(0, 16),
    timestamp: timestamp!,
    signature: signature!,
    bundleSHA256: bundleHash ?? "",
  };
}

/** Throws bad_signature unless `signature` is this key's over `message`. */
export async function requireSignature(h: SignedHeaders, message: string): Promise<void> {
  if (!(await verify(h.publicKey, message, h.signature))) {
    throw new ApiError(
      401,
      "bad_signature",
      "The upload's signature did not check out, so nothing was published. Try again; if it keeps happening, the files may have changed while uploading.",
    );
  }
}
