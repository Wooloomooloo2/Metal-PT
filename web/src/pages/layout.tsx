// The page frame: head (title, Open Graph, the one stylesheet, Google Fonts), site header with search, footer.
// Every text value here goes through JSX, which escapes it (Review Focus 5).
import type { Child } from "hono/jsx";
import { STATIC_VERSION } from "./static.ts";

export type Section = "games" | "macs" | "setups" | "privacy" | null;

export interface PageMeta {
  /** The <title>, without the site name. */
  title: string;
  description?: string;
  /** Open Graph title and the page's absolute URL (run and game pages). */
  og?: { title: string; description: string; url: string };
  section?: Section;
  /** The header search box's current text (search page). */
  query?: string;
}

const FONTS =
  "https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&family=Space+Grotesk:wght@500;600;700&family=JetBrains+Mono:wght@500&display=swap";

export function Layout(props: PageMeta & { children?: Child }) {
  const cur = (s: Section) => (props.section === s ? { "aria-current": "page" as const } : {});
  return (
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>{props.title === "" ? "Metal-PT" : `${props.title} · Metal-PT`}</title>
        {props.description ? <meta name="description" content={props.description} /> : null}
        <meta name="referrer" content="strict-origin-when-cross-origin" />
        {props.og ? (
          <>
            <meta property="og:type" content="website" />
            <meta property="og:site_name" content="Metal-PT" />
            <meta property="og:title" content={props.og.title} />
            <meta property="og:description" content={props.og.description} />
            <meta property="og:url" content={props.og.url} />
            <meta name="twitter:card" content="summary" />
            <link rel="canonical" href={props.og.url} />
          </>
        ) : null}
        <link rel="preconnect" href="https://fonts.googleapis.com" />
        <link rel="stylesheet" href={FONTS} />
        <link rel="stylesheet" href={`/static/site.css?v=${STATIC_VERSION}`} />
        <script src={`/static/site.js?v=${STATIC_VERSION}`} defer></script>
      </head>
      <body>
        <header class="site-head">
          <div class="wrap">
            <a class="brand" href="/">Metal-PT</a>
            <nav class="nav" aria-label="Main">
              <a href="/" {...cur("games")}>Games</a>
              <a href="/macs" {...cur("macs")}>Macs</a>
              <a href="/setups" {...cur("setups")}>Setups</a>
              <a href="/privacy" {...cur("privacy")}>Privacy</a>
            </nav>
            <form class="head-search" action="/search" method="get" role="search">
              <label class="sr" for="q">Search games</label>
              <input id="q" type="search" name="q" placeholder="Search games…" value={props.query ?? ""} />
            </form>
          </div>
        </header>
        <main class="wrap">{props.children}</main>
        <footer class="site-foot">
          <div class="wrap">
            <span>Runs are published from the Metal-PT app on a Mac, and checked by this site before they show.</span>
            <a href="/privacy">What Metal-PT sends</a>
          </div>
        </footer>
      </body>
    </html>
  );
}
