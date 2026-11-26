// Task 5: Cloudflare Access JWT verification, the admin pages and every admin write (groups recomputed, pages
// purged), the video lock and the banned key on PATCH/DELETE.
import { createExecutionContext, env, waitOnExecutionContext } from "cloudflare:test";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import { accessConfig, clearJwksCache, verifyAccessJwt, type AccessConfig } from "../src/admin/access.ts";
import { createApp } from "../src/index.ts";
import { normalizeTitle } from "../src/lib/games.ts";
import { base64urlEncode } from "../src/lib/signing.ts";
import type { Fetch } from "../src/oembed.ts";
import {
  BASE,
  deleteRequest,
  newKey,
  NOW,
  oembedStub,
  patchRequest,
  publishRequest,
  syntheticUpload,
  type TestKey,
} from "./api-helpers.ts";
import { recomputeAll, resetSite, seedGame, seedRun } from "./page-seed.ts";

const TEAM = "metalpt";
const ISSUER = "https://metalpt.cloudflareaccess.com";
const CERTS = `${ISSUER}/cdn-cgi/access/certs`;
const AUD = "a1b2c3d4e5f6aud";
const ACCESS = { ACCESS_TEAM_DOMAIN: TEAM, ACCESS_AUD: AUD };
const CFG: AccessConfig = { issuer: ISSUER, aud: AUD };
const NOW_S = Math.floor(NOW.getTime() / 1000);

// MARK: - Test RSA keys and tokens

interface RsaKey {
  kid: string;
  privateKey: CryptoKey;
  jwk: JsonWebKey & { kid: string };
}

async function rsaKey(kid: string): Promise<RsaKey> {
  const pair = (await crypto.subtle.generateKey(
    { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
    true,
    ["sign", "verify"],
  )) as CryptoKeyPair;
  const jwk = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey;
  return { kid, privateKey: pair.privateKey, jwk: { kty: "RSA", n: jwk.n, e: jwk.e, kid, alg: "RS256", use: "sig" } as JsonWebKey & { kid: string } };
}

const b64json = (o: unknown) => base64urlEncode(new TextEncoder().encode(JSON.stringify(o)));

async function token(key: RsaKey, claims: Record<string, unknown> = {}, header: Record<string, unknown> = {}): Promise<string> {
  const payload = {
    aud: [AUD],
    iss: ISSUER,
    email: "owner@example.com",
    sub: "user-1",
    iat: NOW_S - 10,
    nbf: NOW_S - 10,
    exp: NOW_S + 3600,
    ...claims,
  };
  const input = `${b64json({ alg: "RS256", kid: key.kid, typ: "JWT", ...header })}.${b64json(payload)}`;
  const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key.privateKey, new TextEncoder().encode(input));
  return `${input}.${base64urlEncode(new Uint8Array(sig))}`;
}

let signer: RsaKey;
let other: RsaKey;
let certCalls = 0;

/** Answers Access's certs URL with `signer`'s public key; anything else like YouTube's oEmbed. */
function stubFetch(keys: () => JsonWebKey[] = () => [signer.jwk]): Fetch {
  const oembed = oembedStub();
  return async (url, init) => {
    if (url === CERTS) {
      certCalls += 1;
      return Response.json({ keys: keys(), public_cert: {}, public_certs: [] });
    }
    return oembed(url, init);
  };
}

beforeAll(async () => {
  signer = await rsaKey("kid-1");
  other = await rsaKey("kid-1"); // same kid, different key: a forged token
});

beforeEach(async () => {
  clearJwksCache();
  certCalls = 0;
  await resetSite();
});

// MARK: - The site with Access configured

interface SiteOptions {
  vars?: Record<string, string>;
  cache?: Cache | null;
  fetch?: Fetch;
  db?: D1Database;
}

/** env.DB wrapped to count D1 calls: each statement's first/all/run/raw and each batch counts one. */
function countingDB(): { db: D1Database; calls: () => number } {
  let n = 0;
  const real = new WeakMap<object, D1PreparedStatement>();
  const wrap = (stmt: D1PreparedStatement): D1PreparedStatement => {
    const p = new Proxy(stmt, {
      get(t, k) {
        if (k === "bind") return (...args: unknown[]) => wrap(t.bind(...args));
        if (k === "first" || k === "all" || k === "run" || k === "raw") {
          return (...args: unknown[]) => {
            n += 1;
            return (t as any)[k](...args);
          };
        }
        const v = (t as any)[k];
        return typeof v === "function" ? v.bind(t) : v;
      },
    });
    real.set(p, stmt);
    return p;
  };
  const db = new Proxy(env.DB, {
    get(t, k) {
      if (k === "prepare") return (sql: string) => wrap(t.prepare(sql));
      if (k === "batch") {
        return (stmts: D1PreparedStatement[]) => {
          n += 1;
          return t.batch(stmts.map((s) => real.get(s) ?? s));
        };
      }
      const v = (t as any)[k];
      return typeof v === "function" ? v.bind(t) : v;
    },
  });
  return { db, calls: () => n };
}

