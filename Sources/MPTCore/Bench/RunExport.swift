import CryptoKit
import Foundation

/// What the Submit sheet shows before anything is sent: the fields of the upload file a person can recognise, taken
/// from the exported (re-scrubbed) run.json and CSVs.
public struct ExportPreview: Equatable, Sendable {
    public var game: String
    /// The recorded app (`game.exe`), when the game has a title that differs from it; nil otherwise.
    public var recordedApp: String?
    /// "Protium 0.3.1 · FEX · DXMT"; nil when the stack is unknown.
    public var stackLine: String?
    /// "Mac16,5 · Apple M4 Max 40-core GPU · 48 GB · macOS 26.1 (25B78)"
    public var mac: String
    /// "High power mode · on AC · 1728×1117 @ 120 Hz · FPS per-second (system log)"
    public var conditions: String
    /// The game settings the user typed.
    public var settings: String
    public var label: String
    /// The notes that will be sent: nil unless included (and non-empty).
    public var notes: String?
    /// The run has notes (so the "Also send my notes" tick means something).
    public var hasNotes: Bool
    public var warnings: [String]
    public var sampleCount: Int
    /// samples.csv's column count.
    public var columnCount: Int
    /// Frame times sent; nil: no frames.csv.
    public var frameCount: Int?
    /// Total size of the files in the upload (run.json, samples.csv, frames.csv, summary.json; not the manifest), uncompressed.
    public var bytes: Int
    public var privacyLine: String
    /// Why metal-pt.com would refuse this run (too long, samples.csv too large; `PublishLimits`), else nil. The zip's
    /// own size is checked when publishing.
    public var publishRefusal: String? = nil
}

/// The upload file (spec §6, `docs/run-bundle-format.md` "Upload file"): `<run>.mptrun.zip` holding the folder
/// `<run>.mptrun/`, named from the run's start time and game (never the folder's own name), with run.json (notes
/// cleared unless included, privacy-scrubbed again), samples.csv (text cells scrubbed again), frames.csv when present
/// (re-written from its numbers), and manifest.json. Nothing else from the run folder (no summary.html, no dot-files).
public enum RunExport {
    public static let maxBytes = 25 * 1024 * 1024
    public static let format = "metal-pt-run"
    public static let manifestSchema = 1
    public static let privacyLine = "No user name, home folder, computer name or serial number"

    public enum Error: Swift.Error, Equatable, LocalizedError {
        case tooLarge(bytes: Int)
        case missingSamples
        /// samples.csv exists but is not UTF-8 text (or cannot be read).
        case unreadableSamples(String)
        case zipFailed(status: Int32, message: String)

        public var errorDescription: String? {
            switch self {
            case .tooLarge(let bytes):
                "This run is too large to submit (\(RunExport.sizeText(bytes)); the limit is 25 MB). "
                    + "Record a shorter run."
            case .missingSamples: "This run has no samples.csv, so there is nothing to send."
            case .unreadableSamples(let why): "This run's samples.csv could not be read (\(why)), so it cannot be sent."
            case .zipFailed(let status, let message):
                "Could not make the zip file (ditto exited with status \(status)"
                    + (message.isEmpty ? ")." : ": \(message)).")
            }
        }
    }

    // MARK: - Preview

    /// Both previews (notes left out, notes included); the CSVs are read once.
    public static func previews(_ bundle: RunBundle, hosts: [String]? = nil)
        -> (withoutNotes: ExportPreview, withNotes: ExportPreview) {
        let csvs = try? stageCSVs(bundle, hosts: hosts)
        let summary = RunSummary(bundle)
        return (makePreview(bundle, csvs: csvs, summary: summary, includeNotes: false, hosts: hosts),
                makePreview(bundle, csvs: csvs, summary: summary, includeNotes: true, hosts: hosts))
    }

    public static func preview(_ bundle: RunBundle, includeNotes: Bool) -> ExportPreview {
        makePreview(bundle, csvs: try? stageCSVs(bundle, hosts: nil), summary: RunSummary(bundle),
                    includeNotes: includeNotes, hosts: nil)
    }

