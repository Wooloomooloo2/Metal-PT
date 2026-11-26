import { describe, expect, it } from "vitest";
import { matches, recheck, type SummaryJson } from "../src/lib/recheck.ts";
import type { RunJson } from "../src/lib/run-json.ts";
import { FIXTURE_NAMES, fixtureJSON, fixtureText } from "./fixtures.ts";

const close = (a: number | null, b: number | null) => {
  if (a === null || b === null) return expect(a).toBe(b);
  expect(Math.abs(a - b)).toBeLessThan(1e-6);
};

describe("recheck against the golden fixtures", () => {
  it.each(FIXTURE_NAMES)("%s equals expected.json within 1e-6", (name) => {
    const exp = fixtureJSON(name, "expected.json");
    const r = recheck(fixtureJSON<RunJson>(name, "run.json"), fixtureText(name, "samples.csv"));
    close(r.medianFPS, exp.medianFPS);
    close(r.fpsPerWatt, exp.fpsPerWatt);
    expect(r.powerSource).toBe(exp.powerSource);
    if (exp.powerSource === "system") close(r.meanW, exp.meanSystemW);
    expect(r.steadySeconds).toBeGreaterThanOrEqual(60);
  });

  it.each(FIXTURE_NAMES)("%s matches its own summary.json", (name) => {
    const r = recheck(fixtureJSON<RunJson>(name, "run.json"), fixtureText(name, "samples.csv"));
    expect(matches(fixtureJSON<SummaryJson>(name, "summary.json"), r)).toBeNull();
  });

  it("the steady window is [steadyStartS, steadyEndS] when there is a warm-up", () => {
    // system-warmup: rows 1..200 s, steady 20..200 → 181 rows.
    const r = recheck(fixtureJSON<RunJson>("system-warmup", "run.json"), fixtureText("system-warmup", "samples.csv"));
    expect(r.steadyRows).toBe(181);
  });
});

describe("matches", () => {
  const name = "system-warmup";
  const r = () => recheck(fixtureJSON<RunJson>(name, "run.json"), fixtureText(name, "samples.csv"));
  const s = () => fixtureJSON<SummaryJson>(name, "summary.json");

  it("within 0.5 fps is fine, beyond names the problem", () => {
    expect(matches({ ...s(), medianFPS: s().medianFPS! + 0.49 }, r())).toBeNull();
    expect(matches({ ...s(), medianFPS: s().medianFPS! + 0.6 }, r())).toMatch(/median FPS/i);
  });

  it("FPS/W within 2 % is fine, beyond names the problem", () => {
    expect(matches({ ...s(), fpsPerWatt: s().fpsPerWatt! * 1.019 }, r())).toBeNull();
    expect(matches({ ...s(), fpsPerWatt: s().fpsPerWatt! * 1.03 }, r())).toMatch(/FPS\/W/);
    expect(matches({ ...s(), fpsPerWatt: s().fpsPerWatt! * 0.97 }, r())).toMatch(/FPS\/W/);
  });

  it("mean system power within 2 % is fine, beyond names the problem", () => {
    expect(matches({ ...s(), meanSystemW: s().meanSystemW! * 1.019 }, r())).toBeNull();
    expect(matches({ ...s(), meanSystemW: s().meanSystemW! * 1.05 }, r())).toMatch(/power/i);
  });

  it("a different power source, or a missing value, does not match", () => {
    expect(matches({ ...s(), powerSource: "gpuOnly" }, r())).toMatch(/power source/i);
    expect(matches({ ...s(), fpsPerWatt: null }, r())).toMatch(/FPS\/W/);
    expect(matches({ ...s(), medianFPS: null }, r())).toMatch(/median FPS/i);
  });

  it("gpu-only: FPS/W checked; meanSystemW must be null", () => {
    const g = recheck(fixtureJSON<RunJson>("gpu-only", "run.json"), fixtureText("gpu-only", "samples.csv"));
    const gs = fixtureJSON<SummaryJson>("gpu-only", "summary.json");
    expect(matches({ ...gs, fpsPerWatt: gs.fpsPerWatt! * 1.05 }, g)).toMatch(/FPS\/W/);
    expect(matches({ ...gs, meanSystemW: 30 }, g)).toMatch(/power/i);
  });
});

// Synthetic runs for RunSummary's fallback (no warm-up) rules.
const HEADER = "elapsed_s,fps,fps_app,smc_PSTR_w,gpu_w";
function csv(rows: [number | string, number | string, string, number | string, number | string][]): string {
  return [HEADER, ...rows.map((r) => r.join(","))].join("\n") + "\n";
}
function info(steadyStartS: number | null, steadyEndS: number | null): RunJson {
  const base = fixtureJSON<RunJson>("no-warmup", "run.json");
  return { ...base, steadyStartS, steadyEndS };
}