async function call(req: Request, o: SiteOptions = {}): Promise<Response> {
  const app = createApp({ now: () => NOW, fetch: o.fetch ?? stubFetch(), cache: () => o.cache ?? null });
  const ctx = createExecutionContext();
  const res = await app.fetch(req, { ...env, ...(o.db ? { DB: o.db } : {}), ...(o.vars ?? ACCESS) }, ctx);
  await waitOnExecutionContext(ctx);
  return res;
}

async function adminGet(path: string, o: SiteOptions & { jwt?: string | null } = {}): Promise<Response> {
  const headers = new Headers();
  const jwt = o.jwt === undefined ? await token(signer) : o.jwt;
  if (jwt !== null) headers.set("Cf-Access-Jwt-Assertion", jwt);
  return call(new Request(BASE + path, { headers }), o);
}

async function adminPost(
  path: string,
  fields: Record<string, string> = {},
  o: SiteOptions & { origin?: string | null } = {},
): Promise<Response> {
  const headers = new Headers({ "Cf-Access-Jwt-Assertion": await token(signer) });
  const origin = o.origin === undefined ? BASE : o.origin;
  if (origin !== null) headers.set("Origin", origin);
  const body = new URLSearchParams(fields);
  return call(new Request(BASE + path, { method: "POST", headers, body }), o);
}

const run = (id: string) => env.DB.prepare("SELECT * FROM runs WHERE id = ?").bind(id).first<Record<string, any>>();
const group = (key: string) => env.DB.prepare(`SELECT * FROM "groups" WHERE group_key = ?`).bind(key).first<Record<string, any>>();

/** Two keys' runs in one group of game 1 (counted: 3 runs from 2 Macs), plus a game 2. */
async function seedBasic(): Promise<{ gk: string }> {
  await seedGame(1, "cyberpunk-2077", "Cyberpunk 2077", "1091520");
  await seedGame(2, "cyberpunk-2077-ultimate", "Cyberpunk 2077 Ultimate");
  const gk = await seedRun({ id: "runaaaa1", game: 1, key: "k1", fps: 60, fpw: 0.5, watts: 120 });
  await seedRun({ id: "runaaaa2", game: 1, key: "k1", fps: 62, fpw: 0.5, watts: 120 });
  await seedRun({ id: "runbbbb1", game: 1, key: "k2", fps: 64, fpw: 0.5, watts: 120 });
  await recomputeAll();
  return { gk };
}

// MARK: - Access

describe("Access config", () => {
  it("is null unless both the team and the AUD are set", () => {
    expect(accessConfig({})).toBeNull();
    expect(accessConfig({ ACCESS_TEAM_DOMAIN: TEAM })).toBeNull();
    expect(accessConfig({ ACCESS_AUD: AUD })).toBeNull();
    expect(accessConfig({ ACCESS_TEAM_DOMAIN: " ", ACCESS_AUD: AUD })).toBeNull();
  });

  it("accepts the team name, its domain or a URL", () => {
    for (const t of ["metalpt", "metalpt.cloudflareaccess.com", "https://metalpt.cloudflareaccess.com/"]) {
      expect(accessConfig({ ACCESS_TEAM_DOMAIN: t, ACCESS_AUD: AUD })).toEqual(CFG);
    }
  });
});

