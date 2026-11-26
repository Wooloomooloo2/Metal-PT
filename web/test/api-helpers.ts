// Test helpers for the API: signing keys, signed requests, the golden fixtures as uploads, synthetic runs.
import { createExecutionContext, env } from "cloudflare:test";
import { createApp } from "../src/index.ts";
import type { Fetch } from "../src/oembed.ts";
import { recheck, type SummaryJson } from "../src/lib/recheck.ts";
import type { RunJson } from "../src/lib/run-json.ts";
import { base64urlEncode, deleteMessage, patchMessage, publishMessage, sha256Hex } from "../src/lib/signing.ts";
import { fixtureBytes, fixtureJSON, fixtureText, type FixtureName } from "./fixtures.ts";

export const BASE = "https://metal-pt.test";
/** Three minutes after the fixtures' signed timestamp (2026-11-25T12:00:00Z): fresh. */
export const NOW = new Date("2026-11-25T12:03:00Z");

export interface OEmbedCall {
  url: string;
}

/** oEmbed stub: answers like YouTube for a public video unless `status` says otherwise. */
export function oembedStub(opts: { status?: number; throws?: boolean; calls?: OEmbedCall[] } = {}): Fetch {
  return async (url) => {
    opts.calls?.push({ url });
    if (opts.throws) throw new Error("network down");
    const status = opts.status ?? 200;
    if (status !== 200) return new Response("Not Found", { status });
    return Response.json({ title: "Never Gonna Give You Up", author_name: "Rick Astley", type: "video" });
  };
}

export function app(opts: { now?: Date; fetch?: Fetch } = {}) {
  const a = createApp({ now: () => opts.now ?? NOW, fetch: opts.fetch ?? oembedStub() });
  return (req: Request) => a.fetch(req, env, createExecutionContext());
}

// MARK: - Keys

export interface TestKey {
  publicKey: string;
  sign(message: string): Promise<string>;
}

export async function newKey(): Promise<TestKey> {
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const raw = new Uint8Array((await crypto.subtle.exportKey("raw", pair.publicKey)) as ArrayBuffer);
  return {
    publicKey: base64urlEncode(raw),
    async sign(message) {
      const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(message));
      return base64urlEncode(new Uint8Array(sig));
    },
  };
}

export async function keyIdOf(publicKey: string): Promise<string> {
  const { base64urlDecode } = await import("../src/lib/signing.ts");
  return (await sha256Hex(base64urlDecode(publicKey)!)).slice(0, 16);
}

// MARK: - Uploads

export interface Upload {
  bundle: Uint8Array;
  run: Uint8Array;
  samples: Uint8Array;
  summary: Uint8Array;
}

const enc = (s: string) => new TextEncoder().encode(s);

export function fixtureUpload(name: FixtureName): Upload {
  return {
    bundle: fixtureBytes(name, "bundle.zip"),
    run: fixtureBytes(name, "run.json"),
    samples: fixtureBytes(name, "samples.csv"),
    summary: fixtureBytes(name, "summary.json"),
  };
}

export interface PublishOptions {
  /** Headers to leave out or replace (null removes). */
  headers?: Record<string, string | null>;
  /** Parts to leave out. */
  omit?: (keyof Upload)[];
  /** Signs over this bundle hash instead of the bundle's own. */
  bundleHash?: string;
  timestamp?: string;
}

function form(u: Upload, omit: (keyof Upload)[] = []): FormData {
  const f = new FormData();
  const add = (name: string, part: keyof Upload, file: string, type: string) => {
    if (!omit.includes(part)) f.append(name, new File([u[part]], file, { type }));
  };
  add("bundle", "bundle", "run.mptrun.zip", "application/zip");
  add("run.json", "run", "run.json", "application/json");
  add("samples.csv", "samples", "samples.csv", "text/csv");
  add("summary.json", "summary", "summary.json", "application/json");
  return f;
}

