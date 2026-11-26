import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { MAX_SAMPLES_BYTES, MAX_STEADY_SECONDS, UPLOADS_PER_HOUR } from "../src/config.ts";
import { isDigestMismatch } from "../src/api/publish.ts";
import { checkVideo } from "../src/oembed.ts";
import { parseSamples, recheckSamples } from "../src/lib/recheck.ts";
import type { RunJson } from "../src/lib/run-json.ts";
import { sha256Hex } from "../src/lib/signing.ts";
import {
  app,
  BASE,
  deleteRequest,
  fixtureRequest,
  fixtureUpload,
  keyIdOf,
  newKey,
  oembedStub,
  patchRequest,
  publishRequest,
  syntheticUpload,
  type OEmbedCall,
  type TestKey,
  type Upload,
} from "./api-helpers.ts";
import { FIXTURE_NAMES, fixtureJSON } from "./fixtures.ts";

// Storage is shared by the tests in this file: start each from empty tables.
beforeEach(async () => {
  await env.DB.batch(
    ["reports", "runs", '"groups"', "game_aliases", "games", "macs"].map((t) => env.DB.prepare(`DELETE FROM ${t}`)),
  );
  const objects = (await env.RUNS.list()).objects.map((o) => o.key);
  if (objects.length > 0) await env.RUNS.delete(objects);
});

type Body = Record<string, any>;

async function send(req: Request, opts: Parameters<typeof app>[0] = {}): Promise<{ status: number; body: Body }> {
  const res = await app(opts)(req);
  return { status: res.status, body: (await res.json()) as Body };
}

async function publishOK(u: Upload, key: TestKey, opts: Parameters<typeof app>[0] = {}): Promise<Body> {
  const { status, body } = await send(await publishRequest(u, key), opts);
  expect(status, JSON.stringify(body)).toBe(201);
  return body;
}

async function runRow(id: string): Promise<Body> {
  return (await env.DB.prepare("SELECT * FROM runs WHERE id = ?").bind(id).first<Body>())!;
}

async function groupRow(key: string): Promise<Body | null> {
  return env.DB.prepare(`SELECT * FROM "groups" WHERE group_key = ?`).bind(key).first<Body>();
}