describe("Access JWT", () => {
  const verify = (t: string | null) => verifyAccessJwt(t, CFG, { fetch: stubFetch(), now: NOW });

  it("a valid token gives the identity", async () => {
    expect(await verify(await token(signer))).toEqual({ email: "owner@example.com", sub: "user-1" });
  });

  it("aud as a string also works", async () => {
    expect(await verify(await token(signer, { aud: AUD }))).not.toBeNull();
  });

  it("refuses a wrong audience, issuer, expiry or not-before", async () => {
    expect(await verify(await token(signer, { aud: ["another-app"] }))).toBeNull();
    expect(await verify(await token(signer, { iss: "https://evil.cloudflareaccess.com" }))).toBeNull();
    expect(await verify(await token(signer, { exp: NOW_S - 120 }))).toBeNull();
    expect(await verify(await token(signer, { exp: undefined }))).toBeNull();
    expect(await verify(await token(signer, { nbf: NOW_S + 600 }))).toBeNull();
  });

  it("refuses a token signed by another key, an unknown kid, another algorithm, or junk", async () => {
    expect(await verify(await token(other))).toBeNull();
    expect(await verify(await token(signer, {}, { kid: "kid-unknown" }))).toBeNull();
    expect(await verify(await token(signer, {}, { alg: "HS256" }))).toBeNull();
    expect(await verify(await token(signer, {}, { alg: "none" }))).toBeNull();
    const good = await token(signer);
    const [h, p] = good.split(".");
    expect(await verify(`${h}.${p}.`)).toBeNull();
    expect(await verify(`${h}.${b64json({ aud: [AUD], iss: ISSUER, exp: NOW_S + 3600, email: "x@evil" })}.${good.split(".")[2]}`)).toBeNull();
    expect(await verify("not-a-jwt")).toBeNull();
    expect(await verify("")).toBeNull();
    expect(await verify(null)).toBeNull();
  });

  it("caches the team's keys", async () => {
    await verify(await token(signer));
    await verify(await token(signer));
    expect(certCalls).toBe(1);
  });

  it("a certs fetch failure refuses (no throw)", async () => {
    const failing: Fetch = async () => new Response("down", { status: 500 });
    expect(await verifyAccessJwt(await token(signer), CFG, { fetch: failing, now: NOW })).toBeNull();
  });
});

describe("/admin access", () => {
  it("without Access config every /admin URL is the normal 404 page", async () => {
    const partial: Record<string, string>[] = [{}, { ACCESS_TEAM_DOMAIN: TEAM }];
    for (const vars of partial) {
      const res = await adminGet("/admin", { vars });
      expect(res.status).toBe(404);
      expect(await res.text()).toContain("Not found");
      expect((await adminGet("/admin/games", { vars })).status).toBe(404);
    }
    await seedBasic();
    const res = await adminPost("/admin/run/runaaaa1/hide", {}, { vars: {} });
    expect(res.status).toBe(404);
    expect((await run("runaaaa1"))!.hidden).toBe(0);
  });

  it("no token or a bad token: 403", async () => {
    expect((await adminGet("/admin", { jwt: null })).status).toBe(403);
    expect((await adminGet("/admin", { jwt: await token(other) })).status).toBe(403);
    expect((await adminGet("/admin", { jwt: await token(signer, { aud: ["x"] }) })).status).toBe(403);
  });

  it("a valid token opens the queue; never cached, not frameable", async () => {
    const res = await adminGet("/admin");
    expect(res.status).toBe(200);
    expect(res.headers.get("cache-control")).toBe("no-store");
    expect(res.headers.get("x-frame-options")).toBe("DENY");
    const html = await res.text();
    expect(html).toContain("Open reports");
    expect(html).toContain("Signed in as owner@example.com");
    expect(html).toContain("noindex");
  });

  it("a write without this site's Origin is refused (CSRF) and changes nothing", async () => {
    await seedBasic();
    expect((await adminPost("/admin/run/runaaaa1/hide", {}, { origin: null })).status).toBe(403);
    expect((await adminPost("/admin/run/runaaaa1/hide", {}, { origin: "https://evil.example" })).status).toBe(403);
    expect((await run("runaaaa1"))!.hidden).toBe(0);
  });
});

// MARK: - Reports queue