function withHeaders(base: Record<string, string>, over: Record<string, string | null> = {}): Headers {
  const h = new Headers();
  for (const [k, v] of Object.entries({ ...base, ...over })) if (v !== null) h.set(k, v);
  return h;
}

/** A publish request signed by `key` (or, for a fixture with no key, by the fixture's own headers.json). */
export async function publishRequest(u: Upload, key: TestKey, o: PublishOptions = {}): Promise<Request> {
  const timestamp = o.timestamp ?? "2026-11-25T12:00:00Z";
  const bundleHash = o.bundleHash ?? (await sha256Hex(u.bundle));
  const message = publishMessage({
    bundle: bundleHash,
    run: await sha256Hex(u.run),
    samples: await sha256Hex(u.samples),
    summary: await sha256Hex(u.summary),
    timestamp,
  });
  const headers = withHeaders(
    {
      "MPT-Key": key.publicKey,
      "MPT-Timestamp": timestamp,
      "MPT-Signature": await key.sign(message),
      "MPT-Bundle-SHA256": bundleHash,
    },
    o.headers,
  );
  return new Request(`${BASE}/api/v1/runs`, { method: "POST", body: form(u, o.omit), headers });
}

/** The golden fixture exactly as the app signed it (headers.json). */
export async function fixtureRequest(name: FixtureName): Promise<Request> {
  const h = fixtureJSON<{ key: string; timestamp: string; signature: string }>(name, "headers.json");
  const u = fixtureUpload(name);
  const headers = new Headers({
    "MPT-Key": h.key,
    "MPT-Timestamp": h.timestamp,
    "MPT-Signature": h.signature,
    "MPT-Bundle-SHA256": await sha256Hex(u.bundle),
  });
  return new Request(`${BASE}/api/v1/runs`, { method: "POST", body: form(u), headers });
}

export async function patchRequest(id: string, body: unknown, key: TestKey, timestamp = "2026-11-25T12:00:00Z"): Promise<Request> {
  const bytes = enc(JSON.stringify(body));
  const sig = await key.sign(patchMessage({ id, bodySHA256: await sha256Hex(bytes), timestamp }));
  return new Request(`${BASE}/api/v1/runs/${id}`, {
    method: "PATCH",
    body: bytes,
    headers: { "content-type": "application/json", "MPT-Key": key.publicKey, "MPT-Timestamp": timestamp, "MPT-Signature": sig },
  });
}

export async function deleteRequest(id: string, key: TestKey, timestamp = "2026-11-25T12:00:00Z"): Promise<Request> {
  const sig = await key.sign(deleteMessage({ id, timestamp }));
  return new Request(`${BASE}/api/v1/runs/${id}`, {
    method: "DELETE",
    headers: { "MPT-Key": key.publicKey, "MPT-Timestamp": timestamp, "MPT-Signature": sig },
  });
}

// MARK: - Synthetic runs

const HEADER = fixtureText("system-warmup", "samples.csv").split("\n")[0];
const COLUMNS = HEADER.split(",");

export interface SyntheticOptions {
  seconds?: number;
  steadyStartS?: number | null;
  fps?: (s: number) => number | null;
  watts?: (s: number) => number | null;
  onAC?: (s: number) => boolean;
  elapsed?: (s: number) => number;
  title?: string;
  exe?: string;
  chip?: string;
  gpuCores?: number | null;
  runtime?: string | null;
  graphics?: Record<string, unknown> | null;
  user?: Record<string, unknown>;
  limiterPrimary?: string | null;
  powerMode?: string;
  /** Edits run.json after it is built. */
  edit?: (run: Record<string, any>) => void;
  /** Edits summary.json after it is computed (so it can be made not to match). */
  editSummary?: (s: Record<string, any>) => void;
}

let serial = 0;

