# Metal-PT website, part 1: what the app must carry — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give runs the fields, files and signature the website needs (spec §4.A), with no networking yet.

**Architecture:** New optional `run.json` fields (`graphics`, `user.videoURL`), Steam ID from the game's environment,
`summary.json` + a publish payload built from the same staged bytes as the export zip, and a Secure Enclave signing
key behind a protocol so tests use a software key. A `mpt payload` command writes golden fixtures for the site.

**Tech Stack:** Swift 6, CryptoKit (`SecureEnclave.P256.Signing`, `P256.Signing`), SwiftUI, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-25-metal-pt-website-design.md` (§4.A, §4.B, §4.C.3, §4.C.6).

## Global Constraints
- Schema stays 1; every new `run.json` key optional; old runs load unchanged; `swift test` green; warning-free builds.
- RunIndex `cacheVersion` bumped (4 → 5) when `RunEntry` gains fields.
- Privacy: new text fields go through the existing scrub (`Privacy.swift`); `videoURL` is stored only if it parses as
  YouTube (else rejected in the UI).
- Commits with explicit pathspecs only; never commit `docs/data/aldente-ids.txt`; never `git reset`.
- Don't launch the real app (the user's installed Metal-PT may be running); snapshots via `--render-snapshots`.
- Never touch `~/Documents/Metal-PT` (read-only allowed) or `~/Library` from tests; key files only under a temp dir in tests.

## Review Focus
1. A run without `graphics` (all old runs) loads, edits and exports exactly as before.
2. `YouTubeLink.videoID` rejects look-alikes: `youtube.com.evil.com/watch?v=…`, `http://` URLs, `youtube.com/redirect?…`,
   IDs of wrong length or with other characters.
3. The payload's `run.json`/`samples.csv`/`summary.json` bytes are byte-identical to the copies inside the zip.
4. A corrupt or missing key file → a new key is made (old published runs then can't be removed — stated in the UI
   string `SiteKey.lostKeyNote`), never a crash.
5. Steam ID: non-numeric or absent `SteamAppId` → `storeAppID` stays nil; a Wine game launched by Steam inherits it.

---

### Task 1: Graphics settings and video link fields
**Files:** `Sources/MPTCore/Bench/RunInfo.swift`, `Sources/MPTCore/Bench/YouTubeLink.swift` (new),
`Sources/MPTApp/RunIndex.swift`, `Sources/MetalPT/RunsStore.swift`, `Sources/MetalPT/EditNotesSheet.swift`,
`Sources/MetalPT/RunDetailView.swift`, `Sources/MPTCore/Bench/SummaryReport.swift` (settings row shows graphics),
`Sources/MetalPT/Snapshots.swift`, tests in `Tests/MPTCoreTests/RunInfoGraphicsTests.swift`,
`Tests/MPTCoreTests/YouTubeLinkTests.swift`, `Tests/MPTAppTests/RunIndexTests.swift`.
**Interfaces (produces):**
- `public struct RunInfo.Graphics: Codable, Sendable, Equatable { preset: Preset?; width: Int?; height: Int?;
  upscaler: Upscaler?; upscalerMode: UpscalerMode?; frameGeneration: Bool?; var isComplete: Bool }` with
  `enum Preset: String { low, medium, high, veryHigh, ultra, custom }`, `enum Upscaler: String { off, metalfx, fsr,
  xess, dlss, other }`, `enum UpscalerMode: String { quality, balanced, performance, ultraPerformance, native }`.
  `isComplete` = preset, width, height, upscaler, frameGeneration set, and upscalerMode set unless upscaler == .off.
  `RunInfo.graphics: Graphics?` (JSON key `graphics`); unknown enum strings decode as nil (never throw).
- `RunInfo.UserFields.videoURL: String?` (JSON `videoURL`, absent when nil).
- `public enum YouTubeLink { static func videoID(from: String) -> String?; static func canonicalURL(id:) -> String }`
  — https only; hosts `youtube.com`, `www.youtube.com`, `m.youtube.com`, `youtu.be`; paths `/watch?v=ID`, `/ID`
  (youtu.be), `/shorts/ID`, `/live/ID`; ID `^[A-Za-z0-9_-]{11}$`; canonical `https://www.youtube.com/watch?v=ID`.