    private static func makePreview(_ bundle: RunBundle, csvs: StagedCSVs?, summary: RunSummary, includeNotes: Bool,
                                    hosts: [String]?) -> ExportPreview {
        let info = exportInfo(bundle.info, includeNotes: true, hosts: hosts)   // what notes would be sent
        let notes = info.user.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let json = (try? runJSON(bundle.info, includeNotes: includeNotes, hosts: hosts))?.count ?? 0
        return ExportPreview(
            game: info.game.titleText ?? info.game.exe,
            recordedApp: info.game.titleText.flatMap { $0 != info.game.exe && !info.game.exe.isEmpty ? info.game.exe : nil },
            stackLine: SummaryReport.stackLine(info.stack),
            mac: macLine(info.machine),
            conditions: conditionsLine(info),
            settings: info.user.gameSettings,
            label: info.user.label,
            notes: includeNotes && !notes.isEmpty ? notes : nil,
            hasNotes: !notes.isEmpty,
            warnings: info.warnings,
            sampleCount: csvs?.sampleCount ?? 0,
            columnCount: csvs?.columnCount ?? 0,
            frameCount: csvs?.frameCount,
            bytes: json + ((try? SiteSummary(bundle: bundle, summary: summary).encoded())?.count ?? 0)
                + (csvs?.files.reduce(0) { $0 + $1.data.count } ?? 0),
            privacyLine: privacyLine,
            publishRefusal: PublishLimits.refusal(
                steadySeconds: PublishLimits.steadySeconds(bundle, summary: summary),
                samplesBytes: csvs?.files.first { $0.path == "samples.csv" }?.data.count ?? 0)?.localizedDescription)
    }

    static func macLine(_ m: RunInfo.Machine) -> String {
        var chip = m.chip
        if let g = m.gpuCores { chip += "\(chip.isEmpty ? "" : " ")\(g)-core GPU" }
        let os = m.osVersion.isEmpty ? "" : "macOS \(m.osVersion)" + (m.osBuild.isEmpty ? "" : " (\(m.osBuild))")
        return [m.modelID, chip, "\(m.memoryGB) GB", os].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func conditionsLine(_ info: RunInfo) -> String {
        var parts: [String] = []
        if let p = info.settings.powerMode { parts.append("\(p) power mode") }
        if let ac = info.settings.onACAtStart { parts.append(ac ? "on AC" : "on battery") }
        if let d = SummaryReport.displayText(info.settings) { parts.append(d) }
        parts.append("FPS \(SummaryReport.fpsSourceText(info.fpsSource))")
        return parts.joined(separator: " · ")
    }

    /// "312 KB", "1.4 MB" (binary units, as the 25 MB limit).
    public static func sizeText(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) bytes" }
        if bytes < 1024 * 1024 { return "\(Int((Double(bytes) / 1024).rounded())) KB" }
        return String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
    }

    // MARK: - Staging

    private static func exportInfo(_ info: RunInfo, includeNotes: Bool, hosts: [String]?) -> RunInfo {
        var r = info
        if !includeNotes { r.user.notes = "" }
        return Privacy.scrub(r, hosts: hosts)
    }

    /// run.json as exported (`encodedInfo` scrubs once more with this Mac's host names).
    private static func runJSON(_ info: RunInfo, includeNotes: Bool, hosts: [String]?) throws -> Data {
        try RunBundleWriter.encodedInfo(exportInfo(info, includeNotes: includeNotes, hosts: hosts))
    }

    private struct StagedCSVs {
        var files: [(path: String, data: Data)]
        var sampleCount: Int
        var columnCount: Int
        var frameCount: Int?
    }

