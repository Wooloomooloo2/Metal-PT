import { describe, expect, it } from "vitest";
import { capOf, groupStats, weightedPercentile, type StatRun } from "../src/lib/stats.ts";

let n = 0;
function r(keyId: string, fps: number, extra: Partial<StatRun> = {}): StatRun {
  n += 1;
  return {
    id: `r${n}`,
    keyId,
    fps,
    fpw: fps / 50,
    onAC: true,
    lowPower: false,
    capped: false,
    capFPS: null,
    hidden: false,
    unknown: false,
    ...extra,
  };
}

describe("weightedPercentile", () => {
  it("is the smallest value whose cumulative weight reaches q of the total", () => {
    const v = [
      { value: 10, weight: 1 },
      { value: 20, weight: 1 },
      { value: 30, weight: 1 },
      { value: 40, weight: 1 },
    ];
    expect(weightedPercentile(v, 0.25)).toBe(10);
    expect(weightedPercentile(v, 0.5)).toBe(20);
    expect(weightedPercentile(v, 0.75)).toBe(30);
    expect(weightedPercentile(v, 1)).toBe(40);
  });

  it("thirds that sum to just under 1 still reach the median", () => {
    const third = 1 / 3;
    const v = [10, 20, 30].map((value) => ({ value, weight: third }));
    expect(weightedPercentile(v, 0.5)).toBe(20);
    expect(weightedPercentile(v, 1)).toBe(30);
  });

  it("empty -> null", () => expect(weightedPercentile([], 0.5)).toBeNull());
});

describe("groupStats: one Mac counts once (Review Focus 1)", () => {
  it("4 runs from one Mac + 1 from another: 2 Macs, 5 runs, typical and range shown", () => {
    const runs = [r("A", 60), r("A", 61), r("A", 62), r("A", 63), r("B", 80)];
    const s = groupStats(runs);
    expect(s.counted).toBe(5);
    expect(s.macs).toBe(2);
    expect(s.enough).toBe(true);
    // Weights: A's runs 0.25 each (total 1), B 1; total 2. Median: cumulative ≥ 1 first at A's 63.
    expect(s.typical).toBe(63);
    // p25: cumulative ≥ 0.5 at 61; p75: ≥ 1.5 only at B's 80.
    expect(s.p25).toBe(61);
    expect(s.p75).toBe(80);
    expect(s.outlierIds).toEqual([]);
  });

  it("a single Mac's 10 runs never show a typical or range", () => {
    const runs = Array.from({ length: 10 }, (_, i) => r("A", 50 + i));
    const s = groupStats(runs);
    expect(s.counted).toBe(10);
    expect(s.macs).toBe(1);
    expect(s.enough).toBe(false);
    expect(s.typical).toBeNull();
    expect(s.p25).toBeNull();
    expect(s.p75).toBeNull();
    expect(s.typicalFPW).toBeNull();
  });

  it("2 runs from 2 Macs is not enough (fewer than 3 runs)", () => {
    const s = groupStats([r("A", 50), r("B", 52)]);
    expect(s.enough).toBe(false);
    expect(s.counted).toBe(2);
    expect(s.typical).toBeNull();
  });

  it("3 runs from 2 Macs is enough", () => {
    const s = groupStats([r("A", 50), r("A", 52), r("B", 54)]);
    expect(s.enough).toBe(true);
    // A: 0.5 + 0.5, B: 1; total 2: median at cumulative ≥ 1 → 52.
    expect(s.typical).toBe(52);
  });
});

describe("groupStats: outliers", () => {
  it("never marked with fewer than 5 runs", () => {
    const s = groupStats([r("A", 50), r("B", 51), r("C", 52), r("D", 500)]);
    expect(s.outlierIds).toEqual([]);
    expect(s.counted).toBe(4);
  });

  it("marked at 5 runs (Tukey fences on weighted quartiles), excluded from the counted runs", () => {
    const far = r("E", 500);
    const s = groupStats([r("A", 50), r("B", 51), r("C", 52), r("D", 53), far]);
    expect(s.outlierIds).toEqual([far.id]);
    expect(s.counted).toBe(4);
    expect(s.macs).toBe(4);
    expect(s.typical).toBe(51);
  });

  it("low outliers too", () => {
    const low = r("E", 2);
    const s = groupStats([r("A", 50), r("B", 51), r("C", 52), r("D", 53), r("F", 54), low]);
    expect(s.outlierIds).toEqual([low.id]);
  });

  it("a value on the fence is not an outlier", () => {
    // Q1 = 10, Q3 = 20 (IQR 10): fences -5 and 35.
    const runs = [r("A", 10), r("B", 10), r("C", 20), r("D", 20), r("E", 35)];
    expect(groupStats(runs).outlierIds).toEqual([]);
  });
});