describe("reports queue", () => {
  it("lists open reports (text escaped), resolves and reopens", async () => {
    await seedBasic();
    await env.DB.prepare("INSERT INTO reports (id, run_id, reason, text, created) VALUES (7, 'runaaaa1', 'impossible_numbers', ?, '2026-11-25T10:00:00Z')")
      .bind("<script>alert(1)</script> way too fast")
      .run();
    let html = await (await adminGet("/admin")).text();
    expect(html).toContain("Impossible numbers");
    expect(html).toContain("&lt;script&gt;alert(1)&lt;/script&gt; way too fast");
    expect(html).not.toContain("<script>alert(1)");
    expect(html).toContain('href="/admin/run/runaaaa1"');

    const res = await adminPost("/admin/report/7/resolve", { back: "/admin" });
    expect(res.status).toBe(303);
    expect(res.headers.get("location")).toBe("/admin?done=resolved");
    expect((await env.DB.prepare("SELECT resolved FROM reports WHERE id = 7").first<{ resolved: number }>())!.resolved).toBe(1);
    html = await (await adminGet("/admin?done=resolved")).text();
    expect(html).toContain("No open reports.");
    expect(html).toContain("Report resolved.");
    expect(await (await adminGet("/admin?show=resolved")).text()).toContain("way too fast");

    await adminPost("/admin/report/7/reopen");
    expect((await env.DB.prepare("SELECT resolved FROM reports WHERE id = 7").first<{ resolved: number }>())!.resolved).toBe(0);
  });

  it("an off-site back link falls back to the admin page", async () => {
    await seedBasic();
    await env.DB.prepare("INSERT INTO reports (id, run_id, reason, created) VALUES (8, 'runaaaa1', 'other', 'x')").run();
    const res = await adminPost("/admin/report/8/resolve", { back: "https://evil.example/admin" });
    expect(res.headers.get("location")).toBe("/admin?done=resolved");
  });
});

// MARK: - Runs

describe("hide and unhide", () => {
  it("recomputes the group and purges the pages", async () => {
    const { gk } = await seedBasic();
    expect((await group(gk))!.runs).toBe(3);
    const cache = await caches.open("admin-hide");
    for (const p of ["/run/runbbbb1", "/game/cyberpunk-2077"]) await cache.put(BASE + p, new Response("old"));

    const res = await adminPost("/admin/run/runbbbb1/hide", {}, { cache });
    expect(res.status).toBe(303);
    expect(res.headers.get("location")).toBe("/admin/run/runbbbb1?done=hidden");
    expect((await run("runbbbb1"))!.hidden).toBe(1);
    // One Mac left: still 2 counted runs, macs 1.
    expect((await group(gk))!.macs).toBe(1);
    expect(await cache.match(BASE + "/run/runbbbb1")).toBeUndefined();
    expect(await cache.match(BASE + "/game/cyberpunk-2077")).toBeUndefined();

    await adminPost("/admin/run/runbbbb1/unhide");
    expect((await run("runbbbb1"))!.hidden).toBe(0);
    expect((await group(gk))!.macs).toBe(2);
  });

  it("the admin run page shows a hidden run; an unknown run is a 404", async () => {
    await seedBasic();
    await adminPost("/admin/run/runaaaa1/hide");
    const html = await (await adminGet("/admin/run/runaaaa1")).text();
    expect(html).toContain("HIDDEN");
    expect(html).toContain("Unhide run");
    expect((await adminGet("/admin/run/nosuchrun1")).status).toBe(404);
    const go = await adminGet("/admin/run?id=" + encodeURIComponent("https://metal-pt.com/run/runaaaa1"));
    expect(go.headers.get("location")).toBe("/admin/run/runaaaa1");
  });

  it("an unknown run: the error page, nothing written", async () => {
    const res = await adminPost("/admin/run/nosuchrun1/hide");
    expect(res.status).toBe(400);
    expect(await res.text()).toContain("That run doesn&#39;t exist");
  });
});

describe("video link removal and the lock", () => {
  async function publishWithVideo(k: TestKey): Promise<string> {
    const pub = await call(await publishRequest(syntheticUpload(), k));
    expect(pub.status).toBe(201);
    const id = ((await pub.json()) as { id: string }).id;
    const set = await call(await patchRequest(id, { videoURL: "https://youtu.be/dQw4w9WgXcQ" }, k));
    expect(set.status).toBe(200);
    return id;
  }

  it("removes the link and the owner's PATCH can't put one back until unlocked", async () => {
    const k = await newKey();
    const id = await publishWithVideo(k);
    const res = await adminPost(`/admin/run/${id}/remove-video`);
    expect(res.status).toBe(303);
    const r = (await run(id))!;
    expect([r.video_id, r.video_title, r.video_channel, r.video_locked]).toEqual([null, null, null, 1]);

    for (const body of [{ videoURL: "https://youtu.be/dQw4w9WgXcQ" }, { videoURL: null }]) {
      const again = await call(await patchRequest(id, body, k));
      expect(again.status).toBe(403);
      expect(await again.json()).toEqual({ code: "video_locked", message: "The video link on this run was removed by a moderator." });
    }
    expect((await run(id))!.video_id).toBeNull();

    await adminPost(`/admin/run/${id}/unlock-video`);
    expect((await run(id))!.video_locked).toBe(0);
    expect((await call(await patchRequest(id, { videoURL: "https://youtu.be/dQw4w9WgXcQ" }, k))).status).toBe(200);
  });

  it("another key's PATCH on a locked run is still not_yours", async () => {
    const k = await newKey();
    const id = await publishWithVideo(k);
    await adminPost(`/admin/run/${id}/remove-video`);
    const r = await call(await patchRequest(id, { videoURL: null }, await newKey()));
    expect(r.status).toBe(403);
    expect(((await r.json()) as { code: string }).code).toBe("not_yours");
  });
});