- `RunIndex.update(dir:settings:notes:label:title:graphics:videoURL:)` — `graphics: RunInfo.Graphics??` and
  `videoURL: String??` (outer nil = leave); `RunEntry.graphics: RunInfo.Graphics?`; cacheVersion 5.
- `RunInfo.Graphics.commonResolutions: [(Int, Int)]` = 1280×800, 1920×1080, 1920×1200, 2560×1440, 2560×1600,
  3024×1964, 3456×2234.
- [ ] Tests (RED): Graphics round-trip; old JSON without `graphics` decodes nil; unknown preset string → nil;
  `isComplete` cases (off needs no mode); YouTube accepted forms (4) and Review Focus 2 rejections (≥ 8 cases);
  RunIndex update sets/clears graphics and videoURL and leaves `game.exe` untouched; cache version 5 rebuild.
- [ ] Implement. Edit sheet: a "Graphics" section (Preset, Resolution with the main display size first then
  `commonResolutions` then Custom W×H, Upscaler, Mode (hidden when Off), Frame generation toggle) and "YouTube video
  about this run" field with inline "Only YouTube links (youtube.com, youtu.be)" error when it doesn't parse.
  Run header/summary show "High · 2560×1440 · MetalFX Quality · FG off" when graphics exist.
- [ ] Snapshots of the edit sheet (light/dark); Read them. Commit `Record graphics settings and a YouTube link`.

### Task 2: Steam app ID
**Files:** `Sources/MPTCore/Bench/RunRecorder.swift` (where `info.game.exe` is set, ~line 346),
`Sources/MPTCore/Bench/StoreAppID.swift` (new), tests `Tests/MPTCoreTests/StoreAppIDTests.swift`.
**Interfaces:** `public enum StoreAppID { static func steam(from env: [String: String]) -> String? }` — `SteamAppId`,
else `SteamGameId`; value must be all digits, 1–10 chars, and not `0` → `"steam:<digits>"`. The recorder reads the
game pid's environment through an injectable `(Int32) -> [String: String]?` (default `ProcessNames.environment`)
once, when the game is identified, and sets `info.game.storeAppID` only if it was nil.
- [ ] Tests (RED): Review Focus 5; precedence AppId over GameId; recorder test with an injected env sets the field.
- [ ] Implement; commit `Record the Steam app ID`.

### Task 3: summary.json and the publish payload
**Files:** `Sources/MPTCore/Bench/RunExport.swift`, `Sources/MPTCore/Bench/PublishPayload.swift` (new),
`Sources/mpt/…` (the `mpt` CLI target: new subcommand `payload`), tests `Tests/MPTCoreTests/PublishPayloadTests.swift`.
**Interfaces (produces):**
- `public struct SiteSummary: Codable, Equatable { summaryVersion = 1; medianFPS, p1LowFPS, fpsPerWatt,
  meanSystemW: Double?; steadyStartS, steadyEndS: Double?; limiter: Limiter? { primary: String?; verdict: String };
  powerSource: String /* "system" | "gpuOnly" | "none" */; init(bundle: RunBundle) }` — from `RunSummary`
  (`medianFPS`, `low1`, `fpsPerWatt`, `powerColumn` "smc_PSTR_w" → system, "gpu_w" → gpuOnly, nil → none; meanSystemW =
  mean of the power column over steady rows) and `LimiterAnalysis` (`primary?.rawValue`, `verdict`). Encoded sorted
  keys, no pretty print.
- `public struct PublishPayload { bundleZip: Data; runJSON: Data; samplesCSV: Data; summaryJSON: Data;
  static func make(_ bundle: RunBundle, includeNotes: Bool, appVersion: String, hosts: [String]?) throws -> Self }`
  — staging shared with `RunExport.write` (refactor: one function stages files incl. `summary.json`, both use it);
  the zip now also contains `summary.json` (listed in `manifest.json`); same 25 MB limit over the zip.
