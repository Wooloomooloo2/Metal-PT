import { createExecutionContext, env, waitOnExecutionContext } from "cloudflare:test";
import { beforeAll, describe, expect, it } from "vitest";
import { afterWrite } from "../src/db.ts";
import { createApp } from "../src/index.ts";
import { fpsChart, parseSeries } from "../src/pages/chart.ts";
import { compareIds } from "../src/pages/compare.tsx";
import { efficiencyPhrase } from "../src/pages/format.ts";
import { SITE_CSS } from "../src/pages/static.ts";
import { BASE, deleteRequest, newKey, NOW, oembedStub, publishRequest, syntheticUpload } from "./api-helpers.ts";
import { EVIL, seedSite, series } from "./page-seed.ts";

/** The site without an edge cache (each test sees the seeded rows directly). */
async function get(path: string, cache: Cache | null = null): Promise<{ status: number; html: string; res: Response }> {
  const app = createApp({ now: () => NOW, fetch: oembedStub(), cache: () => cache });
  const ctx = createExecutionContext();
  const res = await app.fetch(new Request(BASE + path), env, ctx);
  await waitOnExecutionContext(ctx);
  const html = res.headers.get("content-type")?.includes("zip") ? "" : await res.clone().text();
  return { status: res.status, html, res };
}

/** Text content: tags removed, whitespace collapsed, entities for the few characters JSX escapes decoded. */
function text(html: string): string {
  return html
    .replace(/<style[\s\S]*?<\/style>/g, " ")
    .replace(/<[^>]+>/g, " ")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&amp;/g, "&")
    .replace(/\s+/g, " ");
}

beforeAll(async () => {
  await seedSite();
});

describe("game page", () => {
  it("shows the most-run settings with typical, range, FPS/W and the counts", async () => {
    const { status, html } = await get("/game/cyberpunk-2077");
    expect(status).toBe(200);
    const t = text(html);
    expect(t).toContain("Cyberpunk 2077");
    expect(t).toContain("Steam app 1091520");
    // 19 visible runs (the hidden one left out) from 13 keys
    expect(t).toContain("19 runs on 13 Macs");
    // M4 Max native: typical 61.5 -> 62, range 60.5–63.5 -> 61–64, FPS/W weighted median.
    expect(t).toMatch(/M4 Max 40-core GPU Native 62 61–64 0\.5\d/);
    expect(html).toContain('<option value="high" selected="">High</option>');
  });

  it('"Not enough runs yet (2)", "Capped at 60", GPU-only FPS/W, battery not counted', async () => {
    const t = text((await get("/game/cyberpunk-2077")).html);
    expect(t).toContain("Not enough runs yet (2)");
    expect(t).toContain("Capped at 60");
    expect(t).toMatch(/M1 Pro 16-core GPU Native 24 \S+ — GPU-only power/);
    expect(t).toContain("Not counted: on battery");
    expect(t).toContain("Not counted: unknown Mac or setup");
  });

  it("outlier note and the runs behind Show them", async () => {
    const { html } = await get("/game/cyberpunk-2077");
    const t = text(html);
    expect(t).toContain("1 run set aside as an outlier and not counted.");
    expect(t).toContain("2 runs not counted (on battery, Low Power, frame-capped or unknown setup).");
    expect(html).toContain("<summary>");
    expect(t).toContain("Show them");
    const details = html.slice(html.indexOf("<details>"), html.indexOf("</details>"));
    expect(details).toContain('href="/run/outlier20a"');
    expect(details).toContain('href="/run/battery35a"');
    expect(details).toContain('href="/run/unknown40a"');
  });

  it("hidden runs are not listed or counted anywhere", async () => {
    for (const p of ["/game/cyberpunk-2077", "/", "/mac/m4-max-40", "/setup/native"]) {
      expect((await get(p)).html).not.toContain("HIDDEN RUN");
      expect((await get(p)).html).not.toContain("hidden99aa");
    }
    expect((await get("/run/hidden99aa")).status).toBe(404);
  });

  it("pickers are GET parameters: another combination", async () => {
    const t = text((await get("/game/cyberpunk-2077?preset=medium&res=1920x1080&up=off&fg=on")).html);
    expect(t).toMatch(/Not enough runs yet \(1\)/);
    expect(t).not.toContain("Capped at 60");
    const none = text((await get("/game/cyberpunk-2077?preset=low")).html);
    expect(none).toContain("No runs at these settings yet.");
  });

  it("Open Graph: game · Mac · fps · FPS/W", async () => {
    const { html } = await get("/game/cyberpunk-2077");
    expect(html).toMatch(/<meta property="og:title" content="Cyberpunk 2077 · M4 Max · 62 fps · 0\.5\d FPS\/W"/);
    expect(html).toContain('<meta property="og:url" content="https://metal-pt.test/game/cyberpunk-2077"');
  });
});