// MARK: - Keys

describe("ban", () => {
  it("bans the key, hides its runs, recomputes groups; PATCH refused, DELETE allowed", async () => {
    const k = await newKey();
    const ids: string[] = [];
    for (let i = 0; i < 2; i++) {
      const r = await call(await publishRequest(syntheticUpload(), k));
      ids.push(((await r.json()) as { id: string }).id);
    }
    const other = await call(await publishRequest(syntheticUpload(), await newKey()));
    const otherId = ((await other.json()) as { id: string }).id;
    const gk = (await run(ids[0]))!.group_key;
    expect((await group(gk))!.runs).toBe(3);
    const keyId = (await run(ids[0]))!.key_id;

    const res = await adminPost("/admin/key/ban", { key_id: keyId, back: `/admin/run/${ids[0]}` });
    expect(res.status).toBe(303);
    expect(res.headers.get("location")).toBe(`/admin/run/${ids[0]}?done=banned`);
    expect((await env.DB.prepare("SELECT banned FROM macs WHERE key_id = ?").bind(keyId).first<{ banned: number }>())!.banned).toBe(1);
    for (const id of ids) expect((await run(id))!.hidden).toBe(1);
    expect((await run(otherId))!.hidden).toBe(0);
    const g = (await group(gk))!;
    expect([g.runs, g.macs]).toEqual([1, 1]);

    const patch = await call(await patchRequest(ids[0], { videoURL: null }, k));
    expect(patch.status).toBe(403);
    expect(((await patch.json()) as { code: string }).code).toBe("banned");
    const publish = await call(await publishRequest(syntheticUpload(), k));
    expect(publish.status).toBe(403);
    const del = await call(await deleteRequest(ids[1], k));
    expect(del.status).toBe(200);
    expect(await run(ids[1])).toBeNull();
  });

  it("unban with unhide shows the runs again; without, they stay hidden", async () => {
    await seedBasic();
    await adminPost("/admin/key/ban", { key_id: "k1" });
    await adminPost("/admin/key/unban", { key_id: "k1" });
    expect((await env.DB.prepare("SELECT banned FROM macs WHERE key_id = 'k1'").first<{ banned: number }>())!.banned).toBe(0);
    expect((await run("runaaaa1"))!.hidden).toBe(1);
    await adminPost("/admin/key/unban", { key_id: "k1", unhide: "1" });
    expect((await run("runaaaa1"))!.hidden).toBe(0);
    expect((await run("runaaaa2"))!.hidden).toBe(0);
  });

  it("an unknown key is refused", async () => {
    const res = await adminPost("/admin/key/ban", { key_id: "nope" });
    expect(res.status).toBe(400);
  });
});

// MARK: - Games