- `func hashes() -> (bundle, run, samples, summary: String)` lowercase hex SHA-256.
- `mpt payload <run dir> --out <dir> [--notes]` writes `bundle.zip`, `run.json`, `samples.csv`, `summary.json`.
- [ ] Tests (RED): Review Focus 3 (unzip with `/usr/bin/ditto -x -k` into a temp dir and compare bytes);
  SiteSummary on a fixture with and without `smc_PSTR_w` (system / gpuOnly / none); notes excluded unless asked.
- [ ] Implement; commit `Build summary.json and the publish payload`.

### Task 4: Signing key and signed messages
**Files:** `Sources/MPTApp/SiteKey.swift` (new), `Sources/MPTCore/Bench/SiteSigning.swift` (new, pure),
tests `Tests/MPTCoreTests/SiteSigningTests.swift`, `Tests/MPTAppTests/SiteKeyTests.swift`.
**Interfaces (produces):**
- `public protocol RunSigner: Sendable { var publicKeyX963: Data { get }; func sign(_ message: Data) throws -> Data }`
  — returns raw 64-byte r‖s (`.rawRepresentation`), ECDSA-SHA256 over `message` (CryptoKit hashes it once).
- `public struct SoftwareSigner: RunSigner` (P256.Signing; for tests and fixtures; init from a 32-byte raw key).
- `public enum SiteSigning { static func publishMessage(bundle:run:samples:summary:timestamp:) -> Data;
  static func patchMessage(id:bodySHA256:timestamp:) -> Data; static func deleteMessage(id:timestamp:) -> Data;
  static func base64url(_: Data) -> String; static func keyID(publicKeyX963:) -> String /* first 16 hex of SHA-256 */;
  static func timestamp(_ date: Date) -> String /* ISO-8601 UTC, seconds */ }` — message texts exactly as spec §4.B
  (`"metal-pt-run\n" + h1 + "\n" + h2 + "\n" + h3 + "\n" + h4 + "\n" + ts`, etc.).
- `public final class SiteKey: RunSigner` in MPTApp: `static func loadOrCreate(in folder: URL, makeKey: () throws ->
  SecureEnclave.P256.Signing.PrivateKey = { try .init() }) throws -> SiteKey` storing `dataRepresentation` at
  `<folder>/site-key` (0600); Review Focus 4; `static let lostKeyNote = "This Mac's publishing key was replaced, so
  runs published before can no longer be removed from this Mac."`; `wasReplaced: Bool`. Where Secure Enclave is
  unavailable (`SecureEnclave.isAvailable == false`) it falls back to a software key stored the same way.
  App folder: `AppFolders` Application Support `Metal-PT`.
- [ ] Tests (RED): messages byte-exact against literal strings; base64url without padding; a SoftwareSigner signature
  verifies with `P256.Signing.PublicKey(x963Representation:)`; SiteKey with an injected software-backed maker in a
  temp dir: create, reload same public key, corrupt file → new key + `wasReplaced`.
- [ ] Implement; hardware check: a throwaway `swift` snippet or `mpt` debug path creates a real Secure Enclave key in a
  temp dir and signs once (report result in the task report). Commit `Sign runs with a per-Mac key`.

### Task 5: Golden fixtures for the website, and docs
**Files:** `Tests/Fixtures/site/` (new: 4 runs — system power with warm-up; no warm-up (fallback selection); GPU-only
power; capped 60 fps — each a small run dir), `mpt payload` gains `--test-key-hex HEX --timestamp TS` (debug use: writes `headers.json` `{ "key", "timestamp",
"signature" }` signed with `SoftwareSigner`), `scripts/make-site-fixtures.sh` (new: runs `mpt payload` on each and
writes `web/test/fixtures/<name>/{bundle.zip,run.json,samples.csv,summary.json,expected.json}`, where expected.json
holds `SiteSummary` plus signatures made with a fixed test key `SoftwareSigner(raw: 32×0x01)` and timestamp
`2026-11-25T12:00:00Z`), `docs/run-bundle-format.md` (graphics, videoURL, storeAppID `steam:<id>`, summary.json,
multipart publish contract summary pointing to the spec), CLAUDE.md state.
- [ ] Generate fixtures; commit them and the script with message `Add website golden fixtures and document new fields`.