describe("POST /api/v1/runs: the golden fixtures", () => {
  it.each(FIXTURE_NAMES)("%s publishes (201) with the re-checked numbers", async (name) => {
    const exp = fixtureJSON(name, "expected.json");
    const run = fixtureJSON<RunJson>(name, "run.json");
    const { status, body } = await send(await fixtureRequest(name));
    expect(status, JSON.stringify(body)).toBe(201);
    expect(body.id).toMatch(/^[a-z0-9]{10}$/);
    expect(body.url).toBe(`${BASE}/run/${body.id}`);

    const row = await runRow(body.id);
    expect(row.key_id).toBe(exp.keyID);
    expect(row.bundle_sha256).toBe(await sha256Hex(fixtureUpload(name).bundle));
    expect(row.median_fps).toBeCloseTo(exp.medianFPS, 6);
    expect(row.fps_per_watt).toBeCloseTo(exp.fpsPerWatt, 6);
    expect(row.power_source).toBe(exp.powerSource);
    if (exp.powerSource === "system") expect(row.mean_system_w).toBeCloseTo(exp.meanSystemW, 6);
    else expect(row.mean_system_w).toBeNull();
    expect(row.limiter_primary).toBe(exp.limiter.primary);
    expect(row.limiter_verdict).toBe(exp.limiter.verdict);
    expect(row.steady_s).toBeGreaterThanOrEqual(60);
    expect(row.mac_key).toBe("m4-max-40");
    expect(row.setup_key).toBe("protium-dxmt");
    expect(row.setup_label).toBe("Protium · DXMT");
    expect(row.chip).toBe("Apple M4 Max");
    expect(row.gpu_cores).toBe(40);
    expect(row.memory_gb).toBe(48);
    expect(row.recorded).toBe("2026-11-20T12:00:00Z");
    expect(row.recorded_app).toBe(run.game.exe);
    expect(row.preset).toBe(run.graphics!.preset);
    expect(row.width).toBe(run.graphics!.width);
    expect(row.height).toBe(run.graphics!.height);
    expect(row.upscaler).toBe(run.graphics!.upscaler);
    expect(row.upscaler_mode).toBe(run.graphics!.upscalerMode ?? null);
    expect(row.frame_gen).toBe("off");
    expect(row.on_ac).toBe(1);
    expect(row.power_mode).toBe("high");
    expect(row.published).toBe("2026-11-25T12:03:00Z");
    expect(row.hidden).toBe(0);
    expect(row.label).toBe(run.user!.label);
    expect(row.notes).toBeNull();

    const series = JSON.parse(row.fps_series);
    expect(series.v).toBe(1);
    expect(series.points.length).toBeGreaterThan(100);
    expect(series.points.length).toBeLessThanOrEqual(300);

    const game = (await env.DB.prepare("SELECT * FROM games WHERE id = ?").bind(row.game_id).first<Body>())!;
    expect(game.title).toBe(run.game.title);
    expect(row.group_key.startsWith(`${game.id}|m4-max-40|protium-dxmt|`)).toBe(true);

    // The key is registered from its bytes; the zip is in R2 under the run's id, byte for byte.
    const mac = (await env.DB.prepare("SELECT * FROM macs WHERE key_id = ?").bind(exp.keyID).first<Body>())!;
    expect(mac.public_key).toBe(exp.key);
    const obj = await env.RUNS.get(`runs/${body.id}.zip`);
    expect(new Uint8Array(await obj!.arrayBuffer())).toEqual(fixtureUpload(name).bundle);

    // One counted run: a group row, not enough for a typical.
    const g = (await groupRow(row.group_key))!;
    expect(g.runs).toBe(1);
    expect(g.macs).toBe(1);
    expect(g.typical_fps).toBeNull();
    expect(g.capped_at).toBe(name === "capped-60" ? 60 : null);
  });

  it("system-warmup: the video is checked with oEmbed and only its id, title and channel are kept", async () => {
    const calls: OEmbedCall[] = [];
    const { status, body } = await send(await fixtureRequest("system-warmup"), { fetch: oembedStub({ calls }) });
    expect(status).toBe(201);
    expect(body.notice).toBeUndefined();
    expect(calls.map((c) => c.url)).toEqual([
      "https://www.youtube.com/oembed?url=https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3DdQw4w9WgXcQ&format=json",
    ]);
    const row = await runRow(body.id);
    expect(row.video_id).toBe("dQw4w9WgXcQ");
    expect(row.video_title).toBe("Never Gonna Give You Up");
    expect(row.video_channel).toBe("Rick Astley");
    expect(JSON.stringify(row)).not.toContain("youtube.com");
  });

  it("the Steam ID matches the game, and the run's title becomes an alias", async () => {
    const { body } = await send(await fixtureRequest("system-warmup"));
    const game = (await env.DB.prepare("SELECT g.* FROM games g JOIN runs r ON r.game_id = g.id WHERE r.id = ?").bind(body.id).first<Body>())!;
    expect(game.steam_id).toBe("1151640");
    expect(game.slug).toBe("horizon-zero-dawn");
    // A differently titled run with the same Steam ID lands on the same game.
    const u = syntheticUpload({ title: "HZD Remastered?", edit: (r) => (r.game.storeAppID = "steam:1151640") });
    const b2 = await publishOK(u, await newKey());
    expect((await runRow(b2.id)).game_id).toBe(game.id);
    const aliases = await env.DB.prepare("SELECT alias_norm FROM game_aliases WHERE game_id = ? ORDER BY alias_norm").bind(game.id).all();
    expect(aliases.results.map((a) => a.alias_norm)).toEqual(["horizon zero dawn", "hzd remastered"]);
  });

  it("titles match by their normalised form; a new title is a new game with a unique slug", async () => {
    const k = await newKey();
    const a = await publishOK(syntheticUpload({ title: "Baldur's Gate 3" }), k);
    const b = await publishOK(syntheticUpload({ title: "baldurs gate™ 3" }), k);
    expect((await runRow(b.id)).game_id).toBe((await runRow(a.id)).game_id);
    const c = await publishOK(syntheticUpload({ title: "Baldurs-Gate 3!" }), k); // normalises differently: "baldursgate 3"
    const slugs = await env.DB.prepare("SELECT slug FROM games ORDER BY id").all();
    expect(slugs.results.map((s) => s.slug)).toEqual(["baldurs-gate-3", "baldurs-gate-3-2"]);
    expect((await runRow(c.id)).game_id).not.toBe((await runRow(a.id)).game_id);
  });

  it("an all-CJK title gets a fallback slug", async () => {
    const b = await publishOK(syntheticUpload({ title: "原神" }), await newKey());
    const g = (await env.DB.prepare("SELECT g.slug FROM games g JOIN runs r ON r.game_id = g.id WHERE r.id = ?").bind(b.id).first<Body>())!;
    expect(g.slug).toMatch(/^game-[a-z0-9]{6}$/);
  });

  it("stores the key re-encoded from its bytes, never the submitted text", async () => {
    // Same bytes, non-canonical base64url (the last character's unused low bits set).
    const k = await newKey();
    const last = k.publicKey.at(-1)!;
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    const odd = k.publicKey.slice(0, -1) + alphabet[alphabet.indexOf(last) | 1];
    expect(odd).not.toBe(k.publicKey);
    const req = await publishRequest(syntheticUpload(), k, { headers: { "MPT-Key": odd } });
    const { status } = await send(req);
    expect(status).toBe(201);
    const mac = (await env.DB.prepare("SELECT * FROM macs").first<Body>())!;
    expect(mac.public_key).toBe(k.publicKey);
    expect(mac.key_id).toBe(await keyIdOf(k.publicKey));
  });
});