    /// samples.csv with every text cell (the writer's string columns, and any other cell that is not a number)
    /// scrubbed again; frames.csv re-written from the rows whose three columns are numbers.
    private static func stageCSVs(_ bundle: RunBundle, hosts: [String]?) throws -> StagedCSVs {
        let samplesURL = bundle.url.appendingPathComponent("samples.csv")
        guard FileManager.default.fileExists(atPath: samplesURL.path) else { throw Error.missingSamples }
        let raw: Data
        do {
            raw = try Data(contentsOf: samplesURL)
        } catch {
            throw Error.unreadableSamples(error.localizedDescription)
        }
        guard let text = String(data: raw, encoding: .utf8) else { throw Error.unreadableSamples("not UTF-8 text") }
        let records = CSV.records(text)
        let header = records.first ?? []
        var memo: [String: String] = [:]
        func clean(_ cell: String, column: String?) -> String {
            if cell.isEmpty { return cell }
            if !(column.map(RunBundleWriter.stringColumns.contains) ?? false), Double(cell) != nil { return cell }
            if let done = memo[cell] { return done }
            let s = Privacy.scrub(cell, hosts: hosts)
            memo[cell] = s
            return s
        }
        var out = ""
        for (n, r) in records.enumerated() {
            let cells = r.enumerated().map { k, cell in
                clean(cell, column: n == 0 ? nil : (k < header.count ? header[k] : nil))
            }
            out += CSV.line(cells) + "\n"
        }
        var staged = StagedCSVs(files: [("samples.csv", Data(out.utf8))], sampleCount: max(0, records.count - 1),
                                columnCount: header.count, frameCount: nil)

        let framesURL = bundle.url.appendingPathComponent("frames.csv")
        if FileManager.default.fileExists(atPath: framesURL.path) {
            let (data, count) = try framesCSV(framesURL)
            staged.files.append(("frames.csv", data))
            staged.frameCount = count
        }
        staged.files.sort { $0.path < $1.path }
        return staged
    }

