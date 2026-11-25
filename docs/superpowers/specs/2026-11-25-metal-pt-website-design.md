# Metal-PT website (metal-pt.com) — design

Date: 2026-11-25. Status: draft for the user's approval. Extends `2026-11-24-metal-pt-design.md` §6 (upload format)
and `docs/run-bundle-format.md`. Mockups (sample numbers): https://claude.ai/artifact/RAC3mVz5oBjCGcNxUmAv8W (game
page, run page, compare, browse by Mac, and an upload check screen that now lives in the app instead, see §B).

## 1. Intent

A public database of how games run on Apple Silicon Macs, fed only by Metal-PT. A player looks up a game and sees, per
Mac and setup (native, CrossOver, an emulator…), the typical fps and a range, the way Steam shows a Steam Deck rating.
A tester publishes a run from the app with one button and gets a link to share. FPS per watt is a headline figure
throughout (user: "fps/watt is a key metric").

Why: Metal-PT already records trustworthy runs; today they stay on one Mac. Translation layers and emulators change
monthly, and nobody has comparable numbers across Macs.

### Goals (user's words where quoted)
- Game page: fps range per Mac (chip + GPU cores) and setup, at fixed settings ("use fixed settings, record preset,
  resolution and upscaler"; frame generation added and accepted).
- Results resist junk: "anything way out of [the distribution] for any given hardware or game should not affect averages
  or medians".
- Publishing happens entirely in the app: "I was hoping no one would have to download their result and upload to a site."
- Pages: game lookup, single run with share link, compare runs, browse by Mac, browse by setup.
- Site-side aggregates: "average fps for a game on a specific Mac … number of submissions for a game or most popular Mac".
  A metrics page comes later; the data model must make it cheap (§G).

### Non-goals (first version)
Accounts, comments, ratings; a web upload form (every run comes from the app); a metrics page (data ready, page later);
Windows/Linux data; pulling game names or art from Steam.

### Anti-goals
- A figure on the site that one person can move by uploading many runs, or by editing a file.
- Anything identifying a person or a specific Mac on a public page (no user name, host name, serial, paths).
- Pages that need JavaScript to show their numbers, or links that preview badly in chats.

## 2. Constraints
- Cloudflare, the user's account, zone `metal-pt.com` (free plan). Use the `cf` CLI (user's global CLAUDE.md); never
  touch `garelochsoft.com` or the `mfl-website` Worker.
- Upload body ≤ 25 MB (existing app rule; one Worker request).
- Run format schema 1 stays; new `run.json` keys are optional (old runs load unchanged).
- The app keeps its rules: never root, privacy scrubbing (`Privacy.swift`), no `ProcessInfo.hostName`.
- The site is read-only for the public; writes come only from signed app requests and the admin.

## 3. Approaches (chosen: A)
- **A. Server-rendered pages; the app computes the run analysis; the site re-checks the headline figures and computes
  every cross-run figure — chosen.** Plain HTML with server-drawn SVG charts: fast on a phone, good link previews. One
  copy of the per-run analysis (the app's `RunSummary`, `LimiterAnalysis`); the site recomputes median FPS and FPS/W
  from `samples.csv` and rejects mismatches, and trusts the signed limiter verdict, which never feeds a range.
- B. As A but the site re-implements all analysis — rejected: two copies of the analysis to keep in step, to protect a
  verdict that no aggregate uses. A can grow into B if forged runs appear.
- C. Client-side app (SPA) over a JSON API — rejected: more to build, slower first load, weak link previews; the
  filters are four drop-downs.
- User, choosing A: site-side aggregates (averages per Mac, counts, popularity) are the site's job — they are (§E, §G).

## 4. Design

### A. App: what a run must carry (app changes)
1. **Graphics settings** — new optional `run.json` object `graphics`:
   `preset` (`low|medium|high|veryHigh|ultra|custom`), `width`/`height` (output resolution, ints),
   `upscaler` (`off|metalfx|fsr|xess|dlss|other`), `upscalerMode` (`quality|balanced|performance|ultraPerformance|
   native`, absent when off), `frameGeneration` (bool). Set in "Edit Settings/Notes…" and on the Submit sheet; the
   free-text `user.gameSettings` stays. Resolution picker: the main display's size, common sizes (1280×800, 1920×1080,
   1920×1200, 2560×1440, 2560×1600, 3024×1964, 3456×2234), and custom.