describe("groupStats: counted runs", () => {
  it("battery, Low Power, hidden and unknown runs are not counted", () => {
    const runs = [
      r("A", 50),
      r("B", 52),
      r("C", 54),
      r("D", 10, { onAC: false }),
      r("E", 10, { lowPower: true }),
      r("F", 10, { hidden: true }),
      r("G", 10, { unknown: true }),
    ];
    const s = groupStats(runs);
    expect(s.counted).toBe(3);
    expect(s.macs).toBe(3);
    expect(s.typical).toBe(52);
    expect(s.outlierIds).toEqual([]);
  });

  it("excluded runs do not make 5 for the outlier rule", () => {
    const runs = [r("A", 50), r("B", 51), r("C", 52), r("D", 500), r("E", 10, { onAC: false })];
    expect(groupStats(runs).outlierIds).toEqual([]);
  });

  it("FPS/W uses only runs that have it (system power), weighted per Mac", () => {
    const runs = [r("A", 50, { fpw: 1 }), r("A", 50, { fpw: 3 }), r("B", 50, { fpw: null }), r("C", 50, { fpw: 2 })];
    // fpw runs: A 1 (0.5), A 3 (0.5), C 2 (1); total 2 → median at cumulative ≥ 1: sorted 1(0.5),2(1.5) → 2.
    expect(groupStats(runs).typicalFPW).toBe(2);
  });

  it("no run with FPS/W -> null", () => {
    const runs = [r("A", 50, { fpw: null }), r("B", 50, { fpw: null }), r("C", 50, { fpw: null })];
    const s = groupStats(runs);
    expect(s.enough).toBe(true);
    expect(s.typicalFPW).toBeNull();
  });

  it("no runs at all", () => {
    const s = groupStats([]);
    expect(s).toEqual({
      counted: 0,
      macs: 0,
      typical: null,
      p25: null,
      p75: null,
      typicalFPW: null,
      outlierIds: [],
      cappedAt: null,
      enough: false,
    });
  });
});

describe("groupStats: frame caps", () => {
  const cap = (keyId: string, fps: number) => r(keyId, fps, { capped: true, capFPS: Math.round(fps) });

  it("a mixed group leaves the capped runs out of typical and range", () => {
    const runs = [r("A", 80), r("B", 82), r("C", 84), cap("D", 60), cap("E", 60)];
    const s = groupStats(runs);
    expect(s.counted).toBe(3);
    expect(s.typical).toBe(82);
    expect(s.cappedAt).toBeNull();
    // The capped runs are not outliers: they were never in the pool.
    expect(s.outlierIds).toEqual([]);
  });

  it("≥ 75 % capped -> cappedAt is the median cap", () => {
    const runs = [cap("A", 60), cap("B", 60), cap("C", 30), r("D", 45)];
    const s = groupStats(runs);
    expect(s.cappedAt).toBe(60);
  });

  it("just under 75 % capped -> no cappedAt", () => {
    const runs = [cap("A", 60), cap("B", 60), r("C", 45), r("D", 46)];
    expect(groupStats(runs).cappedAt).toBeNull();
  });

  it("all capped: they are the typical", () => {
    const runs = [cap("A", 60), cap("B", 60), cap("C", 60)];
    const s = groupStats(runs);
    expect(s.cappedAt).toBe(60);
    expect(s.counted).toBe(3);
    expect(s.typical).toBe(60);
  });

  it("capped runs on battery do not count towards the 75 %", () => {
    const runs = [cap("A", 60), cap("B", 60), cap("C", 60, ), r("D", 45), r("E", 46)].map((x, i) =>
      i < 2 ? { ...x, onAC: false } : x,
    );
    expect(groupStats(runs).cappedAt).toBeNull();
  });
});

describe("capOf", () => {
  it("frameCap primary -> capped at the rounded median FPS", () => {
    expect(capOf("frameCap", 59.6)).toEqual({ capped: true, capFPS: 60 });
  });
  it("anything else -> not capped", () => {
    expect(capOf("gpu", 59.6)).toEqual({ capped: false, capFPS: null });
    expect(capOf(null, 59.6)).toEqual({ capped: false, capFPS: null });
    expect(capOf("frameCap", null)).toEqual({ capped: true, capFPS: null });
  });
});