describe("run page", () => {
  it("header, chips, badge, tiles, chart, power, download and report links", async () => {
    const { status, html } = await get("/run/native62aa");
    expect(status).toBe(200);
    const t = text(html);
    expect(t).toContain("M4 Max · Native");
    expect(t).toContain("Published from Metal-PT");
    expect(t).toContain("High");
    expect(t).toContain("2560 × 1440");
    expect(t).toContain("MetalFX · Quality");
    expect(t).toContain("Frame gen off");
    expect(t).toMatch(/Median FPS 62 1% low 51/);
    expect(t).toMatch(/FPS per watt 0\.52 at 119 W whole-Mac power/);
    expect(t).toContain("16.1 ms");
    expect(t).toContain("Mostly GPU");
    expect(html).toContain('<svg class="chart"');
    expect(html).toContain('<rect x="0.0" y="0"'); // warm-up shaded
    expect(html).toContain('href="/run/native62aa/download"');
    expect(html).toContain('href="/run/native62aa/report"');
    expect(html).toContain('href="/compare?runs=native62aa"');
    expect(html).toContain('<meta property="og:title" content="Cyberpunk 2077 · M4 Max · 62 fps · 0.52 FPS/W"');
  });

  it("GPU-only power: no FPS/W; battery: not counted chip; capped run in an all-capped group is counted", async () => {
    const gpu = text((await get("/run/m1pro24a")).html);
    expect(gpu).toContain("Only GPU power was measured, so FPS/W isn't shown");
    expect((await get("/run/m1pro24a")).html).toContain('content="Cyberpunk 2077 · M1 Pro · 24 fps"');
    expect(text((await get("/run/battery35a")).html)).toContain("Not counted: on battery");
    expect(text((await get("/run/cap60aaa")).html)).not.toContain("Not counted");
    expect(text((await get("/run/outlier20a")).html)).toContain("Not counted: outlier");
  });

  it("download streams the R2 object with a filename", async () => {
    const { status, res } = await get("/run/native62aa/download");
    expect(status).toBe(200);
    expect(res.headers.get("content-type")).toBe("application/zip");
    expect(res.headers.get("content-disposition")).toBe('attachment; filename="cyberpunk-2077-native62aa.mptrun.zip"');
    expect(new TextDecoder().decode(await res.arrayBuffer())).toBe("PK fake zip bytes");
    expect((await get("/run/native63aa/download")).status).toBe(404); // no object
    expect((await get("/run/hidden99aa/download")).status).toBe(404);
  });
});