describe("games", () => {
  it("lists and finds games (by alias too)", async () => {
    await seedBasic();
    await env.DB.prepare("INSERT INTO game_aliases (alias_norm, game_id) VALUES ('cp2077', 1)").run();
    const all = await (await adminGet("/admin/games")).text();
    expect(all).toContain("Cyberpunk 2077 Ultimate");
    const found = await (await adminGet("/admin/games?q=cp2077")).text();
    expect(found).toContain('href="/admin/game/1"');
    expect(found).not.toContain('href="/admin/game/2"');
    const g = await (await adminGet("/admin/game/1")).text();
    expect(g).toContain("cyberpunk 2077");
    expect(g).toContain("1091520");
  });

  it("rename: title, slug, the new title as an alias; old slug purged", async () => {
    await seedBasic();
    const cache = await caches.open("admin-rename");
    await cache.put(BASE + "/game/cyberpunk-2077", new Response("old"));
    const res = await adminPost("/admin/game/1/rename", { title: "Cyberpunk 2077: Phantom", slug: "cyberpunk-phantom" }, { cache });
    expect(res.status).toBe(303);
    const g = (await env.DB.prepare("SELECT title, slug FROM games WHERE id = 1").first<{ title: string; slug: string }>())!;
    expect(g).toEqual({ title: "Cyberpunk 2077: Phantom", slug: "cyberpunk-phantom" });
    expect(await env.DB.prepare("SELECT game_id FROM game_aliases WHERE alias_norm = ?").bind(normalizeTitle("Cyberpunk 2077: Phantom")).first()).toEqual({ game_id: 1 });
    expect(await cache.match(BASE + "/game/cyberpunk-2077")).toBeUndefined();
  });

  it("rename refusals: slug taken, bad slug, a title that is another game's name", async () => {
    await seedBasic();
    expect((await adminPost("/admin/game/1/rename", { title: "X", slug: "cyberpunk-2077-ultimate" })).status).toBe(400);
    expect((await adminPost("/admin/game/1/rename", { title: "X", slug: "Bad Slug" })).status).toBe(400);
    const res = await adminPost("/admin/game/1/rename", { title: "Cyberpunk 2077 Ultimate", slug: "" });
    expect(res.status).toBe(400);
    expect(await res.text()).toContain("Merge the games instead");
    expect((await env.DB.prepare("SELECT title FROM games WHERE id = 1").first<{ title: string }>())!.title).toBe("Cyberpunk 2077");
  });

  it("Steam ID: clear, set, and one game per ID", async () => {
    await seedBasic();
    await adminPost("/admin/game/1/steam", { steam_id: "" });
    expect((await env.DB.prepare("SELECT steam_id FROM games WHERE id = 1").first<{ steam_id: string | null }>())!.steam_id).toBeNull();
    await adminPost("/admin/game/2/steam", { steam_id: "steam:1091520" });
    expect((await env.DB.prepare("SELECT steam_id FROM games WHERE id = 2").first<{ steam_id: string }>())!.steam_id).toBe("1091520");
    const clash = await adminPost("/admin/game/1/steam", { steam_id: "1091520" });
    expect(clash.status).toBe(400);
    expect(await clash.text()).toContain("belongs to Cyberpunk 2077 Ultimate");
    expect((await adminPost("/admin/game/1/steam", { steam_id: "12ab" })).status).toBe(400);
  });

  it("aliases: add (normalised), refuse another game's, remove", async () => {
    await seedBasic();
    const res = await adminPost("/admin/game/1/alias/add", { alias: "CYBERPUNK™ 2077!" });
    expect(res.status).toBe(303);
    expect(await env.DB.prepare("SELECT game_id FROM game_aliases WHERE alias_norm = 'cyberpunk 2077'").first()).toEqual({ game_id: 1 });
    await adminPost("/admin/game/1/alias/add", { alias: "CP 2077" });
    expect(await env.DB.prepare("SELECT game_id FROM game_aliases WHERE alias_norm = 'cp 2077'").first()).toEqual({ game_id: 1 });
    expect((await adminPost("/admin/game/2/alias/add", { alias: "cp 2077" })).status).toBe(400);
    await adminPost("/admin/game/1/alias/remove", { alias: "cp 2077" });
    expect(await env.DB.prepare("SELECT game_id FROM game_aliases WHERE alias_norm = 'cp 2077'").first()).toBeNull();
    expect((await adminPost("/admin/game/2/alias/remove", { alias: "cyberpunk 2077" })).status).toBe(400);
  });

  it("merge: runs repoint with new group keys, groups recomputed, aliases and Steam ID move, source gone", async () => {
    const { gk } = await seedBasic();
    // Game 2 has its own Steam ID and a run in the same settings from a third Mac.
    await env.DB.prepare("UPDATE games SET steam_id = '2000' WHERE id = 2").run();
    await env.DB.prepare("UPDATE games SET steam_id = NULL WHERE id = 1").run();
    const srcGK = await seedRun({ id: "runcccc1", game: 2, key: "k3", fps: 66, fpw: 0.5, watts: 120 });
    await env.DB.prepare("INSERT INTO game_aliases (alias_norm, game_id) VALUES ('cp2077u', 2)").run();
    await recomputeAll();
    expect((await group(srcGK))!.runs).toBe(1);
    const cache = await caches.open("admin-merge");
    await cache.put(BASE + "/game/cyberpunk-2077-ultimate", new Response("old"));

    const res = await adminPost("/admin/game/2/merge", { target: "https://metal-pt.com/game/cyberpunk-2077", confirm: "1" }, { cache });
    expect(res.status).toBe(303);
    expect(res.headers.get("location")).toBe("/admin/game/1?done=merged");

    const moved = (await run("runcccc1"))!;
    expect(moved.game_id).toBe(1);
    expect(moved.group_key).toBe(gk);
    expect(await env.DB.prepare("SELECT id FROM games WHERE id = 2").first()).toBeNull();
    expect(await env.DB.prepare(`SELECT count(*) AS n FROM "groups" WHERE game_id = 2`).first()).toEqual({ n: 0 });
    expect(await group(srcGK)).toBeNull();
    const g = (await group(gk))!;
    expect([g.runs, g.macs]).toEqual([4, 3]);
    expect(await env.DB.prepare("SELECT game_id FROM game_aliases WHERE alias_norm = 'cp2077u'").first()).toEqual({ game_id: 1 });
    expect(await env.DB.prepare("SELECT game_id FROM game_aliases WHERE alias_norm = 'cyberpunk 2077 ultimate'").first()).toEqual({ game_id: 1 });
    expect((await env.DB.prepare("SELECT steam_id FROM games WHERE id = 1").first<{ steam_id: string }>())!.steam_id).toBe("2000");
    expect(await cache.match(BASE + "/game/cyberpunk-2077-ultimate")).toBeUndefined();
  });

  it("merge keeps the target's Steam ID when it has one (the source's is dropped)", async () => {
    await seedBasic();
    await env.DB.prepare("UPDATE games SET steam_id = '2000' WHERE id = 2").run();
    await adminPost("/admin/game/2/merge", { target: "1", confirm: "1" });
    expect((await env.DB.prepare("SELECT steam_id FROM games WHERE id = 1").first<{ steam_id: string }>())!.steam_id).toBe("1091520");
    expect(await env.DB.prepare("SELECT id FROM games WHERE steam_id = '2000'").first()).toBeNull();
  });

  it("merge refusals: into itself, unknown target, not confirmed", async () => {
    await seedBasic();
    expect((await adminPost("/admin/game/1/merge", { target: "1", confirm: "1" })).status).toBe(400);
    expect((await adminPost("/admin/game/1/merge", { target: "no-such-game", confirm: "1" })).status).toBe(400);
    expect((await adminPost("/admin/game/1/merge", { target: "2" })).status).toBe(400);
    expect(await env.DB.prepare("SELECT count(*) AS n FROM games").first()).toEqual({ n: 2 });
  });
});

