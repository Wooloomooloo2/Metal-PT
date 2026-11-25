# Metal-PT website, part 2: the site and the app's Publish — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Cloudflare Worker site (API + server-rendered pages) on a staging `workers.dev` address, and the app's
Publish / Remove / video-link editing wired to it.

**Architecture:** One Worker in `web/` (TypeScript, Hono + JSX), D1 for rows and cached group statistics, R2 for the
uploaded zips. Pure modules (re-check, stats, keys, YouTube, game matching) are tested against the golden fixtures from
part 1. The app gains a `SiteClient` (URLSession, injectable) and Publish UI. Production on metal-pt.com is NOT
deployed in this plan.

**Tech Stack:** TypeScript, Hono (JSX), Cloudflare Workers / D1 / R2, `cf` CLI (`cloudflare.config.ts`), Vitest with
the Workers runtime pool; Swift 6 for the app.

**Spec:** `docs/superpowers/specs/2026-11-25-metal-pt-website-design.md`. Part 1 plan:
`docs/superpowers/plans/2026-11-25-metal-pt-website-app-prep.md` (its fixtures in `web/test/fixtures/`).

## Global Constraints
- Workers **Free** plan: 10 ms CPU per request. The upload never unzips; `samples.csv` parsed once, only the columns in
  spec §J; pages read D1 rows, never CSVs. A test records CPU time for the 60-minute fixture (see Task 3).
- **No IP address used, logged or stored**; no cookies; no analytics; Worker logs never include request headers.
- Use `cf` for Cloudflare (`cf cli search`, `--dry-run` first). Never touch `garelochsoft.com` or the `mfl-website`
  Worker. Resources named `metal-pt-staging` (D1), `metal-pt-runs-staging` (R2), Worker `metal-pt-staging`.
  Production resources and the metal-pt.com custom domain are NOT created in this plan.
