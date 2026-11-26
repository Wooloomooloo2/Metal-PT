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
`*.workers.dev`, so staging shows no page caching. The cache key is the path plus only the known query parameters
(`preset, res, up, fg, sort, runs, find, q`, in that order); any other parameter shares the bare URL's entry.

Group recomputes (`db.ts` `recomputeGroups`) cost one read and one batch of at most 4 statements per chunk of 200
groups (each statement binds one JSON array via `json_each`), so ≤ 5 D1 statements per chunk; the admin
"Recompute statistics" page does one chunk per request (≤ 10 statements in all).

### Run length cap: 90 minutes

A publish parses and re-checks the whole samples.csv inside one request, so runs are capped:

- steady window ≤ 90 minutes (`MAX_STEADY_SECONDS` = 5400: the larger of the steady seconds with FPS and the steady
  rows' elapsed span), else 422 `too_long` ("Runs longer than 90 minutes can't be published yet — record a shorter
  run.");
- samples.csv ≤ 2 MiB (`MAX_SAMPLES_BYTES`; real runs write ~230 bytes per 1 Hz row, so 90 minutes is ~1.4 MB),
  run.json ≤ 256 KB, summary.json ≤ 16 KB, the whole upload ≤ 25 MiB.

The app refuses the same runs before sending (`PublishLimits` in `Sources/MPTCore/Bench/PublishPayload.swift`);
change both sides together. A 60-minute run's parse and re-check fit the Free plan's budget (see the "60-minute
run" test); raising the cap needs a new measurement, or the Paid plan.

## Privacy rules for contributors

These are promised on the /privacy page; keep them true.

- Never store or log IP addresses, user agents, cookies or request headers (no `console.log` of requests, no
  analytics, no Logpush of headers).
- Observability is set explicitly in `cloudflare.config.ts`: Workers Logs on for what the code logs (errors only),
  **invocation logs off** (they record each request's URL and headers, including `CF-Connecting-IP` and
  `User-Agent`), traces off, Logpush off, query strings redacted. Don't turn invocation logs or traces on.
- No third-party requests from pages except Google Fonts (typefaces) and, on the report page only, Cloudflare
  Turnstile. No YouTube thumbnails or embeds: video links are plain links.
- Turnstile's siteverify gets only the secret and the token, never the visitor's address.
- Scrub free text (names, home folder paths) before storing; run pages show no Mac identity beyond the model.
- The signing key is used inside the site only and never shown.

## Setup: Cloudflare Access (admin) and Turnstile (reports)

Nothing here is created by the code or by a deploy. Do it on the staging Worker `metal-pt-staging` first, then again
for production.

| Name | Kind | What |
|------|------|------|
| `ACCESS_TEAM_DOMAIN` | var | Zero Trust team: `<team>`, `<team>.cloudflareaccess.com` or its URL |
| `ACCESS_AUD` | var | The Access application's Application Audience (AUD) tag |
| `TURNSTILE_SITE_KEY` | var | Turnstile widget's site key (public) |
| `TURNSTILE_SECRET` | secret | Turnstile widget's secret key |

Without both Access values every `/admin` URL is a 404. Without both Turnstile values the report form answers 503
"Reports can't be sent just now". Never set `TURNSTILE_DISABLED` outside tests.

**Cloudflare Access (admin)**

1. Zero Trust dashboard (one.dash.cloudflare.com) → choose a team name if none yet (Settings → Custom Pages shows
   the team domain `<team>.cloudflareaccess.com`; the exact menu may differ — Zero Trust Settings shows it).
2. Settings → Authentication: add a login method (One-time PIN to your email is enough).
3. Access → Applications → Add → Self-hosted. Name "Metal-PT admin". Application domain: the Worker's hostname with
   path `admin` — add two destinations, path `admin` and `admin/*` (for staging the `metal-pt-staging.<sub>.workers.dev`
   host; later `metal-pt.com`). Session duration e.g. 24 h.
4. Policy: Action Allow, Include → Emails → your email only.
5. After saving, open the application's Overview/Basic information and copy the **Application Audience (AUD) Tag**.
6. Give the Worker the two values (not secret, but either way works):
   - in `web/cloudflare.config.ts`, inside `env` for staging: `ACCESS_TEAM_DOMAIN: bindings.text("<team>")`,
     `ACCESS_AUD: bindings.text("<aud tag>")`, then `cf deploy --mode staging`; or
   - Workers & Pages → metal-pt-staging → Settings → Variables and Secrets (dashboard plain-text vars may be replaced
     by the next deploy; the config file is the safer place).
7. Check: open `https://<host>/admin` in a private window → Access login → the reports queue. `curl` to `/admin`
   without signing in → Access's redirect (or 403 from the Worker if Access isn't on that hostname).
   **workers.dev:** Access only protects hostnames it is configured for; enable it on the workers.dev route (Workers →
   metal-pt-staging → Settings → Domains & Routes → workers.dev → "Enable Cloudflare Access") or add the hostname as
   above. Even without that, the Worker refuses any request without a valid JWT, so the admin is never open.

**Turnstile (report form)**

1. Dashboard → Turnstile → Add widget. Name "Metal-PT reports"; hostnames: the staging workers.dev host (later
   `metal-pt.com`); Widget mode Managed; no pre-clearance.
2. Copy the **Site Key** and **Secret Key**.
3. Site key (public): `TURNSTILE_SITE_KEY: bindings.text("<site key>")` in `cloudflare.config.ts` staging `env` (or a
   dashboard variable).
4. Secret: Workers & Pages → metal-pt-staging → Settings → Variables and Secrets → Add → type **Secret**, name
   `TURNSTILE_SECRET`. (This `cf` version has `cf workers secrets list/get/delete` but no `put`; `npx wrangler secret
   put TURNSTILE_SECRET --name metal-pt-staging` also works.) Optionally declare it in the config with
   `TURNSTILE_SECRET: bindings.secret()` so local dev warns when it's missing.
5. Never set `TURNSTILE_DISABLED` outside tests. Until both keys are set, the report form shows "Reports can't be sent
   just now" (503).
6. Check: open a run → "Report a problem" → the widget appears, a report sends, and it shows on `/admin`.
7. Apply migration 0003 to staging before deploying: `npm run migrate:staging`.
