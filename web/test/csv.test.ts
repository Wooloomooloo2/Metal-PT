import { describe, expect, it } from "vitest";
import { parseColumns } from "../src/lib/csv.ts";

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
