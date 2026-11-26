import { describe, expect, it } from "vitest";
import { canonicalURL, videoID } from "../src/lib/youtube.ts";

// The same table as Tests/MPTCoreTests/YouTubeLinkTests.swift.
const accepts = [
  "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
  "https://youtube.com/watch?v=dQw4w9WgXcQ&t=42s",
  "https://m.youtube.com/watch?feature=share&v=dQw4w9WgXcQ",
  "https://youtu.be/dQw4w9WgXcQ",
  "https://youtu.be/dQw4w9WgXcQ?si=abc",
  "https://www.youtube.com/shorts/dQw4w9WgXcQ",
  "https://www.youtube.com/live/dQw4w9WgXcQ",
  "  https://youtu.be/dQw4w9WgXcQ  ",
];

const rejects = [
  "https://youtube.com.evil.com/watch?v=dQw4w9WgXcQ",
  "https://evil.com/youtube.com/watch?v=dQw4w9WgXcQ",
  "https://notyoutube.com/watch?v=dQw4w9WgXcQ",
  "https://youtube.com@evil.com/watch?v=dQw4w9WgXcQ",
  "http://www.youtube.com/watch?v=dQw4w9WgXcQ",
  "http://youtu.be/dQw4w9WgXcQ",
  "https://www.youtube.com/redirect?q=https://evil.com&v=dQw4w9WgXcQ",
  "https://www.youtube.com/watch?v=short",
  "https://www.youtube.com/watch?v=dQw4w9WgXcQQ",
  "https://www.youtube.com/watch?v=dQw4w9WgX!Q",
  "https://youtu.be/dQw4w9WgXc",
  "https://youtu.be/dQw4w9WgXc/extra",
  "https://www.youtube.com/watch",
  "https://www.youtube.com/dQw4w9WgXcQ",
  "ftp://youtu.be/dQw4w9WgXcQ",
  "dQw4w9WgXcQ",
  "",
];

// Beyond the Swift table: ports (even the default one), user info, case and odd characters.
const extraRejects = [
  "https://www.youtube.com:443/watch?v=dQw4w9WgXcQ",
  "https://youtu.be:8443/dQw4w9WgXcQ",
  "https://user:pw@youtu.be/dQw4w9WgXcQ",
  "https://@youtu.be/dQw4w9WgXcQ",
  "https://youtu.be/dQw4w9WgXcQ extra",
  "https://youtu.be/%ZZw4w9WgXcQ",
  "javascript:alert(1)//youtu.be/dQw4w9WgXcQ",
];

describe("videoID", () => {
  it.each(accepts)("accepts %s", (s) => expect(videoID(s)).toBe("dQw4w9WgXcQ"));
  it.each(rejects)("rejects %s", (s) => expect(videoID(s)).toBeNull());
  it.each(extraRejects)("rejects %s", (s) => expect(videoID(s)).toBeNull());

  it("lowercases the host (as URLComponents' host.lowercased())", () => {
    expect(videoID("https://WWW.YouTube.com/watch?v=dQw4w9WgXcQ")).toBe("dQw4w9WgXcQ");
  });

  it("takes the first v= and keeps the ID's case", () => {
    expect(videoID("https://youtube.com/watch?v=AbC_-1234xY&v=dQw4w9WgXcQ")).toBe("AbC_-1234xY");
  });
});

describe("canonicalURL", () => {
  it("is the www watch form", () => {
    expect(canonicalURL("dQw4w9WgXcQ")).toBe("https://www.youtube.com/watch?v=dQw4w9WgXcQ");
  });
});
