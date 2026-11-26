// YouTube video links (spec §4.C.6): the same rules as `YouTubeLink` (Sources/MPTCore/Bench/YouTubeLink.swift).
// Only the 11-character ID is ever stored; the submitted URL is never echoed.

const HOSTS = new Set(["youtube.com", "www.youtube.com", "m.youtube.com"]);
const SHORT_HOST = "youtu.be";
const ID = /^[A-Za-z0-9_-]{11}$/;

// RFC 3986 appendix B, as `URLComponents(string:)` splits a URL.
const URI = /^(?:([^:/?#]+):)?(?:\/\/([^/?#]*))?([^?#]*)(?:\?([^#]*))?(?:#(.*))?$/;
// Characters `URLComponents(string:)` accepts unescaped; anything else (spaces, quotes, <>, non-ASCII…) fails it.
const URI_CHARS = /^(?:[A-Za-z0-9\-._~:/?#[\]@!$&'()*+,;=]|%[0-9A-Fa-f]{2})*$/;

function decode(s: string): string | null {
  try {
    return decodeURIComponent(s);
  } catch {
    return null;
  }
}

/**
 * The 11-character video ID of an https YouTube link (`/watch?v=ID`, `youtu.be/ID`, `/shorts/ID`, `/live/ID`),
 * else null: other hosts (including look-alikes such as `youtube.com.evil.com`), http, user info, ports (even
 * `:443`) and IDs of another shape are all refused.
 */
export function videoID(url: string): string | null {
  // Swift trims `.whitespacesAndNewlines`; JS `trim` covers the same Unicode white space and line ends.
  const s = url.trim();
  if (s === "" || !URI_CHARS.test(s)) return null;
  const m = URI.exec(s);
  if (!m) return null;
  const [, scheme, authority, rawPath, query] = m;
  if (scheme !== "https") return null; // case-sensitive, as Swift compares `c.scheme == "https"`
  if (authority === undefined) return null;
  // User info (even empty: "https://@host") and any port are refused.
  if (authority.includes("@") || authority.includes(":")) return null;
  const host = decode(authority)?.toLowerCase();
  const path = decode(rawPath);
  if (!host || path === null) return null;

  const parts = path.split("/").filter((p) => p !== "");
  let id: string | null = null;
  if (host === SHORT_HOST) {
    id = parts.length === 1 ? parts[0] : null;
  } else if (HOSTS.has(host)) {
    if (path === "/watch") {
      id = null;
      for (const item of (query ?? "").split("&")) {
        const eq = item.indexOf("=");
        const name = decode(eq === -1 ? item : item.slice(0, eq));
        if (name === "v") {
          id = eq === -1 ? null : decode(item.slice(eq + 1));
          break;
        }
      }
    } else if (parts.length === 2 && (parts[0] === "shorts" || parts[0] === "live")) {
      id = parts[1];
    }
  }
  return id !== null && ID.test(id) ? id : null;
}

/** The one form the site links to. */
export function canonicalURL(id: string): string {
  return `https://www.youtube.com/watch?v=${id}`;
}