describe("POST: the same bundle twice (Review Focus 2)", () => {
  it("409 with the first run's id and URL", async () => {
    const first = await send(await fixtureRequest("gpu-only"));
    expect(first.status).toBe(201);
    const again = await send(await fixtureRequest("gpu-only"));
    expect(again.status).toBe(409);
    expect(again.body).toMatchObject({ code: "already_published", id: first.body.id, url: first.body.url });
    expect(typeof again.body.message).toBe("string");
    expect((await env.DB.prepare("SELECT count(*) AS n FROM runs").first<Body>())!.n).toBe(1);
  });
});

describe("POST: every §4.C failure has its code", () => {
  async function expectError(req: Request, status: number, code: string, opts: Parameters<typeof app>[0] = {}) {
    const r = await send(req, opts);
    expect(r.status, JSON.stringify(r.body)).toBe(status);
    expect(r.body.code).toBe(code);
    expect(typeof r.body.message).toBe("string");
    expect(r.body.message.length).toBeGreaterThan(10);
    expect((await env.DB.prepare("SELECT count(*) AS n FROM runs").first<Body>())!.n).toBe(0);
    return r.body;
  }

  it("size: over 25 MB", async () => {
    const req = await publishRequest(syntheticUpload(), await newKey());
    const big = new Request(req, { headers: new Headers([...req.headers, ["content-length", String(26 * 1024 * 1024)]]) });
    await expectError(big, 413, "too_large");
  });

  it("headers: missing", async () => {
    const k = await newKey();
    for (const h of ["MPT-Key", "MPT-Timestamp", "MPT-Signature", "MPT-Bundle-SHA256"]) {
      const body = await expectError(await publishRequest(syntheticUpload(), k, { headers: { [h]: null } }), 400, "missing_header");
      expect(body.message).toContain(h);
    }
  });

  it("headers: a key that is not a P-256 point", async () => {
    await expectError(await publishRequest(syntheticUpload(), await newKey(), { headers: { "MPT-Key": "AAAA" } }), 400, "bad_key");
  });

  it("parts: missing", async () => {
    const body = await expectError(await publishRequest(syntheticUpload(), await newKey(), { omit: ["summary"] }), 400, "missing_part");
    expect(body.message).toContain("summary.json");
  });

  it("timestamp: unreadable, and more than 10 minutes off", async () => {
    const k = await newKey();
    await expectError(await publishRequest(syntheticUpload(), k, { timestamp: "yesterday" }), 400, "bad_timestamp");
    await expectError(await publishRequest(syntheticUpload(), k, { timestamp: "2026-11-25T11:52:59Z" }), 401, "stale_timestamp");
    await expectError(await publishRequest(syntheticUpload(), k, { timestamp: "2026-11-25T12:13:01Z" }), 401, "stale_timestamp");
    // Just inside the window.
    expect((await send(await publishRequest(syntheticUpload(), k, { timestamp: "2026-11-25T11:53:01Z" }))).status).toBe(201);
  });

  it("the fixtures' timestamp is stale a day later", async () => {
    await expectError(await fixtureRequest("gpu-only"), 401, "stale_timestamp", { now: new Date("2026-11-26T12:00:00Z") });
  });

  it("signature: a part changed after signing, or another key's signature", async () => {
    const u = syntheticUpload();
    const k = await newKey();
    const req = await publishRequest(u, k);
    const tampered: Upload = { ...u, run: new TextEncoder().encode(new TextDecoder().decode(u.run).replace("synthetic", "Synthetic")) };
    const sig = req.headers.get("MPT-Signature")!;
    await expectError(await publishRequest(tampered, k, { headers: { "MPT-Signature": sig } }), 401, "bad_signature");
    const other = await newKey();
    await expectError(await publishRequest(u, k, { headers: { "MPT-Key": other.publicKey } }), 401, "bad_signature");
  });

  it("part hashes: a bundle that is not the signed one (enforced by R2's SHA-256 check)", async () => {
    const u = syntheticUpload();
    const wrong = await sha256Hex(new TextEncoder().encode("a different zip"));
    await expectError(await publishRequest(u, await newKey(), { bundleHash: wrong }), 422, "bundle_mismatch");
    expect((await env.RUNS.list({ prefix: "runs/" })).objects.length).toBe(0);
  });

  it("banned key", async () => {
    const k = await newKey();
    await env.DB.prepare("INSERT INTO macs (key_id, public_key, first_seen, banned) VALUES (?, ?, 'x', 1)")
      .bind(await keyIdOf(k.publicKey), k.publicKey)
      .run();
    await expectError(await publishRequest(syntheticUpload(), k), 403, "banned");
  });

  it(`rate limit: ${UPLOADS_PER_HOUR} runs in the last hour`, async () => {
    const k = await newKey();
    const keyId = await keyIdOf(k.publicKey);
    await env.DB.batch([
      env.DB.prepare("INSERT INTO macs (key_id, public_key, first_seen) VALUES (?, ?, 'x')").bind(keyId, k.publicKey),
      env.DB.prepare("INSERT INTO games (id, slug, title, created) VALUES (1, 'g', 'G', 'x')"),
    ]);
    const insert = (i: number, published: string) =>
      env.DB.prepare(
        "INSERT INTO runs (id, game_id, key_id, bundle_sha256, published, mac_key, setup_key, setup_label, group_key) VALUES (?, 1, ?, ?, ?, 'unknown', 'unknown', 'U', 'g')",
      ).bind(`rate${i}`, keyId, `h${i}`, published);
    // 29 in the last hour and one from earlier: still allowed.
    await env.DB.batch([
      ...Array.from({ length: UPLOADS_PER_HOUR - 1 }, (_, i) => insert(i, "2026-11-25T11:30:00Z")),
      insert(99, "2026-11-25T11:02:59Z"),
    ]);
    expect((await send(await publishRequest(syntheticUpload(), k))).status).toBe(201);
    const r = await send(await publishRequest(syntheticUpload(), k));
    expect(r.status).toBe(429);
    expect(r.body.code).toBe("rate_limited");
  });

  it("JSON shape: not JSON, wrong types", async () => {
    const k = await newKey();
    const u = syntheticUpload();
    await expectError(await publishRequest({ ...u, run: new TextEncoder().encode("{not json") }, k), 422, "bad_json");
    await expectError(await publishRequest(syntheticUpload({ edit: (r) => (r.machine.gpuCores = "40") }), k), 422, "bad_json");
    await expectError(await publishRequest({ ...u, summary: new TextEncoder().encode('{"summaryVersion":1,"powerSource":"mains"}') }, k), 422, "bad_json");
  });

  it("JSON shape: schema other than 1", async () => {
    await expectError(await publishRequest(syntheticUpload({ edit: (r) => (r.schema = 2) }), await newKey()), 422, "unsupported_schema");
  });

  it("required: app version", async () => {
    await expectError(await publishRequest(syntheticUpload({ edit: (r) => (r.appVersion = "0.1.9") }), await newKey()), 422, "app_too_old");
  });

  it("required: all four graphics fields (a mode only when an upscaler is on)", async () => {
    const k = await newKey();
    const body = await expectError(
      await publishRequest(syntheticUpload({ graphics: { preset: "high", upscaler: "fsr", frameGeneration: true } }), k),
      422,
      "missing_graphics",
    );
    expect(body.missing).toEqual(["resolution", "upscaler mode"]);
    await expectError(await publishRequest(syntheticUpload({ graphics: null }), k), 422, "missing_graphics");
    await expectError(
      await publishRequest(syntheticUpload({ graphics: { preset: "epic", width: 1920, height: 1080, upscaler: "off", frameGeneration: false } }), k),
      422,
      "missing_graphics",
    );
  });

  it("required: a game title or exe", async () => {
    await expectError(await publishRequest(syntheticUpload({ title: "", exe: "" }), await newKey()), 422, "missing_game");
  });

  it("required: an FPS source", async () => {
    await expectError(await publishRequest(syntheticUpload({ edit: (r) => (r.fpsSource = "none") }), await newKey()), 422, "no_fps");
  });

  it("required: ≥ 60 steady seconds with FPS", async () => {
    await expectError(await publishRequest(syntheticUpload({ seconds: 65, steadyStartS: 10 }), await newKey()), 422, "too_short");
  });

  it("re-check: summary.json numbers that samples.csv does not give", async () => {
    const body = await expectError(
      await publishRequest(syntheticUpload({ editSummary: (s) => (s.medianFPS += 1) }), await newKey()),
      422,
      "numbers_mismatch",
    );
    expect(body.message).toContain("median FPS");
  });

  it("sanity: impossible FPS, power, time going backwards, gaps, too many rows", async () => {
    const k = await newKey();
    await expectError(await publishRequest(syntheticUpload({ fps: () => 1500 }), k), 422, "implausible");
    await expectError(await publishRequest(syntheticUpload({ watts: () => 1 }), k), 422, "implausible");
    await expectError(await publishRequest(syntheticUpload({ elapsed: (s) => (s === 50 ? 48.5 : s) }), k), 422, "implausible");
    await expectError(await publishRequest(syntheticUpload({ seconds: 120, elapsed: (s) => (s < 60 ? s : s + 10) }), k), 422, "implausible");
    await expectError(await publishRequest(syntheticUpload({ seconds: 200, elapsed: (s) => s / 2 }), k), 422, "implausible");
  });
});