/** A run as the app would upload it: samples.csv with the app's columns, summary.json computed to match. */
export function syntheticUpload(o: SyntheticOptions = {}): Upload & { runJson: RunJson; summaryJson: SummaryJson } {
  serial += 1;
  const seconds = o.seconds ?? 120;
  const steadyStartS = o.steadyStartS === undefined ? 10 : o.steadyStartS;
  const fps = o.fps ?? ((s: number) => 60 + (s % 7) * 0.5);
  const watts = o.watts ?? ((s: number) => 40 + (s % 5));
  const onAC = o.onAC ?? (() => true);
  const elapsed = o.elapsed ?? ((s: number) => s);
  const lines = [HEADER];
  const start = Date.parse("2026-11-20T12:00:00Z");
  for (let s = 1; s <= seconds; s++) {
    const f = fps(s);
    const w = watts(s);
    const row: Record<string, string> = {
      t: new Date(start + s * 1000).toISOString(),
      elapsed_s: elapsed(s).toFixed(1),
      fps: f === null ? "" : f.toFixed(1),
      fps_app: f === null ? "" : o.exe ?? "game.exe",
      gpu_w: "12.50",
      smc_PSTR_w: w === null ? "" : w.toFixed(2),
      cpu_p_util_pct: "40.0",
      gpu_busy_pct: "90.0",
      temp_max_c: "70.1",
      on_ac: onAC(s) ? "1" : "0",
      thermal_state: "nominal",
      gpu_mhz: "1400",
      mem_pressure: "normal",
    };
    lines.push(COLUMNS.map((c) => row[c] ?? "").join(","));
  }
  const samples = lines.join("\n") + "\n";
  const run: Record<string, any> = {
    appVersion: "0.2.0",
    end: new Date(start + seconds * 1000).toISOString().replace(/\.000Z$/, "Z"),
    fpsSource: "log",
    game: { exe: o.exe ?? "game.exe", title: o.title ?? "Synthetic Game" },
    graphics:
      o.graphics === undefined
        ? { frameGeneration: false, height: 1080, preset: "high", upscaler: "off", width: 1920 }
        : o.graphics,
    machine: {
      chip: o.chip ?? "Apple M4 Max",
      gpuCores: o.gpuCores === undefined ? 40 : o.gpuCores,
      memoryGB: 48,
      modelID: "Mac16,5",
      osBuild: "25B78",
      osVersion: "26.1",
    },
    schema: 1,
    settings: { onACAtStart: true, powerMode: o.powerMode ?? "high" },
    stack: o.runtime === null ? {} : { graphics: ["DXMT"], runtime: o.runtime ?? "Protium", runtimeVersion: "1.2" },
    start: "2026-11-20T12:00:00Z",
    steadyEndS: seconds,
    steadyStartS: steadyStartS,
    user: { gameSettings: "", label: `synthetic ${serial}`, notes: "", ...(o.user ?? {}) },
    warnings: [],
  };
  o.edit?.(run);
  const runText = JSON.stringify(run);
  const r = recheck(run as RunJson, samples);
  const summary: Record<string, any> = {
    fpsPerWatt: r.fpsPerWatt,
    limiter: { primary: o.limiterPrimary === undefined ? "gpu" : o.limiterPrimary, verdict: "Mostly the GPU" },
    meanSystemW: r.powerSource === "system" ? r.meanW : null,
    medianFPS: r.medianFPS,
    p1LowFPS: null,
    powerSource: r.powerSource,
    steadyEndS: run.steadyEndS,
    steadyStartS: run.steadyStartS,
    summaryVersion: 1,
  };
  o.editSummary?.(summary);
  // A unique stand-in for the zip (the Worker never opens it).
  const bundle = enc(`PK synthetic bundle ${serial} ${crypto.randomUUID()}`);
  return {
    bundle,
    run: enc(runText),
    samples: enc(samples),
    summary: enc(JSON.stringify(summary)),
    runJson: run as RunJson,
    summaryJson: summary as SummaryJson,
  };
}
