import { describe, expect, it } from "vitest";
import { parseColumns, parseGeneral, parseUnquoted } from "../src/lib/csv.ts";
import { FIXTURE_NAMES, fixtureText } from "./fixtures.ts";

describe("parseColumns", () => {
  it("picks wanted columns by header name, empty cells undefined", () => {
    const text = "a,b,c\n1,,3\n4,5,6\n";
    expect(parseColumns(text, ["c", "b"])).toEqual({ c: ["3", "6"], b: [undefined, "5"] });
  });

  it("a wanted column missing from the header is all undefined", () => {
    expect(parseColumns("a\n1\n2", ["z"])).toEqual({ z: [undefined, undefined] });
  });

  it("undoes RFC-4180 quoting: commas, doubled quotes and newlines inside quotes", () => {
    const text = 'a,b\n"x,y","say ""hi"""\n"line1\nline2",2\n';
    expect(parseColumns(text, ["a", "b"])).toEqual({ a: ["x,y", "line1\nline2"], b: ['say "hi"', "2"] });
  });

  it("handles CRLF and lone CR line ends, skips blank lines, no trailing newline", () => {
    expect(parseColumns("a,b\r\n1,2\r\n\r\n3,4\r5,6", ["a", "b"])).toEqual({ a: ["1", "3", "5"], b: ["2", "4", "6"] });
  });

  it("short rows give undefined; extra cells are ignored", () => {
    expect(parseColumns("a,b\n1\n2,3,4\n", ["a", "b"])).toEqual({ a: ["1", "2"], b: [undefined, "3"] });
  });

  it("a quoted empty cell is empty (undefined)", () => {
    expect(parseColumns('a,b\n"",1\n', ["a"])).toEqual({ a: [undefined] });
  });

  it("empty text gives empty columns", () => {
    expect(parseColumns("", ["a"])).toEqual({ a: [] });
  });
});

describe("parseUnquoted (the fast path) equals parseGeneral", () => {
  const wanted = ["elapsed_s", "fps", "fps_app", "smc_PSTR_w", "gpu_w", "on_ac", "nope"];
  it.each(FIXTURE_NAMES)("on fixture %s", (name) => {
    const text = fixtureText(name, "samples.csv");
    expect(text.includes('"')).toBe(false);
    expect(parseUnquoted(text, wanted)).toEqual(parseGeneral(text, wanted));
  });
  it.each([
    ["blank lines and a trailing comma", "a,b,c\n\n1,2,\n\n4,,6\n"],
    ["short and long rows", "a,b,c\n1\n1,2,3,4,5\n,\n"],
    ["no final newline", "a,b\n1,2"],
    ["header only", "a,b\n"],
    ["leading blank lines", "\n\na,b\n1,2\n"],
    ["repeated header name", "a,b,a\n1,2,3\n4,5\n"],
    ["white space is a value", "a,b\n ,2\n \n"],
    ["empty", ""],
  ])("%s", (_, text) => {
    for (const w of [["a"], ["b", "c"], ["c", "a", "x"]]) expect(parseUnquoted(text, w)).toEqual(parseGeneral(text, w));
  });
});