describe("POST: scrub (spec §4.C.5) and stored fields", () => {
  it("home paths and host names are scrubbed from every text field; notes kept only when sent", async () => {
    const u = syntheticUpload({
      title: "Game from /Users/mark/Games",
      user: {
        label: "Run on Mark's MacBook Pro",
        gameSettings: "config at /Users/mark/Library/x.ini",
        notes: "ssh Marks-MacBook-Pro.local first",
      },
    });
    const b = await publishOK(u, await newKey());
    const row = await runRow(b.id);
    expect(row.label).toBe("Run on <host>");
    expect(row.settings_text).toBe("config at ~/Library/x.ini");
    expect(row.notes).toBe("ssh <host> first");
    const game = (await env.DB.prepare("SELECT title FROM games WHERE id = ?").bind(row.game_id).first<Body>())!;
    expect(game.title).toBe("Game from ~/Games");
  });

  it("on battery for most of the steady window -> on_ac 0, and the run is not counted", async () => {
    const b = await publishOK(syntheticUpload({ onAC: (s) => s < 30 }), await newKey());
    const row = await runRow(b.id);
    expect(row.on_ac).toBe(0);
    expect(await groupRow(row.group_key)).toBeNull();
  });

  it("unknown bucket: no GPU cores -> mac_key unknown, published, never in a group", async () => {
    const b = await publishOK(syntheticUpload({ gpuCores: null }), await newKey());
    const row = await runRow(b.id);
    expect(row.mac_key).toBe("unknown");
    expect(await groupRow(row.group_key)).toBeNull();
  });
});