describe("recheck: RunSummary's fallback row selection", () => {
  it("follows the most common fps_app, trims its first 10 s, drops rows above 2x the median", () => {
    const rows: [number, number | string, string, number, number][] = [];
    for (let t = 1; t <= 40; t++) rows.push([t, t === 30 ? 101 : 50, "game", 20, 10]); // 101 > 2 x 50
    for (let t = 41; t <= 45; t++) rows.push([t, 999, "launcher", 20, 10]);
    const r = recheck(info(null, null), csv(rows));
    // game rows 1..40; t0 = 1, so rows from 11 s: 30 rows, one (101 fps) above 2 x 50 dropped.
    expect(r.steadyRows).toBe(29);
    expect(r.medianFPS).toBe(50);
    expect(r.meanW).toBe(20);
    expect(r.fpsPerWatt).toBe(2.5);
    expect(r.powerSource).toBe("system");
  });

  it("a tie between apps goes to the alphabetically first name", () => {
    const rows: [number, number, string, number, number][] = [];
    for (let t = 1; t <= 20; t++) rows.push([t, 40, "b-app", 20, 10]);
    for (let t = 21; t <= 40; t++) rows.push([t, 80, "a-app", 20, 10]);
    expect(recheck(info(null, null), csv(rows)).medianFPS).toBe(80);
  });

  it("without any fps_app all FPS rows are candidates", () => {
    const rows: [number, number, string, number, number][] = [];
    for (let t = 1; t <= 30; t++) rows.push([t, t, "", 10, 5]);
    const r = recheck(info(null, null), csv(rows));
    // rows 11..30 (fps 11..30), median 20.5, none above 41.
    expect(r.steadyRows).toBe(20);
    expect(r.medianFPS).toBe(20.5);
  });

  it("never past the recorded end (steadyEndS) even without a warm-up", () => {
    const rows: [number, number, string, number, number][] = [];
    for (let t = 1; t <= 100; t++) rows.push([t, t <= 50 ? 30 : 90, "g", 10, 5]);
    const r = recheck(info(0, 50), csv(rows));
    expect(r.steadyRows).toBe(40);
    expect(r.medianFPS).toBe(30);
  });

  it("no FPS at all: steady is every row in the window, no median", () => {
    const rows: [number, string, string, number, number][] = [];
    for (let t = 1; t <= 5; t++) rows.push([t, "", "", 10, 5]);
    const r = recheck(info(null, null), csv(rows));
    expect(r.steadyRows).toBe(5);
    expect(r.steadySeconds).toBe(0);
    expect(r.medianFPS).toBeNull();
    expect(r.fpsPerWatt).toBeNull();
    expect(r.powerSource).toBe("system");
  });

  it("warm-up window: rows without elapsed_s are left out", () => {
    const rows: [number | string, number, string, number, number][] = [
      [1, 10, "g", 10, 5],
      ["", 99, "g", 10, 5],
      [2, 20, "g", 10, 5],
      [3, 30, "g", 10, 5],
    ];
    const r = recheck(info(2, 3), csv(rows));
    expect(r.steadyRows).toBe(2);
    expect(r.medianFPS).toBe(25);
  });

  it("power falls back to gpu_w (gpuOnly), else none", () => {
    const gpu = csv([
      [1, 60, "g", "", 10],
      [2, 60, "g", "", 20],
    ]);
    const a = recheck(info(1, 2), gpu);
    expect(a.powerSource).toBe("gpuOnly");
    expect(a.meanW).toBe(15);
    expect(a.fpsPerWatt).toBe(4);
    const none = recheck(info(1, 2), csv([[1, 60, "g", "", ""]]));
    expect(none.powerSource).toBe("none");
    expect(none.fpsPerWatt).toBeNull();
    expect(none.meanW).toBeNull();
  });

  it("zero mean power gives no FPS/W", () => {
    const r = recheck(info(1, 2), csv([[1, 60, "g", 0, 5]]));
    expect(r.powerSource).toBe("system");
    expect(r.fpsPerWatt).toBeNull();
  });

  it("non-numbers and non-finite values are left out of the stats", () => {
    const r = recheck(info(1, 4), csv([
      [1, 60, "g", 10, 5],
      [2, "abc", "g", "inf", 5],
      [3, 70, "g", "x", 5],
      [4, " 80", "g", 20, 5],
    ]));
    expect(r.medianFPS).toBe(65);
    expect(r.meanW).toBe(15);
  });
});
