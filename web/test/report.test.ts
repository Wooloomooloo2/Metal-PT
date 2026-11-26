// Task 5: "Report a problem with this run" — the form, validation, Turnstile on/off/unconfigured, what a report
// stores (no request data), plus the download's Cache-Control and the privacy page's Turnstile note.
import { createExecutionContext, env, waitOnExecutionContext } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { createApp } from "../src/index.ts";
import type { Fetch } from "../src/oembed.ts";
import { verifyTurnstile } from "../src/turnstile.ts";
import { BASE, NOW } from "./api-helpers.ts";
import { recomputeAll, resetSite, seedGame, seedRun } from "./page-seed.ts";

const OFF = { TURNSTILE_DISABLED: "1" };
const ON = { TURNSTILE_SITE_KEY: "0x4AAAAAAA-site", TURNSTILE_SECRET: "0x4AAAAAAA-secret" };

interface Siteverify {
  url: string;
  fields: Record<string, string>;
}

function siteverifyStub(reply: Record<string, unknown> | "throw", calls: Siteverify[] = []): Fetch {
  return async (url, init) => {
    const fields: Record<string, string> = {};
    if (init?.body instanceof FormData) for (const [k, v] of init.body.entries()) fields[k] = String(v);
    calls.push({ url, fields });
    if (reply === "throw") throw new Error("network down");
    return Response.json(reply);
  };
}

async function call(req: Request, vars: Record<string, string>, fetch: Fetch = siteverifyStub({ success: true })): Promise<Response> {
  const app = createApp({ now: () => NOW, fetch, cache: () => null });
  const ctx = createExecutionContext();
  const res = await app.fetch(req, { ...env, ...vars }, ctx);
  await waitOnExecutionContext(ctx);
  return res;
}

function post(id: string, fields: Record<string, string>, headers: Record<string, string> = {}): Request {
  return new Request(`${BASE}/run/${id}/report`, { method: "POST", body: new URLSearchParams(fields), headers });
}

const reports = async () =>
  (await env.DB.prepare("SELECT * FROM reports ORDER BY id").all<Record<string, unknown>>()).results;

beforeEach(async () => {
  await resetSite();
  await seedGame(1, "cyberpunk-2077", "Cyberpunk 2077");
  await seedRun({ id: "repaaaa1", game: 1, key: "k1", fps: 60 });
  await seedRun({ id: "repvideo", game: 1, key: "k1", fps: 61, video: { id: "dQw4w9WgXcQ", title: "t", channel: "c" } });
  await seedRun({ id: "rephidden", game: 1, key: "k2", fps: 62, hidden: 1 });
  await recomputeAll();
});

describe("report form", () => {
  it("the run page links to it; the form names the run and the reasons; never cached", async () => {
    const runPage = await (await call(new Request(`${BASE}/run/repaaaa1`), OFF)).text();
    expect(runPage).toContain('href="/run/repaaaa1/report"');
    const res = await call(new Request(`${BASE}/run/repaaaa1/report`), OFF);
    expect(res.status).toBe(200);
    expect(res.headers.get("cache-control")).toBe("no-store");
    const html = await res.text();
    expect(html).toContain("Report a problem with this run");
    expect(html).toContain("Cyberpunk 2077 · M4 Max · Native");
    for (const r of ["Wrong game", "Wrong settings", "Impossible numbers", "Something else"]) expect(html).toContain(r);
    // No video on this run: no "Bad video link" choice.
    expect(html).not.toContain("Bad video link");
    expect(await (await call(new Request(`${BASE}/run/repvideo/report`), OFF)).text()).toContain("Bad video link");
    // Turnstile disabled: no third-party script.
    expect(html).not.toContain("challenges.cloudflare.com");
    expect(html).toContain('name="robots" content="noindex');
  });

  it("with Turnstile configured: its script and the widget with the site key", async () => {
    const html = await (await call(new Request(`${BASE}/run/repaaaa1/report`), ON)).text();
    expect(html).toContain('<script src="https://challenges.cloudflare.com/turnstile/v0/api.js"');
    expect(html).toContain('class="cf-turnstile" data-sitekey="0x4AAAAAAA-site" data-action="report"');
  });

  it("other pages never load Turnstile", async () => {
    const html = await (await call(new Request(`${BASE}/run/repaaaa1`), ON)).text();
    expect(html).not.toContain("challenges.cloudflare.com");
  });

  it("without Turnstile config (and not disabled) reports are closed", async () => {
    const res = await call(new Request(`${BASE}/run/repaaaa1/report`), {});
    expect(res.status).toBe(503);
    expect(await res.text()).toContain("Reports can&#39;t be sent just now");
    const sent = await call(post("repaaaa1", { reason: "wrong_game" }), {});
    expect(sent.status).toBe(503);
    expect(await reports()).toEqual([]);
  });

  it("a hidden or unknown run: 404", async () => {
    expect((await call(new Request(`${BASE}/run/rephidden/report`), OFF)).status).toBe(404);
    expect((await call(new Request(`${BASE}/run/nosuchrun1/report`), OFF)).status).toBe(404);
    expect((await call(post("rephidden", { reason: "wrong_game" }), OFF)).status).toBe(404);
  });
});