describe("POST: video links (Review Focus 3)", () => {
  const url = "https://youtu.be/dQw4w9WgXcQ";

  it.each([
    ["not YouTube", "https://vimeo.com/12345678", {}],
    ["private or deleted (oEmbed 401)", url, { status: 401 }],
    ["missing (oEmbed 404)", url, { status: 404 }],
    ["YouTube unreachable", url, { throws: true }],
  ] as const)("%s: published without the link, the reply says why, the URL is never echoed", async (_, link, stub) => {
    const u = syntheticUpload({ user: { videoURL: link } });
    const { status, body } = await send(await publishRequest(u, await newKey()), { fetch: oembedStub(stub) });
    expect(status).toBe(201);
    expect(body.notice).toMatch(/^Published without the video link: /);
    expect(JSON.stringify(body)).not.toContain(link);
    expect(JSON.stringify(body)).not.toContain("dQw4w9WgXcQ");
    const row = await runRow(body.id);
    expect(row.video_id).toBeNull();
    expect(row.video_title).toBeNull();
  });

  it("oEmbed that does not answer within the timeout counts as unreachable", async () => {
    const never = () => new Promise<Response>(() => {});
    const v = await checkVideo(url, never, 20);
    expect(v).toMatchObject({ ok: false, reason: "unreachable" });
  });
});

describe("groups (spec §4.E)", () => {
  it("3 runs from 2 Macs: typical and range cached; Review Focus 1 weighting", async () => {
    const a = await newKey(), b = await newKey();
    const ids = [
      (await publishOK(syntheticUpload({ fps: () => 50 }), a)).id,
      (await publishOK(syntheticUpload({ fps: () => 52 }), a)).id,
      (await publishOK(syntheticUpload({ fps: () => 54 }), b)).id,
    ];
    const g = (await groupRow((await runRow(ids[0])).group_key))!;
    expect(g.runs).toBe(3);
    expect(g.macs).toBe(2);
    // A 0.5 + 0.5, B 1: the median lands exactly between 52 and 54.
    expect(g.typical_fps).toBe(53);
    expect(g.p25_fps).toBe(51);
    expect(g.p75_fps).toBe(54);
    expect(g.typical_fpw).not.toBeNull();
  });

  it("outliers are marked on the runs at ≥ 5", async () => {
    const ids: string[] = [];
    for (const f of [50, 51, 52, 53, 300]) ids.push((await publishOK(syntheticUpload({ fps: () => f, watts: () => 50 }), await newKey())).id);
    expect((await runRow(ids[4])).outlier).toBe(1);
    expect((await runRow(ids[0])).outlier).toBe(0);
    const g = (await groupRow((await runRow(ids[0])).group_key))!;
    expect(g.outliers).toBe(1);
    expect(g.runs).toBe(4);
  });
});

