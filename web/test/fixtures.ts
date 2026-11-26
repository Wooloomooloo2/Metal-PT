import { env } from "cloudflare:test";

export const FIXTURE_NAMES = ["capped-60", "gpu-only", "no-warmup", "system-warmup"] as const;
export type FixtureName = (typeof FIXTURE_NAMES)[number];

function bytesOf(b64: string): Uint8Array {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

/** A golden fixture's file, as bytes (exactly the file) or as UTF-8 text. */
export function fixtureBytes(name: FixtureName, file: string): Uint8Array {
  const b64 = env.FIXTURES[name]?.[file];
  if (b64 === undefined) throw new Error(`no fixture file ${name}/${file}`);
  return bytesOf(b64);
}

export function fixtureText(name: FixtureName, file: string): string {
  return new TextDecoder().decode(fixtureBytes(name, file));
}

export function fixtureJSON<T = any>(name: FixtureName, file: string): T {
  return JSON.parse(fixtureText(name, file)) as T;
}
