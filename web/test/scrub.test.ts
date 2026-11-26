import { describe, expect, it } from "vitest";
import { scrub, scrubPaths } from "../src/lib/scrub.ts";

describe("scrubPaths (as Privacy.scrubPaths)", () => {
  it("home paths become ~", () => {
    expect(scrubPaths("/Users/mark/Games/x")).toBe("~/Games/x");
    expect(scrubPaths("/users/Mark")).toBe("~");
  });
  it("Wine prefix users keep their folder, name replaced", () => {
    expect(scrubPaths("/Users/mark/pfx/drive_c/users/mark/AppData")).toBe("~/pfx/drive_c/users/~/AppData");
    expect(scrubPaths("drive_c/users/crossover/x")).toBe("drive_c/users/~/x");
  });
  it("Windows home paths", () => {
    expect(scrubPaths("C:\\Users\\mark\\Saved")).toBe("C:\\Users\\~\\Saved");
  });
  it("leaves other text alone", () => {
    expect(scrubPaths("High, MetalFX Quality")).toBe("High, MetalFX Quality");
  });
});

describe("scrub: host-name patterns", () => {
  it("computer names", () => {
    expect(scrub("recorded on Mark's MacBook Pro today")).toBe("recorded on <host> today");
    expect(scrub("Jo’s Mac mini (2)")).toBe("<host>");
    expect(scrub("Ann's iMac")).toBe("<host>");
  });
  it("local host names", () => {
    expect(scrub("ssh Marks-MacBook-Pro-2.local")).toBe("ssh <host>");
    expect(scrub("Marks-MacBook-Air")).toBe("<host>");
    expect(scrub("on Ann-Mac-Studio now")).toBe("on <host> now");
  });
  it("any .local name", () => {
    expect(scrub("studio.local:22")).toBe("<host>:22");
  });
  it("keeps model names without an owner and ordinary text", () => {
    expect(scrub("MacBook Pro M4 Max, High preset")).toBe("MacBook Pro M4 Max, High preset");
    expect(scrub("Mac mini")).toBe("Mac mini");
    expect(scrub("Baldur's Gate 3")).toBe("Baldur's Gate 3");
  });
});