describe("PATCH /api/v1/runs/:id", () => {
  async function published(key: TestKey) {
    return (await publishOK(syntheticUpload(), key)).id as string;
  }

  it("the publishing key sets, then clears, the video link", async () => {
    const k = await newKey();
    const id = await published(k);
    const set = await send(await patchRequest(id, { videoURL: "https://www.youtube.com/shorts/dQw4w9WgXcQ" }, k));
    expect(set.status).toBe(200);
    expect(set.body.video).toEqual({ id: "dQw4w9WgXcQ", title: "Never Gonna Give You Up", channel: "Rick Astley" });
    expect((await runRow(id)).video_id).toBe("dQw4w9WgXcQ");
    const clear = await send(await patchRequest(id, { videoURL: null }, k));
    expect(clear.status).toBe(200);
    expect((await runRow(id)).video_id).toBeNull();
  });

  it("another key: 403, nothing changes", async () => {
    const id = await published(await newKey());
    const r = await send(await patchRequest(id, { videoURL: "https://youtu.be/dQw4w9WgXcQ" }, await newKey()));
    expect(r.status).toBe(403);
    expect(r.body.code).toBe("not_yours");
    expect((await runRow(id)).video_id).toBeNull();
  });

  it("an unknown run: 404", async () => {
    const r = await send(await patchRequest("nosuchrun2", { videoURL: null }, await newKey()));
    expect(r.status).toBe(404);
    expect(r.body.code).toBe("not_found");
  });

  it("a bad or unavailable link: 422, the old link stays, the URL is not echoed", async () => {
    const k = await newKey();
    const id = await published(k);
    await send(await patchRequest(id, { videoURL: "https://youtu.be/dQw4w9WgXcQ" }, k));
    const bad = await send(await patchRequest(id, { videoURL: "https://example.com/watch?v=dQw4w9WgXcQ" }, k));
    expect(bad.status).toBe(422);
    expect(bad.body.code).toBe("bad_video_link");
    expect(JSON.stringify(bad.body)).not.toContain("example.com");
    const gone = await send(await patchRequest(id, { videoURL: "https://youtu.be/aaaaaaaaaaa" }, k), { fetch: oembedStub({ status: 404 }) });
    expect(gone.status).toBe(422);
    expect(gone.body.code).toBe("video_unavailable");
    expect((await runRow(id)).video_id).toBe("dQw4w9WgXcQ");
  });

  it("a body changed after signing: 401", async () => {
    const k = await newKey();
    const id = await published(k);
    const req = await patchRequest(id, { videoURL: null }, k);
    const forged = new Request(req, { body: JSON.stringify({ videoURL: "https://youtu.be/aaaaaaaaaaa" }) });
    const r = await send(forged);
    expect(r.status).toBe(401);
    expect(r.body.code).toBe("bad_signature");
  });

  it("a body that is not { videoURL }: 400", async () => {
    const k = await newKey();
    const id = await published(k);
    const r = await send(await patchRequest(id, { videoURL: 5 }, k));
    expect(r.status).toBe(400);
    expect(r.body.code).toBe("bad_json");
  });
});

describe("DELETE /api/v1/runs/:id", () => {
  it("another key: 403, the run stays", async () => {
    const id = (await publishOK(syntheticUpload(), await newKey())).id;
    const r = await send(await deleteRequest(id, await newKey()));
    expect(r.status).toBe(403);
    expect(r.body.code).toBe("not_yours");
    expect(await runRow(id)).toBeDefined();
  });

  it("the publishing key removes the run, its zip and its reports", async () => {
    const k = await newKey();
    const id = (await publishOK(syntheticUpload(), k)).id;
    await env.DB.prepare("INSERT INTO reports (run_id, reason, created) VALUES (?, 'other', 'x')").bind(id).run();
    const r = await send(await deleteRequest(id, k));
    expect(r.status).toBe(200);
    expect(r.body).toEqual({ id, deleted: true });
    expect(await env.DB.prepare("SELECT id FROM runs WHERE id = ?").bind(id).first()).toBeNull();
    expect(await env.RUNS.get(`runs/${id}.zip`)).toBeNull();
    expect((await env.DB.prepare("SELECT count(*) AS n FROM reports").first<Body>())!.n).toBe(0);
    expect((await send(await deleteRequest(id, k))).status).toBe(404);
  });

  it("a signature over another id: 401", async () => {
    const k = await newKey();
    const id = (await publishOK(syntheticUpload(), k)).id;
    const req = await deleteRequest("otherrunid", k);
    const r = await send(new Request(`${BASE}/api/v1/runs/${id}`, { method: "DELETE", headers: req.headers }));
    expect(r.status).toBe(401);
  });

  it("deleting the last counted run removes the group row (Review Focus 4)", async () => {
    const k = await newKey();
    const id = (await publishOK(syntheticUpload(), k)).id;
    const key = (await runRow(id)).group_key;
    expect(await groupRow(key)).not.toBeNull();
    expect((await send(await deleteRequest(id, k))).status).toBe(200);
    expect(await groupRow(key)).toBeNull();
  });

  it("deleting a run below the minimum clears the typical (no stale figure)", async () => {
    const a = await newKey(), b = await newKey();
    await publishOK(syntheticUpload({ fps: () => 50 }), a);
    const second = (await publishOK(syntheticUpload({ fps: () => 52 }), a)).id;
    await publishOK(syntheticUpload({ fps: () => 54 }), b);
    const key = (await runRow(second)).group_key;
    expect((await groupRow(key))!.typical_fps).toBe(53);
    expect((await send(await deleteRequest(second, a))).status).toBe(200);
    const g = (await groupRow(key))!;
    expect(g.runs).toBe(2);
    expect(g.typical_fps).toBeNull();
    expect(g.p25_fps).toBeNull();
  });
});