describe("compare", () => {
  it("the app's efficiency wording", () => {
    expect(efficiencyPhrase(0.39, 0.52)).toBe("25 % fewer frames per watt than the baseline");
    expect(efficiencyPhrase(1.57, 1.2)).toBe("31 % more frames per watt than the baseline");
    expect(efficiencyPhrase(1.001, 1)).toBe("the same frames per watt as the baseline");
    expect(efficiencyPhrase(null, 1)).toBeNull();
    expect(efficiencyPhrase(1, 0)).toBeNull();
  });

  it("verdict, bars, side by side with the differing row marked", async () => {
    const { status, html } = await get("/compare?runs=native62aa,crossover49");
    expect(status).toBe(200);
    const t = text(html);
    expect(t).toContain("CrossOver 25 · D3DMetal runs at 79 % of the baseline's speed, with 25 % fewer frames per watt than the baseline");
    expect(html).toContain('<span class="hi">25 % fewer frames per watt than the baseline</span>.</p>');
    expect(t).toContain("Same Mac, same settings, both on mains power.");
    expect(t).toContain("What differs: setup");
    expect(t).toContain("Native vs CrossOver 25 · D3DMetal on M4 Max");
    expect(t).toContain("Baseline");
    expect(html).toContain('<tr class="diff"><td class="muted nw">Setup</td>');
    expect(t).not.toContain("FPS/W not comparable across Macs");
    // Add a run: other runs of the same game.
    expect(html).toContain('href="/compare?runs=native62aa,crossover49,');
  });

  it("different Macs: the warning, and no efficiency phrase", async () => {
    const t = text((await get("/compare?runs=native62aa,m4base30a")).html);
    expect(t).toContain("FPS/W not comparable across Macs");
    expect(t).not.toContain("frames per watt than the baseline");
  });

  it("ids: valid, distinct, at most 6; none found -> 404", async () => {
    expect(compareIds("a1b2c3,a1b2c3,../x,BAD,zzzzzz")).toEqual(["a1b2c3", "zzzzzz"]);
    expect(compareIds(Array.from({ length: 9 }, (_, i) => `run00${i}`).join(","))).toHaveLength(6);
    expect((await get("/compare?runs=nosuchrun")).status).toBe(404);
    expect((await get("/compare")).status).toBe(404);
  });
});

describe("Mac, setup, home, search, privacy", () => {
  it("/mac/:key lists games at their most-run settings, sortable", async () => {
    const { status, html } = await get("/mac/m4-max-40");
    expect(status).toBe(200);
    const t = text(html);
    expect(t).toContain("M4 Max · 40-core GPU");
    expect(t).toContain("each game shown at its most-tested settings");
    expect(t).toMatch(/Cyberpunk 2077 Native High · 1440p · MetalFX Quality 62 61–64 0\.5\d 6 /);
    expect(html).toContain('href="/mac/m4-max-40?sort=fps"');
    // Most runs first by default; by name, "<" sorts before letters.
    const byRuns = text(html);
    expect(byRuns.indexOf("Cyberpunk 2077 Native")).toBeLessThan(byRuns.indexOf(`${EVIL} Game`));
    const byName = text((await get("/mac/m4-max-40?sort=name")).html);
    expect(byName.indexOf(`${EVIL} Game`)).toBeLessThan(byName.indexOf("Cyberpunk 2077 Native"));
  });

  it("/setup/:key shows the same table by Mac", async () => {
    const t = text((await get("/setup/crossover-25-d3dmetal")).html);
    expect(t).toContain("CrossOver 25 · D3DMetal");
    expect(t).toMatch(/Cyberpunk 2077 M2 Max 38-core GPU .* 60 60–60 Capped at 60 0\.90 4 /);
  });

  it("home: counts, most-tested games, recent runs", async () => {
    const t = text((await get("/")).html);
    expect(t).toMatch(/Runs 20 Games 2 Macs 13/);
    expect(t).toContain("Most-tested games");
    expect(t).toContain("Recently published");
  });

  it("search by title or alias", async () => {
    await env.DB.prepare("INSERT OR IGNORE INTO game_aliases (alias_norm, game_id) VALUES ('cp2077', 1)").run();
    expect(text((await get("/search?q=cyber")).html)).toContain("Cyberpunk 2077");
    expect(text((await get("/search?q=CP2077")).html)).toContain("Cyberpunk 2077");
    expect(text((await get("/search?q=zelda")).html)).toContain("No games with runs match.");
    expect((await get("/search")).status).toBe(200);
  });

  it("privacy page in plain words", async () => {
    const t = text((await get("/privacy")).html);
    expect(t).toContain("What Metal-PT sends");
    expect(t).toContain("Never stored: IP addresses, user agents or cookies.");
    expect(t).toContain("No analytics or tracking scripts on any page.");
    expect(t).toContain("Your notes, only if you ticked the box to include them.");
    expect(t).toContain("Run pages show no Mac identity beyond the model.");
  });

  it("/macs and /setups list what has runs", async () => {
    expect(text((await get("/macs")).html)).toContain("M2 Max · 38-core GPU");
    expect(text((await get("/setups")).html)).toContain("CrossOver 25 · D3DMetal");
  });
});