2. **Steam app ID**: the recorder fills `game.storeAppID` as `steam:<id>` from the game process's environment
   (`SteamAppId`, else `SteamGameId`), read with the existing `ProcessNames.environment(pid:)`.
3. **Signing key**: on the first Submit, the app creates a P-256 key in the Secure Enclave (CryptoKit
   `SecureEnclave.P256.Signing.PrivateKey`), stores its `dataRepresentation` in Application Support
   (`Metal-PT/site-key`), never exported. The public key (raw X9.63, base64url) is the Mac's anonymous identity
   ("key id" = first 16 hex chars of its SHA-256).
4. **Submit** (replaces "Submit (website coming soon)"): the sheet shows what will be public, the four graphics
   fields (required to publish; missing ones highlighted), the existing notes tick box, then **Publish**. The app
   builds the existing `.mptrun.zip` in memory, plus `summary.json` (below), signs, POSTs, and shows "Published" with
   Open page / Copy link, or the site's reason on failure (offline → "Try again"). "Export file…" stays.
5. **Published state**: the run index records `publishedID` and `publishedURL` (RunIndex cache bump); the Runs list
   shows a published mark; the run's menu gains "Open on metal-pt.com" and "Remove from metal-pt.com…" (signed DELETE).
5a. **Video link** (optional) on the Submit sheet and in "Edit Settings/Notes…": "YouTube video about this run". The
   app accepts only YouTube URLs (same rule as §C.6) and says so beside the field. Stored in `run.json` as
   `user.videoURL` (optional); sent in the upload; editable after publishing with a signed `PATCH` (§B).
6. **Setting** "Offer to publish after each run" (off by default): after Stop, a notification/sheet offers Publish.
7. **Site address**: `https://metal-pt.com`; debug builds read `MPT_SITE_URL` to point at staging.

`summary.json` (inside the zip, listed in `manifest.json`): `{ "summaryVersion": 1, "medianFPS", "p1LowFPS",
"fpsPerWatt", "meanSystemW", "steadyStartS", "steadyEndS", "limiter": { "primary", "verdict" }, "powerSource":
"system|gpuOnly|none" }` from `RunSummary`/`LimiterAnalysis`; null where the app has none.

### B. Upload API (one Worker)
- `POST /api/v1/runs` — `multipart/form-data`, total ≤ 25 MB, built so the Worker never unzips anything (fits the
  Free plan's 10 ms CPU per request, §J): parts `bundle` (the existing `.mptrun.zip`, streamed to R2 unopened with
  R2's own SHA-256 check), and `run.json`, `samples.csv`, `summary.json` (copies of the zip's files, parsed by the
  Worker). Headers: `MPT-Key` (public key), `MPT-Timestamp` (ISO-8601, ±10 min of server time), `MPT-Signature`
  (DER ECDSA over SHA-256 of `"metal-pt-run\n" + sha256(bundle) + "\n" + sha256(run.json) + "\n" +
  sha256(samples.csv) + "\n" + sha256(summary.json) + "\n" + timestamp`). The Worker hashes the three small parts
  itself; the bundle's hash is enforced by R2 on write. That the small parts equal the zip's copies is vouched for by
  the signature, not re-checked. Replies `201 { id, url }`, or `4xx { code, message }` with a message the app shows
  as is.
- `PATCH /api/v1/runs/:id` — signed like DELETE (`"metal-pt-patch\n" + id + "\n" + sha256(body) + "\n" + timestamp`);
  body `{ "videoURL": string|null }`; only the publishing key. (Only the video link is editable after publishing.)
- `DELETE /api/v1/runs/:id` — same signature scheme over `"metal-pt-delete\n" + id + "\n" + timestamp`; only the key
  that published it. Removes the run from pages and stats; the stored zip is deleted.