describe("sending a report", () => {
  it("stores only run, reason, scrubbed text and time — nothing from the request", async () => {
    const res = await call(
      post(
        "repaaaa1",
        { reason: "impossible_numbers", text: "  Way too fast for this Mac. See /Users/mark/Desktop and Mark's MacBook Pro\r\n " },
        { "CF-Connecting-IP": "203.0.113.9", "User-Agent": "Test/1.0", Cookie: "a=b" },
      ),
      OFF,
    );
    expect(res.status).toBe(200);
    expect(await res.text()).toContain("Thanks — report sent");
    const rows = await reports();
    expect(rows).toHaveLength(1);
    const { id, ...row } = rows[0];
    expect(row).toEqual({
      run_id: "repaaaa1",
      reason: "impossible_numbers",
      text: "Way too fast for this Mac. See ~/Desktop and <host>",
      created: "2026-11-25T12:03:00Z",
      resolved: 0,
    });
    expect(JSON.stringify(rows)).not.toContain("203.0.113.9");
    expect(JSON.stringify(rows)).not.toContain("Test/1.0");
  });

  it("refuses a missing or unknown reason, too much text, or Something else without words", async () => {
    const bad: Record<string, string>[] = [{}, { reason: "spam" }, { reason: "other" }, { reason: "other", text: "   " }];
    for (const fields of bad) {
      const res = await call(post("repaaaa1", fields), OFF);
      expect(res.status, JSON.stringify(fields)).toBe(400);
    }
    const long = await call(post("repaaaa1", { reason: "wrong_game", text: "x".repeat(1001) }), OFF);
    expect(long.status).toBe(400);
    expect(await long.text()).toContain("1000 characters");
    expect((await call(post("repaaaa1", { reason: "wrong_game", text: "x".repeat(1000) }), OFF)).status).toBe(200);
    expect(await reports()).toHaveLength(1);
  });

  it("keeps the reason and text when the form comes back with an error", async () => {
    const html = await (await call(post("repaaaa1", { reason: "other", text: "" }), OFF)).text();
    expect(html).toContain('value="other" required="" checked=""');
    expect(html).toContain("Say what&#39;s wrong in a few words.");
  });

  it("text with HTML comes back escaped on the form", async () => {
    const html = await (await call(post("repaaaa1", { reason: "spam", text: "<script>alert(1)</script>" }), OFF)).text();
    expect(html).not.toContain("<script>alert(1)");
    expect(html).toContain("&lt;script&gt;alert(1)&lt;/script&gt;");
  });
});

describe("Turnstile", () => {
  it("a passing token: siteverify gets the secret and token, never an IP", async () => {
    const calls: Siteverify[] = [];
    const res = await call(
      post("repaaaa1", { reason: "wrong_game", "cf-turnstile-response": "tok-123" }, { "CF-Connecting-IP": "203.0.113.9" }),
      ON,
      siteverifyStub({ success: true, action: "report" }, calls),
    );
    expect(res.status).toBe(200);
    expect(calls).toEqual([
      {
        url: "https://challenges.cloudflare.com/turnstile/v0/siteverify",
        fields: { secret: "0x4AAAAAAA-secret", response: "tok-123" },
      },
    ]);
    expect(await reports()).toHaveLength(1);
  });

  it("a failing, missing or wrong-action token, or siteverify down: refused, nothing stored", async () => {
    const cases: [Record<string, string>, Fetch][] = [
      [{ "cf-turnstile-response": "tok" }, siteverifyStub({ success: false, "error-codes": ["invalid-input-response"] })],
      [{}, siteverifyStub({ success: true })],
      [{ "cf-turnstile-response": "tok" }, siteverifyStub({ success: true, action: "login" })],
      [{ "cf-turnstile-response": "tok" }, siteverifyStub("throw")],
    ];
    for (const [fields, fetch] of cases) {
      const res = await call(post("repaaaa1", { reason: "wrong_game", ...fields }), ON, fetch);
      expect(res.status).toBe(400);
      expect(await res.text()).toContain("The check that you&#39;re a person didn&#39;t pass");
    }
    expect(await reports()).toEqual([]);
  });

  it("TURNSTILE_DISABLED=1 skips siteverify even with keys set", async () => {
    const calls: Siteverify[] = [];
    const res = await call(post("repaaaa1", { reason: "wrong_game" }), { ...ON, ...OFF }, siteverifyStub({ success: false }, calls));
    expect(res.status).toBe(200);
    expect(calls).toEqual([]);
  });

  it("verifyTurnstile times out to false", async () => {
    const never: Fetch = () => new Promise(() => {});
    expect(await verifyTurnstile("tok", "secret", never, 20)).toBe(false);
  });
});

describe("carry-ins", () => {
  it("the download is private, no-cache (a removal takes effect at once)", async () => {
    await env.RUNS.put("runs/repaaaa1.zip", new Uint8Array([80, 75, 3, 4]));
    const res = await call(new Request(`${BASE}/run/repaaaa1/download`), OFF);
    expect(res.status).toBe(200);
    expect(res.headers.get("cache-control")).toBe("private, no-cache");
    await res.arrayBuffer();
  });

  it("the privacy page tells about Turnstile on the report form", async () => {
    const html = await (await call(new Request(`${BASE}/privacy`), OFF)).text();
    expect(html).toContain("Turnstile");
    expect(html).toContain("challenges.cloudflare.com");
  });
});