// MARK: - Fix round 1: bounded D1 calls, the repair path

/** `n` groups (one per resolution), each with a run from `key` and one from "kother". */
async function seedGroups(n: number, key = "kban"): Promise<string[]> {
  await seedGame(1, "cyberpunk-2077", "Cyberpunk 2077");
  const gks: string[] = [];
  for (let i = 0; i < n; i++) {
    gks.push(await seedRun({ id: `ban${String(i).padStart(4, "0")}a`, game: 1, key, fps: 60, fpw: 0.5, width: 1000 + i }));
    await seedRun({ id: `ban${String(i).padStart(4, "0")}b`, game: 1, key: "kother", fps: 70, fpw: 0.6, width: 1000 + i });
  }
  await recomputeAll();
  return gks;
}

describe("bounded D1 calls", () => {
  it("a ban touching 60 groups costs a few D1 calls and leaves correct group rows", async () => {
    const gks = await seedGroups(60);
    expect((await group(gks[0]))!.runs).toBe(2);
    const { db, calls } = countingDB();
    const res = await adminPost("/admin/key/ban", { key_id: "kban" }, { db });
    expect(res.status).toBe(303);
    expect(calls()).toBeLessThanOrEqual(8);
    for (const gk of gks) {
      const g = (await group(gk))!;
      // One run from one Mac: counted, but not enough for a typical.
      expect([g.runs, g.macs, g.typical_fps, g.updated]).toEqual([1, 1, null, "2026-11-25T12:03:00Z"]);
    }
    // Unban and show: the same bounded cost, groups back to 2 runs.
    const again = countingDB();
    await adminPost("/admin/key/unban", { key_id: "kban", unhide: "1" }, { db: again.db });
    expect(again.calls()).toBeLessThanOrEqual(8);
    for (const gk of gks) expect((await group(gk))!.runs).toBe(2);
  });

  it("a merge of a game with 60 groups costs a few D1 calls", async () => {
    await seedGroups(60);
    await seedGame(2, "other-game", "Other Game");
    const { db, calls } = countingDB();
    const res = await adminPost("/admin/game/1/merge", { target: "2", confirm: "1" }, { db });
    expect(res.status).toBe(303);
    expect(calls()).toBeLessThanOrEqual(12);
    const n = await env.DB.prepare(`SELECT count(*) AS n, sum(runs) AS runs FROM "groups" WHERE game_id = 2`).first();
    expect(n).toEqual({ n: 60, runs: 120 });
  });

  it("rename, Steam ID and alias writes don't recompute groups", async () => {
    const { gk } = await seedBasic();
    for (const [path, fields] of [
      ["/admin/game/1/rename", { title: "Cyberpunk 2077 Remix", slug: "" }],
      ["/admin/game/1/steam", { steam_id: "" }],
      ["/admin/game/1/alias/add", { alias: "CP77" }],
    ] as const) {
      const { db, calls } = countingDB();
      expect((await adminPost(path, fields, { db })).status).toBe(303);
      expect(calls()).toBeLessThanOrEqual(6);
    }
    expect((await group(gk))!.updated).toBe("2026-11-25T12:00:00Z");
  });
});