describe("404 page", () => {
  it("unknown game, run, Mac, setup and paths", async () => {
    for (const p of ["/game/no-such-game", "/game/BAD%20SLUG", "/run/nosuchrun", "/run/x", "/mac/m9-ultra-99", "/setup/nope", "/nowhere"]) {
      const { status, html } = await get(p);
      expect(status, p).toBe(404);
      expect(html, p).toContain("<h1>Not found</h1>");
    }
  });
});

describe("Review Focus 5: HTML in titles, notes and labels is text everywhere", () => {
  const pages = [
    "/", "/game/script-alert-1-script", "/run/evilrun1aa", "/compare?runs=evilrun1aa", "/compare?runs=native62aa,evilrun1aa",
    "/mac/m4-max-40", "/setup/native-via-evil", "/setups", "/search?q=script", `/search?q=${encodeURIComponent(EVIL)}`,
  ];
  for (const p of pages) {
    it(p, async () => {
      const { status, html } = await get(p);
      expect(status).toBe(200);
      expect(html).not.toContain("<script>alert");
      expect(html).not.toContain("<img src=x");
      expect(html).not.toContain("<b>bold");
      expect(html).not.toMatch(/<script(?![^>]*src="\/static\/site\.js)/);
    });
  }

  it("the escaped text is there (run page)", async () => {
    const { html } = await get("/run/evilrun1aa");
    expect(html).toContain("&lt;script&gt;alert(1)&lt;/script&gt; notes");
    expect(html).toContain("&lt;img src=x onerror=alert(2)&gt; label");
    expect(html).toContain("&lt;b&gt;bold&lt;/b&gt;");
    expect(html).toContain('href="https://www.youtube.com/watch?v=dQw4w9WgXcQ"');
    expect(html).toContain('rel="nofollow ugc noopener"');
    // In attributes too (Open Graph, title).
    expect(html).toContain('content="&lt;script&gt;alert(1)&lt;/script&gt; Game · M4 Max · 45 fps · 0.40 FPS/W"');
  });

  it("the chart SVG is made from numbers only", () => {
    const s = parseSeries(series(50))!;
    const c = fpsChart(s, 50);
    expect(c.svg).toMatch(/^<svg[^<]*>(<(rect|line|polyline)[^<]*><\/\2>)+<\/svg>$/);
    expect(c.svg.replace(/<[^>]*>/g, "")).toBe(""); // no text at all
    expect(c.svg).toMatch(/^[^"]*("[-\w ,.#:%()]*"[^"]*)+$/); // attribute values: numbers, colours, fixed words
    expect(parseSeries('{"v":1,"points":[["<x>",1]]}')).toBeNull();
    expect(parseSeries("not json")).toBeNull();
    expect(c.ticks.at(-1)).toEqual({ at: 100, label: "4:12" });
  });
});

describe("page shell", () => {
  it("one stylesheet from the Worker, Google Fonts the only third-party request, no cookies", async () => {
    const { html, res } = await get("/game/cyberpunk-2077");
    expect(html.startsWith("<!doctype html>")).toBe(true);
    expect(html).toContain('<link rel="stylesheet" href="/static/site.css?v=');
    const external = [...html.matchAll(/(?:src|href)="(https?:\/\/[^"]+)"/g)].map((m) => new URL(m[1]).host);
    const loaded = [...html.matchAll(/<(?:link rel="stylesheet"|script)[^>]*(?:src|href)="(https?:\/\/[^"]+)"/g)].map((m) => new URL(m[1]).host);
    expect(new Set(loaded)).toEqual(new Set(["fonts.googleapis.com"]));
    expect(external.every((h) => ["fonts.googleapis.com", "metal-pt.test"].includes(h))).toBe(true);
    expect(res.headers.get("set-cookie")).toBeNull();
    const css = await get("/static/site.css");
    expect(css.res.headers.get("content-type")).toContain("text/css");
    expect(css.html).toBe(SITE_CSS);
  });

  it("360 px: tables scroll in their own box, grids shrink to the width", () => {
    expect(SITE_CSS).toContain(".table-box{overflow-x:auto");
    expect(SITE_CSS).toMatch(/minmax\(min\(260px,100%\),1fr\)/);
    expect(SITE_CSS).toMatch(/minmax\(min\(320px,100%\),1fr\)/);
    expect(SITE_CSS).toContain("@media (max-width:600px)");
  });
});

describe("edge cache", () => {
  it("serves a page from the cache for 60 s and afterWrite purges it", async () => {
    const cache = await caches.open("pages-test-1");
    const first = await get("/run/native63aa", cache);
    expect(first.res.headers.get("cache-control")).toBe("no-cache");
    expect(text(first.html)).not.toContain("Changed notes");
    await env.DB.prepare("UPDATE runs SET notes = 'Changed notes' WHERE id = 'native63aa'").run();
    expect(text((await get("/run/native63aa", cache)).html)).not.toContain("Changed notes"); // cached
    const stored = await cache.match(new Request(BASE + "/run/native63aa"));
    expect(stored?.headers.get("cache-control")).toBe("public, max-age=60");
    await afterWrite(env, { gameIds: [1], runIds: ["native63aa"], macKeys: ["m4-max-40"], setupKeys: ["native"] }, { origin: BASE, cache });
    expect(text((await get("/run/native63aa", cache)).html)).toContain("Changed notes");
    await env.DB.prepare("UPDATE runs SET notes = NULL WHERE id = 'native63aa'").run();
  });

  it("404s are not cached", async () => {
    const cache = await caches.open("pages-test-2");
    await get("/run/nosuchrun", cache);
    expect(await cache.match(new Request(BASE + "/run/nosuchrun"))).toBeUndefined();
  });

  it("publish and delete through the API purge the run and game pages", async () => {
    const cache = await caches.open("pages-test-3");
    const app = createApp({ now: () => NOW, fetch: oembedStub(), cache: () => cache });
    const call = async (req: Request) => {
      const ctx = createExecutionContext();
      const res = await app.fetch(req, env, ctx);
      await waitOnExecutionContext(ctx);
      return res;
    };
    const key = await newKey();
    const pub = await call(await publishRequest(syntheticUpload({ title: "Cyberpunk 2077" }), key));
    expect(pub.status).toBe(201);
    const { id } = (await pub.json()) as { id: string };
    const before = await (await call(new Request(`${BASE}/game/cyberpunk-2077?x=1`))).text();
    const gameBefore = await (await call(new Request(`${BASE}/game/cyberpunk-2077`))).text();
    expect((await call(new Request(`${BASE}/run/${id}`))).status).toBe(200);
    expect(gameBefore).toContain(`/run/${id}`);
    expect(before).toContain(`/run/${id}`);

    expect((await call(await deleteRequest(id, key))).status).toBe(200);
    expect((await call(new Request(`${BASE}/run/${id}`))).status).toBe(404);
    expect(await (await call(new Request(`${BASE}/game/cyberpunk-2077`))).text()).not.toContain(`/run/${id}`);
    // A query-string variant is not purged: it expires after 60 s.
    expect(await (await call(new Request(`${BASE}/game/cyberpunk-2077?x=1`))).text()).toContain(`/run/${id}`);
  });
});