- Unknown keys are registered on first valid upload (no separate step). Same bundle (by its SHA-256) twice → `409` with
  the existing run's URL.
- Rate limit (Workers rate-limiting binding) keyed on the key id only: 30 uploads/hour. **No IP address is used, logged
  or stored** anywhere in the site (user: "I'd rather be able to say honestly this is no kind of spyware"); Worker
  logs must not record request headers. Minimum app version accepted: the first version that signs (config value).

### C. Checks on upload (all must pass; failures name the problem)
1. Signature valid; timestamp fresh; part hashes match; size ≤ 25 MB; `schema` 1.
2. Required: `run.json`, `samples.csv`, `summary.json`, all four `graphics` fields, a game title or exe, `fpsSource`
   ≠ `none`, ≥ 60 steady seconds with FPS.
3. Recompute from `samples.csv` over `[steadyStartS, steadyEndS]`: median of `fps`; mean of `smc_PSTR_w`; FPS/W.
   Must match `summary.json` within 0.5 fps and 2 % (FPS/W). The site ports `RunSummary`'s row selection exactly (`Sources/MPTCore/Bench/RunSummary.swift`:
   the steady window when `steadyStartS > 0`, else its fallback — most common `fps_app`, 10 s trim, rows above 2× the
   median dropped) and its power fallback (`smc_PSTR_w`, else `gpu_w` → `powerSource: gpuOnly`). FPS/W is checked for
   both sources; only `system` feeds aggregates. Shared golden fixture runs (from `Tests/`) prove both sides agree.
4. Sanity: fps 1–1000; system power 2–400 W; elapsed time increases; sample rows ≈ 1 Hz (gaps ≤ 5 s).
6. **Video link** (user: "restrict it to YouTube videos initially"): accepted forms `youtube.com/watch?v=ID`,
   `youtu.be/ID`, `youtube.com/shorts/ID`, `youtube.com/live/ID` (`www.`/`m.` allowed, https only); the 11-character ID
   (`[A-Za-z0-9_-]{11}`) is extracted and **only the ID is stored** — the user's URL is never echoed. The site asks
   YouTube's oEmbed endpoint whether the video exists and is public; if not, the upload is still accepted without the
   link and the reply says why. The video's title and channel name from oEmbed are stored for display.
5. Privacy re-scrub on the server (home paths, `/Users/<name>`, host-name patterns) of every text field; notes only if
   `includesNotes`.

### D. Storage
- **R2** bucket `metal-pt-runs`: the uploaded zip at `runs/<id>.zip` (kept for download and re-processing).
- **D1** database `metal-pt`:
  - `macs(key_id PK, public_key, first_seen, banned)` — a key, not a person.
  - `games(id PK, slug UNIQUE, title, steam_id UNIQUE NULL, created)`; `game_aliases(alias_norm PK, game_id)` — match:
    Steam ID first, else normalised title (lowercase, punctuation/® ™ removed, spaces collapsed) via aliases, else a
    new game. Admin merges games (aliases move, runs repoint).
  - `runs(id PK (short random, URL-safe), game_id, key_id, published, recorded, app_version, chip, gpu_cores,
    memory_gb, model_id, os_version, setup_key, setup_label, runtime, runtime_version, graphics_layers,
    recorded_app, preset, width, height, upscaler, upscaler_mode, frame_gen, median_fps, p1_low_fps, fps_per_watt,
    mean_system_w, power_source, on_ac, power_mode, limiter_primary, limiter_verdict, steady_s, notes, settings_text,
    label, video_id, video_title, video_channel, hidden, outlier)` plus per-run downsampled series for the chart (`fps_series` — ≤ 300 points, JSON).
  - `groups(group_key PK, game_id, mac_key, setup_key, preset, width, height, upscaler, upscaler_mode, frame_gen,
    runs, macs, typical_fps, p25_fps, p75_fps, typical_fpw, outliers, updated)` — cached statistics (§E).
  - `reports(id, run_id, reason, created, resolved)`.
