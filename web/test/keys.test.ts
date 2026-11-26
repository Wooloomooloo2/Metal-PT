import { describe, expect, it } from "vitest";
import { graphicsLayers, groupKey, isUnknown, macKey, setupKey, setupLabel } from "../src/lib/keys.ts";
import type { RunJson } from "../src/lib/run-json.ts";
import { fixtureJSON } from "./fixtures.ts";

function run(stack: RunJson["stack"], exe = "game.exe", title?: string): RunJson {
  const base = fixtureJSON<RunJson>("system-warmup", "run.json");
  return { ...base, stack, game: { exe, title } };
}

describe("macKey", () => {
  it.each([
    [{ chip: "Apple M4 Max", gpuCores: 40 }, "m4-max-40"],
    [{ chip: "Apple M1", gpuCores: 8 }, "m1-8"],
    [{ chip: "Apple M3 Pro", gpuCores: 18 }, "m3-pro-18"],
    [{ chip: "Apple M2 Ultra", gpuCores: 76 }, "m2-ultra-76"],
    [{ chip: "Apple M4 Max", gpuCores: null }, "unknown"],
    [{ chip: "Apple M4 Max" }, "unknown"],
    [{ chip: "", gpuCores: 10 }, "unknown"],
  ])("%o -> %s", (m, key) => expect(macKey(m)).toBe(key));

  it("reads the fixture's machine", () => {
    expect(macKey(fixtureJSON<RunJson>("system-warmup", "run.json").machine)).toBe("m4-max-40");
  });
});

describe("setupKey / setupLabel", () => {
  it("Wine runtime: runtime, major version, graphics layers; never a via even when the exe differs", () => {
    const r = run({ runtime: "CrossOver", runtimeVersion: "25.1.0", graphics: ["D3DMetal"] }, "witcher3.exe", "The Witcher 3");
    expect(setupKey(r, "The Witcher 3")).toBe("crossover-25-d3dmetal");
    expect(setupLabel(r, "The Witcher 3")).toBe("CrossOver 25 · D3DMetal");
  });

  it("the fixture (Protium, no version, DXMT)", () => {
    const r = fixtureJSON<RunJson>("system-warmup", "run.json");
    expect(setupKey(r, "Horizon Zero Dawn")).toBe("protium-dxmt");
    expect(setupLabel(r, "Horizon Zero Dawn")).toBe("Protium · DXMT");
  });

  it("all detected layers, sorted, joined", () => {
    const r = run({ runtime: "Protium", runtimeVersion: "0.3.1", graphics: ["vkd3d", "DXMT", "KosmicKrisp"] });
    expect(setupKey(r, "G")).toBe("protium-0-dxmt-kosmickrisp-vkd3d");
    expect(setupLabel(r, "G")).toBe("Protium 0 · DXMT + KosmicKrisp + vkd3d");
    expect(graphicsLayers(r.stack)).toBe("DXMT + KosmicKrisp + vkd3d");
  });

  it("layer order does not change the key", () => {
    const a = run({ runtime: "Whisky", runtimeVersion: "2.3", graphics: ["DXMT", "MoltenVK"] });
    const b = run({ runtime: "Whisky", runtimeVersion: "2.3", graphics: ["MoltenVK", "DXMT"] });
    expect(setupKey(a, "G")).toBe(setupKey(b, "G"));
  });

  it("Wine runtime without graphics layers", () => {
    const r = run({ runtime: "GPTK", runtimeVersion: "2.1", graphics: [] });
    expect(setupKey(r, "G")).toBe("gptk-2");
    expect(setupLabel(r, "G")).toBe("GPTK 2");
  });

  it("native, recorded app is the game: plain native", () => {
    const r = run({ runtime: "native", graphics: [] }, "Cyberpunk 2077", "Cyberpunk 2077");
    expect(setupKey(r, "Cyberpunk 2077")).toBe("native");
    expect(setupLabel(r, "Cyberpunk 2077")).toBe("Native");
  });

  it("native, no title (the exe is the game): plain native", () => {
    const r = run({ runtime: "native", graphics: [] }, "Cyberpunk 2077");
    expect(setupKey(r, "Cyberpunk 2077")).toBe("native");
  });

  it("native, recorded app differs (an emulator): via the app", () => {
    const r = run({ runtime: "native", graphics: [] }, "ARMSX2", "Gran Turismo 4");
    expect(setupKey(r, "Gran Turismo 4")).toBe("native-via-armsx2");
    expect(setupLabel(r, "Gran Turismo 4")).toBe("Native · via ARMSX2");
  });

  it("native: case/punctuation-only differences are the same app", () => {
    const r = run({ runtime: "native", graphics: [] }, "baldurs gate 3", "Baldur's Gate 3");
    expect(setupKey(r, "Baldur's Gate 3")).toBe("native");
  });

  it.each([
    [{ runtime: undefined, graphics: [] }],
    [{ runtime: null, graphics: ["DXMT"] }],
    [{ runtime: "Wine (unknown)", graphics: ["DXMT"] }],
  ])("unknown runtime -> unknown (%o)", (stack) => {
    const r = run(stack as RunJson["stack"]);
    expect(setupKey(r, "G")).toBe("unknown");
    expect(setupLabel(r, "G")).toBe("Unknown setup");
  });

  it("no stack at all -> unknown", () => {
    const r = { ...fixtureJSON<RunJson>("system-warmup", "run.json") };
    delete (r as Partial<RunJson>).stack;
    expect(setupKey(r, "G")).toBe("unknown");
  });
});

describe("groupKey", () => {
  const g = {
    gameId: 7,
    macKey: "m4-max-40",
    setupKey: "crossover-25-d3dmetal",
    preset: "high",
    width: 2560,
    height: 1440,
    upscaler: "metalfx",
    upscalerMode: "quality",
    frameGeneration: false,
  };

  it("joins every dimension", () => {
    expect(groupKey(g)).toBe("7|m4-max-40|crossover-25-d3dmetal|high|2560x1440|metalfx-quality|fg-off");
  });

  it("each dimension changes the key", () => {
    const k = groupKey(g);
    for (const change of [
      { gameId: 8 },
      { macKey: "m4-pro-20" },
      { setupKey: "native" },
      { preset: "ultra" },
      { width: 1920 },
      { height: 1080 },
      { upscaler: "fsr" },
      { upscalerMode: "performance" },
      { frameGeneration: true },
    ]) {
      expect(groupKey({ ...g, ...change })).not.toBe(k);
    }
  });

  it("the mode is ignored when the upscaler is off", () => {
    expect(groupKey({ ...g, upscaler: "off", upscalerMode: "quality" })).toBe(
      groupKey({ ...g, upscaler: "off", upscalerMode: null }),
    );
  });
});

describe("isUnknown", () => {
  it("either key unknown", () => {
    expect(isUnknown("unknown", "native")).toBe(true);
    expect(isUnknown("m4-max-40", "unknown")).toBe(true);
    expect(isUnknown("m4-max-40", "native")).toBe(false);
  });
});
