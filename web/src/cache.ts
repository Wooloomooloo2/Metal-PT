// Edge cache for the HTML pages (spec §4.F): each page's response is kept for 60 s in this data centre's cache
// (Cache API, keyed by the path and the known query parameters, `cacheKeyURL`), and a publish, video-link change or remove purges the pages it touches.
//
// Limits, by design:
// - The Cache API is per data centre, so a purge clears the copies where the write was handled; elsewhere a page
//   can be up to 60 s stale. (A global purge needs the zone purge API and a token; not worth it for 60 s.)
// - Only the bare URLs are purged: a game page with picker parameters, a search, and every /compare URL simply
//   expire after 60 s (their query strings can't be listed).
// - Browsers are told `no-cache`, so a purge reaches the next page load.

export const PAGE_TTL_S = 60;
const EDGE = `public, max-age=${PAGE_TTL_S}`;
const BROWSER = "no-cache";

/** The query parameters a page reads, in the order they go into the cache key. Any other parameter is ignored. */
export const PAGE_PARAMS = ["preset", "res", "up", "fg", "sort", "runs", "find", "q"] as const;

/**
 * The cache key: GET of the route path plus only the known query parameters (first value of each, as the pages
 * read them), in a fixed order. Unknown parameters and the parameters' order don't make new entries, so a
 * `?x=1`, `?x=2`, … loop can't fill the cache or dodge a purge of the bare URL.
 */
export function cacheKeyURL(url: string): string {
  const u = new URL(url);
  const out = new URL(u.origin + u.pathname);
  for (const p of PAGE_PARAMS) {
    const v = u.searchParams.get(p);
    if (v !== null) out.searchParams.set(p, v);
  }
  return out.href;
}

function key(url: string): Request {
  return new Request(cacheKeyURL(url), { method: "GET" });
}

function forBrowser(res: Response): Response {
  const out = new Response(res.body, res);
  out.headers.set("Cache-Control", BROWSER);
  return out;
}

/**
 * Serves `url` from `cache` when present; else renders, stores a 200 for 60 s (in the background via `waitUntil`)
 * and returns it.
 */
export async function cachedPage(
  cache: Cache | null,
  url: string,
  waitUntil: (p: Promise<unknown>) => void,
  render: () => Promise<Response>,
): Promise<Response> {
  if (cache === null) return render();
  const k = key(url);
  const hit = await cache.match(k);
  if (hit) return forBrowser(hit);
  const res = await render();
  if (res.status !== 200) return res;
  const stored = new Response(res.body, res);
  stored.headers.set("Cache-Control", EDGE);
  waitUntil(cache.put(k, stored.clone()));
  return forBrowser(stored);
}

/** Removes each path (on `origin`) from `cache`. Failures are logged without the URL and never fail the write. */
export async function purge(cache: Cache | null, origin: string, paths: string[]): Promise<void> {
  if (cache === null) return;
  const unique = [...new Set(paths)];
  const results = await Promise.allSettled(unique.map((p) => cache.delete(key(new URL(p, origin).href))));
  if (results.some((r) => r.status === "rejected")) console.error("purge: some cached pages were not removed");
}