    /// frames.csv re-emitted from numbers only: the three known columns (mapped by header name), rows where any of
    /// them is missing or not a finite number dropped, unknown columns dropped. Read line by line.
    private static func framesCSV(_ url: URL) throws -> (Data, Int) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var out = Data((CSV.line(framesHeader) + "\n").utf8)
        var columns: [Int]?
        var count = 0
        var pending = Data()
        func line(_ bytes: Data) {
            var s = String(decoding: bytes, as: UTF8.self)
            if s.hasSuffix("\r") { s.removeLast() }
            guard !s.isEmpty else { return }
            let cells = s.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard let cols = columns else {
                columns = framesHeader.map { cells.firstIndex(of: $0) ?? -1 }
                return
            }
            var values: [Double] = []
            for c in cols {
                guard c >= 0, c < cells.count, let v = Double(cells[c]), v.isFinite else { return }
                values.append(v)
            }
            out.append(Data((values.map { CSV.number($0, digits: 2) }.joined(separator: ",") + "\n").utf8))
            count += 1
        }
        while let chunk = try handle.read(upToCount: 1 << 16), !chunk.isEmpty {
            pending.append(chunk)
            while let nl = pending.firstIndex(of: 0x0A) {
                line(pending[pending.startIndex..<nl])
                pending.removeSubrange(pending.startIndex...nl)
            }
        }
        if !pending.isEmpty { line(pending) }   // no trailing newline
        return (out, count)
    }

    /// `<yyyyMMdd-HHmmss>-<slug of the scrubbed exe>.mptrun` from the run itself: the folder's own name may have been
    /// changed by hand to anything.
    static func folderName(_ info: RunInfo, hosts: [String]?) -> String {
        RunBundle.directoryName(start: info.start, game: Privacy.scrub(info.game.exe, hosts: hosts))
    }

    // MARK: - Write

    /// Writes `<dir>/<run>.mptrun.zip` (`-2`, `-3`, … before `.mptrun.zip` when taken) and returns it. Refuses a run
    /// whose files total more than `limit` bytes (`Error.tooLarge`), before writing anything. `appVersion` is the
    /// manifest's `app` (the exporting Metal-PT). `hosts` replaces this Mac's host names (tests).
    @discardableResult
    public static func write(_ bundle: RunBundle, includeNotes: Bool, to dir: URL,
                             appVersion: String = MetalPTVersion.current, limit: Int = maxBytes,
                             hosts: [String]? = nil) throws -> URL {
        let fm = FileManager.default
        let staged = try stageFiles(bundle, includeNotes: includeNotes, hosts: hosts, appVersion: appVersion)
        let total = staged.files.reduce(0) { $0 + $1.data.count }
        guard total <= limit else { throw Error.tooLarge(bytes: total) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = availableZip(in: dir, folderName: staged.folderName)
        try zip(staged, includeNotes: includeNotes, appVersion: appVersion, to: out)
        return out
    }

    /// Every file of the upload except manifest.json (run.json, samples.csv, frames.csv, summary.json), sorted by path,
    /// plus the folder name. The one place the bytes are made: the zip and the publish payload both take them from here.
    struct StagedFiles {
        var files: [(path: String, data: Data)]
        var folderName: String

        func data(_ path: String) -> Data? { files.first { $0.path == path }?.data }
    }

    /// `appVersion`: the app making the file (summary.json's `publisherVersion`). `summary`: the run's
    /// `RunSummary` when the caller already has it.
    static func stageFiles(_ bundle: RunBundle, includeNotes: Bool, hosts: [String]?,
                           appVersion: String = MetalPTVersion.current, summary: RunSummary? = nil) throws -> StagedFiles {
        var files = try stageCSVs(bundle, hosts: hosts).files
        files.append(("run.json", try runJSON(bundle.info, includeNotes: includeNotes, hosts: hosts)))
        files.append(("summary.json", try SiteSummary(bundle: bundle, summary: summary ?? RunSummary(bundle),
                                                      publisherVersion: appVersion).encoded()))
        files.sort { $0.path < $1.path }
        return StagedFiles(files: files, folderName: folderName(bundle.info, hosts: hosts))
    }

    /// The modification time of every entry in an upload zip (2026-01-01 00:00 UTC).
    static let zipDate = Date(timeIntervalSince1970: 1_767_225_600)

    /// ditto's whole environment: zip entry times are stored as local (DOS) time, so the time zone is fixed to UTC for
    /// the same bytes on every Mac; nothing else from the parent's environment is passed.
    static let dittoEnvironment = ["TZ": "UTC", "PATH": "/usr/bin:/bin", "LANG": "C"]

    /// Writes the staged files and manifest.json into a temporary folder and zips it with ditto to `out`.
    static func zip(_ staged: StagedFiles, includeNotes: Bool, appVersion: String, to out: URL,
                    environment: [String: String] = dittoEnvironment) throws {
        let fm = FileManager.default
        let stagingRoot = fm.temporaryDirectory.appendingPathComponent("mpt-export-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: stagingRoot) }
        let staging = stagingRoot.appendingPathComponent(staged.folderName)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        var entries: [ManifestFile] = []
        for f in staged.files {
            try f.data.write(to: staging.appendingPathComponent(f.path))
            entries.append(ManifestFile(path: f.path, bytes: f.data.count,
                                        sha256: SHA256.hash(data: f.data).map { String(format: "%02x", $0) }.joined()))
        }
        let manifest = Manifest(format: format, schema: manifestSchema, files: entries, app: appVersion,
                                includesNotes: includeNotes)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(manifest).write(to: staging.appendingPathComponent("manifest.json"))
        // Fixed times: the same run zips to the same bytes (the website knows a run already published by the
        // zip's SHA-256), whenever it is exported.
        for path in staged.files.map(\.path) + ["manifest.json"] {
            try fm.setAttributes([.modificationDate: zipDate], ofItemAtPath: staging.appendingPathComponent(path).path)
        }
        try fm.setAttributes([.modificationDate: zipDate], ofItemAtPath: staging.path)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--norsrc", "--noextattr", "--noqtn", "--noacl", "--keepParent",
                       staging.path, out.path]
        p.environment = environment
        let err = Pipe()
        p.standardError = err
        try p.run()
        let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            try? fm.removeItem(at: out)
            throw Error.zipFailed(status: p.terminationStatus,
                                  message: message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private struct ManifestFile: Encodable {
        let path: String
        let bytes: Int
        let sha256: String
    }

    private struct Manifest: Encodable {
        let format: String
        let schema: Int
        let files: [ManifestFile]
        let app: String
        let includesNotes: Bool
    }

    private static func availableZip(in dir: URL, folderName: String) -> URL {
        let base = String(folderName.dropLast(".mptrun".count))
        var url = dir.appendingPathComponent("\(folderName).zip")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base)-\(n).mptrun.zip")
            n += 1
        }
        return url
    }
}