describe("a 60-minute run (CPU budget, spec §4.J)", () => {
  it("publishes, and logs the parse and re-check timing", async ({ annotate }) => {
    const u = syntheticUpload({ seconds: 3600, steadyStartS: 30, fps: (s) => 55 + (s % 11) * 0.7, watts: (s) => 45 + (s % 13) * 0.3 });
    expect(u.samples.length).toBeGreaterThan(300_000);
    const text = new TextDecoder().decode(u.samples);

    // Note: in workerd, timers only advance across I/O, so these in-runtime numbers can read 0; the Node
    // measurement of the same code is in the Task 3 report (scripts in the report).
    const t0 = performance.now();
    const s = parseSamples(text);
    const t1 = performance.now();
    const r = recheckSamples(u.runJson, s);
    const t2 = performance.now();
    const timing = `60-min run: ${u.samples.length} bytes, ${s.rows} rows; parse ${(t1 - t0).toFixed(2)} ms, re-check ${(t2 - t1).toFixed(2)} ms (workerd clock)`;
    console.log(timing);
    await annotate(timing);
    expect(r.steadySeconds).toBeGreaterThan(3500);

    const start = Date.now();
    const b = await publishOK(u, await newKey());
    const whole = `60-min run: whole publish ${Date.now() - start} ms wall (includes local D1/R2 I/O)`;
    console.log(whole);
    await annotate(whole);
    const row = await runRow(b.id);
    expect(JSON.parse(row.fps_series).points.length).toBe(300);
  });
});

describe("review fixes", () => {
  const enc = (t: string) => new TextEncoder().encode(t);

  it.each([
    ["run.json", "run", 256 * 1024, "256 KB"],
    ["summary.json", "summary", 16 * 1024, "16 KB"],
    ["samples.csv", "samples", 2 * 1024 * 1024, "2 MB"],
  ] as const)("%s over its cap: 413 before anything is parsed", async (part, field, cap, label) => {
    const u = syntheticUpload();
    const big = { ...u, [field]: new Uint8Array(cap + 1).fill(0x20) };
    const { status, body } = await send(await publishRequest(big, await newKey()));
    expect(status).toBe(413);
    expect(body.code).toBe("too_large");
    expect(body.message).toContain(part);
    expect(body.message).toContain(label);
  });

  it("a part exactly at its cap is not refused for size", async () => {
    const u = syntheticUpload();
    const text = new TextDecoder().decode(u.summary);
    const padded = enc(text + " ".repeat(16 * 1024 - u.summary.length));
    expect(padded.length).toBe(16 * 1024);
    expect((await send(await publishRequest({ ...u, summary: padded }, await newKey()))).status).toBe(201);
  });

  it("R2 failing for another reason than the hash: 503 storage_unavailable, nothing stored", async () => {
    const put = async () => {
      throw new Error("internal error");
    };
    const { status, body } = await send(await publishRequest(syntheticUpload(), await newKey()), { runs: { put } as any });
    expect(status).toBe(503);
    expect(body).toEqual({
      code: "storage_unavailable",
      message: "metal-pt.com couldn't store the run just now — try again in a few minutes.",
    });
    expect((await env.DB.prepare("SELECT count(*) AS n FROM runs").first<Body>())!.n).toBe(0);
  });

  it("tells R2's digest refusal from other errors", () => {
    expect(isDigestMismatch(new Error("put: The SHA-256 checksum you specified did not match what we received. (10037)"))).toBe(true);
    expect(isDigestMismatch(new Error("put: We encountered an internal error. Please try again. (10001)"))).toBe(false);
    expect(isDigestMismatch("network connection lost")).toBe(false);
  });

  it("DELETE: the group is recomputed before the zip goes; an R2 failure still removes the run", async () => {
    const k = await newKey();
    const id = (await publishOK(syntheticUpload(), k)).id;
    const key = (await runRow(id)).group_key;
    let groupGoneFirst: boolean | null = null;
    const del = async () => {
      groupGoneFirst = (await groupRow(key)) === null;
      throw new Error("R2 down");
    };
    const r = await send(await deleteRequest(id, k), { runs: { delete: del } as any });
    expect(r.status).toBe(200);
    expect(groupGoneFirst).toBe(true);
    expect(await env.DB.prepare("SELECT id FROM runs WHERE id = ?").bind(id).first()).toBeNull();
    // The orphaned zip is harmless.
    expect(await env.RUNS.get(`runs/${id}.zip`)).not.toBeNull();
  });

  it("GPU cores outside 1–256: published in the unknown bucket", async () => {
    for (const cores of [0, 300]) {
      const b = await publishOK(syntheticUpload({ gpuCores: cores }), await newKey());
      const row = await runRow(b.id);
      expect(row.gpu_cores).toBeNull();
      expect(row.mac_key).toBe("unknown");
    }
  });

  it("memory outside 1–1024 GB is stored as unknown", async () => {
    const b = await publishOK(syntheticUpload({ edit: (r) => (r.machine.memoryGB = 4096) }), await newKey());
    expect((await runRow(b.id)).memory_gb).toBeNull();
    const ok = await publishOK(syntheticUpload({ edit: (r) => (r.machine.memoryGB = 1024) }), await newKey());
    expect((await runRow(ok.id)).memory_gb).toBe(1024);
  });

  it("a start time that is not ISO-8601: refused with a clear message", async () => {
    for (const start of ["yesterday", "2026-11-20 12:00:00", "2026-13-45T99:00:00Z"]) {
      const { status, body } = await send(await publishRequest(syntheticUpload({ edit: (r) => (r.start = start) }), await newKey()));
      expect(status, start).toBe(422);
      expect(body.code).toBe("bad_json");
      expect(body.message).toContain("start time");
    }
  });

  it("the recorded time is stored normalised to the second", async () => {
    const b = await publishOK(syntheticUpload({ edit: (r) => (r.start = "2026-11-20T13:00:00.250+01:00") }), await newKey());
    expect((await runRow(b.id)).recorded).toBe("2026-11-20T12:00:00Z");
  });
});

