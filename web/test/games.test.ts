import { describe, expect, it } from "vitest";
import { normalizeTitle, slugify } from "../src/lib/games.ts";

describe("normalizeTitle", () => {
  it.each([
    ["Baldur's Gate 3", "baldurs gate 3"],
    ["  Cyberpunk   2077 ", "cyberpunk 2077"],
    ["DEATH STRANDING™ Director’s Cut", "death stranding directors cut"],
    ["Tom Clancy's® Rainbow Six®: Siege", "tom clancys rainbow six siege"],
    ["Half-Life 2", "halflife 2"],
    ["Ｆｕｌｌ　Ｗｉｄｔｈ", "full width"],
    ["Pokémon", "pokémon"],
    ["™®", ""],
  ])("%s -> %s", (input, out) => expect(normalizeTitle(input)).toBe(out));

  it("the same game written two ways normalises the same", () => {
    expect(normalizeTitle("Horizon Zero Dawn™")).toBe(normalizeTitle("horizon zero dawn"));
  });
});

describe("slugify", () => {
  it.each([
    ["Baldur's Gate 3", "baldurs-gate-3"],
    ["Cyberpunk 2077", "cyberpunk-2077"],
    ["DEATH STRANDING™ Director’s Cut", "death-stranding-directors-cut"],
    ["Half-Life 2: Episode One", "half-life-2-episode-one"],
    ["Pokémon Légendes", "pokemon-legendes"],
    ["  --Weird__Name!!  ", "weird-name"],
    ["ARMSX2.app", "armsx2-app"],
    ["™", ""],
  ])("%s -> %s", (input, out) => expect(slugify(input)).toBe(out));

  it("slugs are URL-safe", () => {
    expect(slugify("<script>alert(1)</script> / ? # & 漢字")).toMatch(/^[a-z0-9]+(-[a-z0-9]+)*$|^$/);
  });
});