- **Mac key** (`mac_key`) = chip + GPU cores, e.g. `m4-max-40`. RAM ignored for grouping (shown on runs).
- **Setup key** = `native` | runtime + major version + main graphics layer (`crossover-25-d3dmetal`), plus
  `-via-<recorded app slug>` only for **native** runs whose recorded app differs from the game title (emulators,
  launchers); Wine runs never get it (their exe is the game). Graphics layers: all detected layers, sorted, joined.
  Label e.g. "CrossOver 25 · D3DMetal", "Native · via ARMSX2". Full versions show on run pages.
- **Unknown bucket**: null GPU cores, null runtime or `Wine (unknown)` → `mac_key`/`setup_key` `unknown`; such runs
  are published and visible but never counted in `groups`.

### E. Statistics (site-side)
- **Group** = game × Mac key × setup key × preset × resolution × upscaler (+mode) × frame generation.
- Per run value: `median_fps` (and `fps_per_watt` where `power_source = system`).
- **One Mac counts once**: each run is weighted 1 / (runs from its key in the group), so a key's runs together weigh 1.
  Typical = weighted median; range = weighted 25th–75th percentiles.
- **Outliers**: with ≥ 5 runs, runs outside [Q1 − 1.5·IQR, Q3 + 1.5·IQR] (weighted quartiles of fps) are marked
  `outlier`, excluded from typical/range, shown behind "Show them". With < 5 runs nothing is marked.
- **Minimum**: typical and range shown with ≥ 3 non-outlier runs from ≥ 2 keys; otherwise "Not enough runs yet (n)".
- **Counted runs** exclude: on battery (`on_ac` false), Low Power mode, outliers, hidden, unknown bucket. Excluded runs
  stay visible on their run pages and in "Show them".
- **Frame caps**: runs whose limiter primary is `frameCap` are left out of typical/range when the group also has
  uncapped counted runs; when ≥ 75 % of counted runs are capped, the row shows "Capped at N" (N = median cap).
- "One Mac counts once" is the main defence against one person moving a figure; a person who resets their key can
  look like several Macs — accepted for v1 (§H, §6a).
