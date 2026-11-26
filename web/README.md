# Metal-PT website (web/)

The site behind metal-pt.com: a Cloudflare Worker (Hono + JSX) with D1 (SQLite) for data and R2 for the uploaded
run files. Design: `docs/superpowers/specs/2026-11-25-metal-pt-website-design.md`. Configured for the `cf` CLI
(`cloudflare.config.ts`), not Wrangler.

## Develop

    cd web
    npm install
    npm test                 # vitest in the Workers runtime, local D1/R2, no network
    npm run typecheck
    npm run dev              # cf dev, local D1/R2 (default http://localhost:5173)
    cf d1 migrations apply 3c0451a9-1b96-446d-94f8-005aa3f606db --dir migrations --local --persist-to .cloudflare/state

The last line applies migrations to the local dev database (needed once before `npm run dev` serves data).
To point the Mac app or `mpt` at it: `MPT_SITE_URL=http://localhost:5173` (the app honours it in debug builds only).

Only staging exists: `npm run migrate:staging`, `npm run deploy:staging` (`cf deploy --mode staging`). A production
build or deploy fails on purpose in `cloudflare.config.ts` until production is set up.

## Layout of src/

- `index.ts`: the Hono app, the `Env` type, route registration.
- `api/`: the signed publish/patch/delete API used by the app (`publish.ts`, `patch.ts`, `delete.ts`, `auth.ts`,
  `validate.ts`, `sanity.ts`, `errors.ts`).
- `pages/`: the public HTML pages (home, game, run, compare, mac, setup, search, report, privacy) and `static.ts` (CSS).
- `admin/`: moderation behind Cloudflare Access (`access.ts` checks the JWT; `actions.ts` does every write).
- `lib/`: pure modules (signing, scrub, stats, recheck, youtube, games, keys, series, csv, run-json).
- `db.ts` (queries, group recompute), `cache.ts` (Cache API), `turnstile.ts`, `oembed.ts`, `config.ts`, `deps.ts`.
- `migrations/`: D1 schema. `test/`: vitest suites and fixtures.

## Free-plan CPU budget

Written for the Workers Free plan (10 ms CPU per request, limits on D1 queries and subrequests per request). So:
keep parsing and hashing off hot paths, cache parsed numbers, batch D1 work (one read, one `batch`) and keep admin
writes to a bounded number of D1 calls (group recomputes work in chunks; `POST /admin/recompute` repairs the rest).
Public pages are cached with the Cache API for about 60 s and purged on writes. The Cache API does nothing on
`*.workers.dev`, so staging shows no page caching.

## Privacy rules for contributors

These are promised on the /privacy page; keep them true.

- Never store or log IP addresses, user agents, cookies or request headers (no `console.log` of requests, no
  analytics, no Logpush of headers).
- No third-party requests from pages except Google Fonts (typefaces) and, on the report page only, Cloudflare
  Turnstile. No YouTube thumbnails or embeds: video links are plain links.
- Turnstile's siteverify gets only the secret and the token, never the visitor's address.
- Scrub free text (names, home folder paths) before storing; run pages show no Mac identity beyond the model.
- The signing key is used inside the site only and never shown.