describe("recompute statistics", () => {
  it("per game repairs a wrong row and a missing row, and is idempotent", async () => {
    const { gk } = await seedBasic();
    const before = (await group(gk))!;
    await env.DB.prepare(`UPDATE "groups" SET typical_fps = 999, runs = 9 WHERE group_key = ?`).bind(gk).run();
    for (let i = 0; i < 2; i++) {
      const res = await adminPost("/admin/recompute", { scope: "game", id: "1", back: "/admin/game/1" });
      expect(res.status).toBe(200);
      expect(await res.text()).toContain("All done.");
      const g = (await group(gk))!;
      expect([g.typical_fps, g.runs]).toEqual([before.typical_fps, before.runs]);
      await env.DB.prepare(`DELETE FROM "groups" WHERE group_key = ?`).bind(gk).run();
    }
    await adminPost("/admin/recompute", { scope: "game", id: "1" });
    expect((await group(gk))!.runs).toBe(before.runs);
  });

  it("a stale group row with no runs left is deleted", async () => {
    const { gk } = await seedBasic();
    await env.DB.prepare("DELETE FROM runs").run();
    await adminPost("/admin/recompute", { scope: "game", id: "1" });
    expect(await group(gk)).toBeNull();
  });

  it("per key", async () => {
    const { gk } = await seedBasic();
    await env.DB.prepare(`UPDATE "groups" SET typical_fps = 999 WHERE group_key = ?`).bind(gk).run();
    const res = await adminPost("/admin/recompute", { scope: "key", key_id: "k2" });
    expect(res.status).toBe(200);
    expect((await group(gk))!.typical_fps).not.toBe(999);
    expect((await adminPost("/admin/recompute", { scope: "key", key_id: "nope" })).status).toBe(400);
    expect((await adminPost("/admin/recompute", { scope: "bogus" })).status).toBe(400);
  });

  it("all: 200 groups per request, then \"N left — run again\" until done", async () => {
    const gks = await seedGroups(205);
    await env.DB.prepare(`UPDATE "groups" SET typical_fps = 999`).run();
    const first = await adminPost("/admin/recompute", { scope: "all" });
    const html = await first.text();
    expect(html).toContain("200 groups recomputed. 5 groups left — run again.");
    const after = /name="after" value="([^"]+)"/.exec(html)![1].replace(/&amp;/g, "&");
    expect((await env.DB.prepare(`SELECT count(*) AS n FROM "groups" WHERE typical_fps = 999`).first())).toEqual({ n: 5 });
    const second = await (await adminPost("/admin/recompute", { scope: "all", after })).text();
    expect(second).toContain("5 groups recomputed. All done.");
    expect((await env.DB.prepare(`SELECT count(*) AS n FROM "groups" WHERE typical_fps = 999`).first())).toEqual({ n: 0 });
    expect(gks).toHaveLength(205);
  });

  it("admin pages load no Google Fonts", async () => {
    const html = await (await adminGet("/admin")).text();
    expect(html).not.toContain("fonts.googleapis.com");
  });
});