- Recomputed for the affected group on every publish, delete, hide or merge (one SQL read of the group's runs; small).
- FPS/W aggregates use only `power_source = system` runs; otherwise "—".

### F. Pages (server-rendered, mockups linked above)
- `/` — search, most-tested games, recently published runs, counts (runs, games, Macs).
- `/game/:slug` — settings pickers (default: the most-run combination), "How it runs" table (Mac, setup, typical,
  range bar, FPS/W, runs), outlier note, recent runs. Query string carries the pickers (shareable).
- `/run/:id` — header, settings chips, "Published from Metal-PT", tiles (median FPS, FPS/W, frame time / 1 % low, what
  held it back), FPS chart (SVG from `fps_series`, warm-up shaded), power/heat, notes, Copy link, Compare with…,
  Download (.mptrun.zip from R2), Report a problem.
  Video: when present, a card with YouTube's thumbnail (`i.ytimg.com`), the video title and channel, linking to
  `https://www.youtube.com/watch?v=ID` (`rel="nofollow ugc noopener"`, new tab). No embedded player by default, so no
  YouTube cookies load on the page; a "Play here" button may swap in a `youtube-nocookie.com` player on click. Open Graph tags: "Cyberpunk 2077 · M4 Max · 49 fps · 0.39 FPS/W".
- `/compare?runs=a,b,c` — first id is the baseline; verdict sentence (same wording as the app's `CompareReport`:
  "N % more/fewer frames per watt than the baseline"), bars, side-by-side with differing rows highlighted; a warning
  line when Macs differ ("FPS/W not comparable across Macs"). "Add a run" = search within the same game.
- `/mac/:mackey` — chip chips, games on that Mac at each game's most-run settings, sortable (runs, fps, FPS/W, name).
- `/setup/:setupkey` — the same table by setup (e.g. everything on CrossOver 25).
- `/search?q=` — games by title/alias.
- Cache: HTML responses cached at the edge for 60 s; publish/delete purges that game's, run's, Mac's and setup's URLs.

### G. Aggregates and the later metrics page
All needed figures are SQL over `runs`/`groups` with indexes on `(game_id)`, `(mac_key)`, `(setup_key)`,
`(published)`: runs per game, per Mac, per setup; most popular Macs/games; average typical fps per game per Mac;
publishes per week. Ideas for the metrics page (later, user to choose): setup progress over time (e.g. CrossOver
versions vs fps for one game), FPS/W leaders per Mac, newest Macs, most-improved games. Nothing is pre-aggregated
beyond `groups` until a page needs it.

### H. Admin and moderation
- `/admin` behind Cloudflare Access (the user's account only): reports queue, hide/unhide a run, remove a run's video link, ban a key (its runs
  hidden), merge/rename games, edit aliases.
- "Report a problem" form on each run: reason (wrong game, wrong settings, impossible numbers, bad video link, other) + text;
  Turnstile on that form.

### I. Privacy
A plain-language page `/privacy` ("What Metal-PT sends") states all of this. Public: Mac model/chip/GPU cores/RAM, macOS version, setup, settings, per-second numbers, label, settings text,
notes (only if ticked). Never public: key id (internal only), anything the app's scrub removes. Never stored: IP addresses, user agents,
cookies; no analytics or tracking scripts on any page.
The run page shows no Mac identity beyond the model.

### J. Code and environments
- Site in this repo under `web/`, TypeScript, one Worker (Hono with JSX for pages), `cloudflare.config.ts` via `cf`.
- Staging Worker on `*.workers.dev` with its own D1/R2 from day one, set up with `cf`; production on `metal-pt.com`
  (Worker custom domain) deployed only when the user says so.
- **Workers Free plan to start** (user: "try the free to start just for testing then pay if this becomes popular").
  Free gives 10 ms CPU per request — queue consumers too, so a queue would not help. Hence §B's upload never unzips,
  and the check parses only the `samples.csv` columns it needs (`elapsed_s`, `fps`, `fps_app`, `smc_PSTR_w`, `gpu_w`,
  `on_ac`) in one pass. A test publishes a 60-minute fixture run and records its CPU time; pages read precomputed
  rows (`groups`, `fps_series`), never CSVs. Moving to Paid ($5/month) is a plan change only, no code change.
  Free limits to watch (D1 100k writes/day, R2 10 GB): ample for testing.
- Tests: Vitest in the Workers runtime; golden fixtures shared with the Swift tests for §C.3.

## 5. Order of work
1. App: `graphics` fields, Steam ID, `summary.json`, signing key (no network yet).
2. Site: API + checks + storage + stats on staging, tested against app-produced fixtures.
3. Site pages.
4. App: Submit/Delete wired to the site; published state.
5. Production deploy on metal-pt.com; first real runs by the user.

## 6. Calls made while writing this up (designer's — open to correction)
Upload page dropped (app-only publishing); signed DELETE as "remove my run"; one Mac weighted once per group;
"via" only for native runs; battery/Low Power, capped-in-mixed-groups and unknown-bucket runs not counted;
outliers by 1.5·IQR only at ≥ 5 runs; minimum 3 runs from 2 Macs; RAM not in the Mac grouping; setup grouped by
runtime major version + graphics layer; Steam ID as `steam:<id>`; no Steam name lookup; Hono + JSX; 60 s edge cache;
staging on workers.dev; rate limit 30/h per key, nothing per IP; report form behind Turnstile; Access-protected admin.

## 6a. Trust, now and later
v1 (agreed: no IP addresses — "a simple VPN or secure router" makes them unreliable, and storing them feels like
spyware): signed runs, one Mac counts once per group, server re-check of headline numbers, outlier rule, reports and
admin hide/ban, honest badge wording. Creators doing many runs at different settings are unaffected: each settings
combination is its own group. Later: App Attest (needs a paid Apple Developer ID, which notarised releases want anyway);
optional verified-creator link (a creator links their key to a public profile; badge on their runs).

## 7. Left to the builder
Exact SQL schema/indexes and migrations; slug rules; HTML/CSS details within the mockups' look; chart drawing; error
copy beyond the named cases; the downsampling method for `fps_series`; Access/Turnstile setup steps.