describe("final review fixes", () => {
  it("a steady window over 90 minutes is refused with too_long; just under is published", async () => {
    const long = await send(await publishRequest(syntheticUpload({ seconds: 5500, steadyStartS: 30 }), await newKey()));
    expect(long.status).toBe(422);
    expect(long.body.code).toBe("too_long");
    expect(long.body.message).toBe("Runs longer than 90 minutes can't be published yet — record a shorter run.");
    await publishOK(syntheticUpload({ seconds: 5420, steadyStartS: 30 }), await newKey());
  });

  it("too_long also counts the steady rows' elapsed span (rows with gaps)", async () => {
    // 3000 rows, one every 2 s: 3000 steady seconds with FPS but a 6000 s span.
    const u = syntheticUpload({ seconds: 3000, steadyStartS: 30, elapsed: (s) => s * 2, edit: (r) => (r.steadyEndS = 6000) });
    expect(recheckSamples(u.runJson, parseSamples(new TextDecoder().decode(u.samples))).steadySpanSeconds).toBeGreaterThan(5400);
    const r = await send(await publishRequest(u, await newKey()));
    expect(r.status).toBe(422);
    expect(r.body.code).toBe("too_long");
  });

  it("the samples.csv cap matches config and the app (2 MiB)", () => {
    expect(MAX_SAMPLES_BYTES).toBe(2 * 1024 * 1024);
    expect(MAX_STEADY_SECONDS).toBe(5400);
  });

  it("409 with the url only for a visible run from the same key", async () => {
    const k = await newKey(), other = await newKey();
    const u = syntheticUpload();
    const first = await publishOK(u, k);
    const again = await send(await publishRequest(u, k));
    expect(again.status).toBe(409);
    expect(again.body).toMatchObject({ code: "already_published", id: first.id, url: first.url });

    const elsewhere = await send(await publishRequest(u, other));
    expect(elsewhere.status).toBe(409);
    expect(elsewhere.body.code).toBe("already_published_elsewhere");
    expect(elsewhere.body.message).toBe("This exact run was already published from another Mac.");
    expect(elsewhere.body.id).toBeUndefined();
    expect(elsewhere.body.url).toBeUndefined();

    await env.DB.prepare("UPDATE runs SET hidden = 1 WHERE id = ?").bind(first.id).run();
    const hidden = await send(await publishRequest(u, k));
    expect(hidden.status).toBe(409);
    expect(hidden.body.code).toBe("already_published_hidden");
    expect(hidden.body.message).toBe("This run was already published and has been hidden by a moderator.");
    expect(hidden.body.id).toBeUndefined();
    expect(hidden.body.url).toBeUndefined();
    // Another key's view of a hidden run says only "elsewhere".
    expect((await send(await publishRequest(u, other))).body.code).toBe("already_published_elsewhere");
  });

  it("key_conflict names no setting", async () => {
    const k = await newKey();
    await env.DB.prepare("INSERT INTO macs (key_id, public_key, first_seen) VALUES (?, ?, ?)")
      .bind(await keyIdOf(k.publicKey), "some-other-public-key", "2026-11-01T00:00:00Z")
      .run();
    const r = await send(await publishRequest(syntheticUpload(), k));
    expect(r.status).toBe(403);
    expect(r.body.code).toBe("key_conflict");
    expect(r.body.message).toBe("Your Mac's publishing key clashes with another — please report this on GitHub.");
  });

  it("the minimum app version is checked on summary.json publisherVersion when present", async () => {
    // Recorded by an old app, published by a current one: accepted.
    await publishOK(
      syntheticUpload({ edit: (r) => (r.appVersion = "0.1.0"), editSummary: (s) => (s.publisherVersion = "0.3.0") }),
      await newKey(),
    );
    // Published by an old app (even if run.json says otherwise): refused.
    const old = await send(
      await publishRequest(syntheticUpload({ editSummary: (s) => (s.publisherVersion = "0.1.9") }), await newKey()),
    );
    expect(old.status).toBe(422);
    expect(old.body.code).toBe("app_too_old");
    // Absent: falls back to run.json appVersion.
    const fallback = await send(await publishRequest(syntheticUpload({ edit: (r) => (r.appVersion = "0.1.9") }), await newKey()));
    expect(fallback.body.code).toBe("app_too_old");
    // Not a string: a shape error.
    const bad = await send(await publishRequest(syntheticUpload({ editSummary: (s) => (s.publisherVersion = 3) }), await newKey()));
    expect(bad.body.code).toBe("bad_json");
  });
});
