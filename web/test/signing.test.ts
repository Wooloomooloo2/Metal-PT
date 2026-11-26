import { describe, expect, it } from "vitest";
import {
  base64urlDecode,
  base64urlEncode,
  deleteMessage,
  keyID,
  patchMessage,
  publishMessage,
  sha256Hex,
  verify,
} from "../src/lib/signing.ts";
import { FIXTURE_NAMES, fixtureBytes, fixtureJSON, type FixtureName } from "./fixtures.ts";

async function fixtureMessage(name: FixtureName, timestamp: string): Promise<string> {
  return publishMessage({
    bundle: await sha256Hex(fixtureBytes(name, "bundle.zip")),
    run: await sha256Hex(fixtureBytes(name, "run.json")),
    samples: await sha256Hex(fixtureBytes(name, "samples.csv")),
    summary: await sha256Hex(fixtureBytes(name, "summary.json")),
    timestamp,
  });
}

function flipKeyByte(key: string): string {
  const raw = base64urlDecode(key)!;
  raw[40] ^= 0x01;
  return base64urlEncode(raw);
}

describe("message builders (identical to SiteSigning.swift)", () => {
  it("publish", () => {
    expect(publishMessage({ bundle: "b", run: "r", samples: "s", summary: "m", timestamp: "t" })).toBe(
      "metal-pt-run\nb\nr\ns\nm\nt",
    );
  });
  it("patch", () => {
    expect(patchMessage({ id: "abc", bodySHA256: "h", timestamp: "t" })).toBe("metal-pt-patch\nabc\nh\nt");
  });
  it("delete", () => {
    expect(deleteMessage({ id: "abc", timestamp: "t" })).toBe("metal-pt-delete\nabc\nt");
  });
});

describe("helpers", () => {
  it("sha256Hex is lowercase hex", async () => {
    expect(await sha256Hex(new TextEncoder().encode("abc"))).toBe(
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
    );
  });

  it("base64url round-trips without padding", () => {
    const bytes = new Uint8Array([0xfb, 0xff, 0xfe, 0x00, 0x01]);
    const s = base64urlEncode(bytes);
    expect(s).toBe("-__-AAE");
    expect(Array.from(base64urlDecode(s)!)).toEqual(Array.from(bytes));
  });

  it("base64urlDecode refuses other alphabets and bad lengths", () => {
    expect(base64urlDecode("+/==")).toBeNull();
    expect(base64urlDecode("a")).toBeNull();
    expect(base64urlDecode("ab c")).toBeNull();
  });

  it.each(FIXTURE_NAMES)("keyID of %s's key is expected.json's keyID", async (name) => {
    const exp = fixtureJSON(name, "expected.json");
    expect(await keyID(exp.key)).toBe(exp.keyID);
  });
});

describe("verify against the fixtures' headers.json", () => {
  it.each(FIXTURE_NAMES)("%s: the signature verifies", async (name) => {
    const h = fixtureJSON(name, "headers.json");
    expect(await verify(h.key, await fixtureMessage(name, h.timestamp), h.signature)).toBe(true);
  });

  it.each(FIXTURE_NAMES)("%s: a 1-byte change to the bundle fails", async (name) => {
    const h = fixtureJSON(name, "headers.json");
    const bundle = fixtureBytes(name, "bundle.zip");
    bundle[bundle.length >> 1] ^= 0x01;
    const msg = publishMessage({
      bundle: await sha256Hex(bundle),
      run: await sha256Hex(fixtureBytes(name, "run.json")),
      samples: await sha256Hex(fixtureBytes(name, "samples.csv")),
      summary: await sha256Hex(fixtureBytes(name, "summary.json")),
      timestamp: h.timestamp,
    });
    expect(await verify(h.key, msg, h.signature)).toBe(false);
  });

  it("a changed timestamp, signature byte or key fails", async () => {
    const name = "system-warmup";
    const h = fixtureJSON(name, "headers.json");
    expect(await verify(h.key, await fixtureMessage(name, "2026-11-25T12:00:01Z"), h.signature)).toBe(false);
    const sig = base64urlDecode(h.signature)!;
    sig[10] ^= 0x01;
    expect(await verify(h.key, await fixtureMessage(name, h.timestamp), base64urlEncode(sig))).toBe(false);
    expect(await verify(flipKeyByte(h.key), await fixtureMessage(name, h.timestamp), h.signature)).toBe(false);
  });

  it("garbage key or signature is false, never a throw", async () => {
    expect(await verify("not-a-key", "m", "c2ln")).toBe(false);
    expect(await verify("", "m", "")).toBe(false);
    const h = fixtureJSON("gpu-only", "headers.json");
    expect(await verify(h.key, "m", "@@@")).toBe(false);
    expect(await verify(h.key, "m", base64urlEncode(new Uint8Array(63)))).toBe(false);
  });
});