- Page copy, wording and numbers follow the mockups (https://claude.ai/artifact/RAC3mVz5oBjCGcNxUmAv8W): colours
  #F6F7F9 ground, #14161A text, #5A6170 muted, #2457D6 accent, #B23A0A FPS/W; Inter / Space Grotesk / JetBrains Mono
  (Google Fonts link is the only third-party request); pages work at 360 px wide; badge text "Published from Metal-PT".
- Stats rules exactly spec §4.E; checks exactly spec §4.C; API exactly spec §4.B.
- App: Swift rules as part 1 (explicit pathspecs, never `git reset`, never commit `docs/data/aldente-ids.txt`, don't
  launch the real app).

## Review Focus
1. A group of 4 runs from one Mac and 1 from another: weights make it 2 Macs → typical/range shown only if ≥ 3 runs
   and ≥ 2 keys (yes here); a single Mac's 10 runs never show a range ("Not enough runs yet").
2. Same bundle published twice → 409 with the first run's URL; the app treats it as "Already published" and records
   that URL.
3. A video URL that fails oEmbed (private/deleted) or the YouTube rules → run published without a link; reply message
   says why; the page never prints the submitted URL text.
4. Deleting the last counted run in a group → group row removed (no stale typical on the game page).
5. HTML escaping: a game title / notes containing `<script>` renders as text everywhere (JSX escapes; no
   `dangerouslySetInnerHTML` except the server-built SVG from numbers).

---

### Task 1: Project, schema and staging resources
**Files:** `web/package.json`, `web/cloudflare.config.ts` (via `cf init` or by hand per `cf` docs), `web/tsconfig.json`,
`web/vitest.config.ts`, `web/migrations/0001_init.sql`, `web/src/index.ts` (Hono app, `/healthz`), `.gitignore`
(`web/node_modules`, `web/.wrangler`, `web/.cf`).
- Schema per spec §4.D (tables `macs`, `games`, `game_aliases`, `runs`, `groups`, `reports`), plus `runs.bundle_sha256
  UNIQUE`, indexes on runs `(game_id)`, `(mac_key)`, `(setup_key)`, `(published)`, `(key_id)`, `(group_key)`.
- [ ] Test: Vitest pool boots the Worker with local D1 + R2, applies migrations, `GET /healthz` → 200 "ok".
- [ ] Create staging D1 and R2 with `cf` (dry-run first; record ids in the config). Commit `Scaffold the website
  Worker`.

### Task 2: Pure modules
**Files:** `web/src/lib/{recheck,stats,keys,youtube,games,csv,signing}.ts` + tests under `web/test/`.
**Interfaces (produces):**
- `csv.ts`: `parseColumns(text: string, wanted: string[]): Record<string, (string|undefined)[]>` — RFC-4180, header by
  name, empty = undefined.
- `recheck.ts`: `recheck(run: RunJson, samples: string): { medianFPS: number|null; fpsPerWatt: number|null;
  meanW: number|null; powerSource: 'system'|'gpuOnly'|'none'; steadyRows: number; steadySeconds: number }` —
  a line-for-line port of `RunSummary`'s steady-row selection and power fallback (`Sources/MPTCore/Bench/
  RunSummary.swift` lines 41–90 and its fpsPerWatt). `matches(summary, recheck) : string | null` (null = ok; else the
  message) with tolerances 0.5 fps and 2 %.
- `youtube.ts`: `videoID(url: string): string | null`, `canonicalURL(id)` — identical rules to `YouTubeLink.swift`
  (same test table).
- `keys.ts`: `macKey(machine)` (`m4-max-40`, or `unknown`), `setupKey(run, title)` + `setupLabel` per spec §4.D (via
  only for native; graphics layers sorted, joined), `groupKey(...)`.
- `games.ts`: `normalizeTitle(s)`, `slugify(s)`.
- `stats.ts`: `groupStats(runs: StatRun[]): GroupStats` where `StatRun = { id, keyId, fps, fpw: number|null, onAC,
  lowPower, capped: boolean, capFPS: number|null, hidden, unknown }` → `{ counted, macs, typical, p25, p75, typicalFPW,
  outlierIds, cappedAt: number|null, enough: boolean }`; weights 1/(runs per key); weighted percentile = smallest value
  whose cumulative weight ≥ q·total (state this in a comment); Tukey fences at ≥ 5 counted runs; caps rule and counted
  rule exactly spec §4.E.
- `signing.ts`: `verify(publicKeyB64url, message: string, sigB64url): Promise<boolean>` (WebCrypto ECDSA P-256 SHA-256,
  raw key import of the X9.63 point), message builders identical to `SiteSigning.swift`.
- [ ] Tests first: recheck equals each fixture's `expected.json` within 1e-6; Review Focus 1; outliers only at ≥ 5;
  caps (mixed group drops capped; ≥ 75 % capped → cappedAt); battery/Low Power not counted; YouTube table from part 1;
  signature from fixture `headers.json` verifies and a 1-byte change fails.
- [ ] Commit `Website pure modules: re-check, statistics, keys, signing`.

### Task 3: API
**Files:** `web/src/api/{publish,patch,delete}.ts`, `web/src/db.ts`, `web/src/oembed.ts` (fetch injectable),
tests `web/test/api.test.ts`.
- POST/PATCH/DELETE exactly spec §4.B and checks §4.C (order: size, headers, timestamp, signature, part hashes, JSON
  shape, required fields, re-check, sanity, scrub). R2 `put` with `sha256` = signed bundle hash. Game match §4.D.
  Group recompute after every write (`stats.groupStats`, upsert/delete `groups`). Rate limit: the Workers
  rate-limiting binding keyed on key id (30/hour); if the binding is unavailable on Free, a D1 count of the key's runs
  in the last hour. Error bodies `{ code, message }`, messages written for the app to show as is.
- [ ] Tests: each fixture publishes (201, row values); every §4.C failure gives its code; Review Focus 2, 3, 4; PATCH
  and DELETE need the publishing key (403 otherwise); a 60-minute synthetic run (generated in the test) publishes and
  the test logs its CPU-relevant timing (report it; flag if the parse alone > 5 ms locally).
- [ ] Commit `Website API: publish, edit video link, remove`.

### Task 4: Pages
**Files:** `web/src/pages/{layout,home,game,run,compare,mac,setup,search,privacy,notfound}.tsx`,
`web/src/pages/chart.ts` (SVG from `fps_series`), `web/src/pages/format.ts`, tests `web/test/pages.test.ts`.
- Routes and contents per spec §4.F and the mockups; `/privacy` per §4.I in plain words; Open Graph tags on run and
  game pages; edge cache 60 s via the Cache API with purge of affected URLs on publish/patch/delete; "Download" streams
  the R2 object. Compare wording identical to the app's `CompareReport` efficiency sentence.
- [ ] Tests: seeded D1 → each page 200 with key strings (game typical/range, "Not enough runs yet (2)", "Capped at 60",
  outlier note, "Published from Metal-PT", privacy text); Review Focus 5; unknown slugs → 404 page.
- [ ] Render each page from local dev to HTML files in the scratchpad and Read them (phone width check by CSS review).
  Commit `Website pages`.

### Task 5: Reports and admin
**Files:** `web/src/pages/report.tsx`, `web/src/admin/*.tsx`, tests.
- "Report a problem" form (reasons per spec §4.H) with Turnstile (site key/secret from config; when unset in tests,
  the check is skipped only if `TURNSTILE_DISABLED=1`). `/admin` requires a valid Cloudflare Access JWT
  (`Cf-Access-Jwt-Assertion`, verified against the team's certs; team domain and AUD from config); with no Access
  config, `/admin` returns 404. Admin: reports queue, hide/unhide run, remove video link, ban key, merge/rename game,
  edit aliases — each write recomputes affected groups.
- [ ] Tests (JWT verification with a test keypair), commit `Website reports and admin`.

### Task 6: Staging deploy and smoke test
- [ ] Apply migrations to staging D1 and deploy the Worker to `metal-pt-staging.<account>.workers.dev` with `cf`.
- [ ] Smoke: publish each fixture with `curl` (multipart, fixture `headers.json`), open game/run/compare pages,
  PATCH and DELETE one; then delete the smoke runs so staging starts clean. Record the URL in CLAUDE.md.
  Commit `Deploy website staging`.

### Task 7: App — publish, remove, edit link
**Files:** `Sources/MPTApp/SiteClient.swift` (new), `Sources/MPTApp/RunIndex.swift` (`publishedID`,
`publishedURL`, cacheVersion 6), `Sources/MetalPT/SubmitSheet.swift`, `Sources/MetalPT/RunsPage.swift`,
`Sources/MetalPT/SettingsPage.swift`, `Sources/MetalPT/AppModel.swift`, `Sources/mpt/…` (`mpt publish <run>
[--site URL]`), tests `Tests/MPTAppTests/SiteClientTests.swift`.
**Interfaces:** `public struct SiteClient { init(base: URL, signer: RunSigner, session: HTTPTransport =
URLSession.shared, now: () -> Date = Date.init); func publish(_ p: PublishPayload) async throws -> Published;
func setVideo(id: String, url: String?) async throws; func remove(id: String) async throws }`, `Published { id, url,
alreadyPublished: Bool }`, `SiteError { message: String }` (server message as is; offline → "Can't reach
metal-pt.com — try again later"). Base URL: `MPT_SITE_URL` env in debug builds, else the staging URL until the user
approves production (constant `SiteClient.defaultBase`, one line to change).
- Submit sheet: graphics fields (required; missing highlighted), video field, notes tick, "Publish" → progress →
  "Published" with Open page / Copy link, or the message. Runs list: published mark; menu "Open on metal-pt.com",
  "Remove from metal-pt.com…" (confirm). Edit sheet saves a changed video link to the site when published.
  Setting "Offer to publish after each run" (default off): after Stop, a notification action opens the Submit sheet.
- [ ] Tests with a stub transport: multipart body parts and headers (signature verifies with the stub's key),
  201/409/4xx/offline handling, index records URL; then `mpt publish` against staging with a fixture run; delete it.
- [ ] Snapshots of the Submit sheet states; Read them. Rebuild `scripts/make-app.sh metal-pt`. Commit
  `Publish runs to the website from the app`.

### Task 8: Docs
- [ ] README (publishing, privacy summary, video links), CLAUDE.md (state, staging URL, how to go live: create prod
  D1/R2, custom domain metal-pt.com, Access + Turnstile setup, flip `SiteClient.defaultBase`). Commit
  `Document the website and publishing`.
