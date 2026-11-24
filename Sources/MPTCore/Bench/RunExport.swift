import CryptoKit
import Foundation

/// What the Submit sheet shows before anything is sent: the fields of the upload file a person can recognise.
public struct ExportPreview: Equatable, Sendable {
    public var game: String
    /// "Protium 0.3.1 · FEX · DXMT"; nil when the stack is unknown.
    public var stackLine: String?
    /// "Mac16,5 · Apple M4 Max 40-core GPU · 48 GB · macOS 26.1"
    public var mac: String
    /// The game settings the user typed.
    public var settings: String
    public var label: String
    /// The notes that will be sent: nil unless included (and non-empty).
    public var notes: String?
    /// The run has notes (so the "Also send my notes" tick means something).
    public var hasNotes: Bool
    public var sampleCount: Int
    /// samples.csv's column count.
    public var columnCount: Int
    /// nil: no frames.csv.
    public var frameCount: Int?
    /// Total size of the files in the upload (run.json, samples.csv, frames.csv; not the manifest), uncompressed.
    public var bytes: Int
    public var privacyLine: String
}

/// The upload file (spec §6, `docs/run-bundle-format.md` "Upload file"): `<run>.mptrun.zip` holding the folder
/// `<run>.mptrun/` with run.json (notes cleared unless included, privacy-scrubbed again), samples.csv, frames.csv when
/// present, and manifest.json. Nothing else from the run folder (no summary.html, no dot-files).
public enum RunExport {
    public static let maxBytes = 25 * 1024 * 1024
    public static let format = "metal-pt-run"
    public static let manifestSchema = 1
    public static let privacyLine = "No user name, home folder, computer name or serial number"

    public enum Error: Swift.Error, Equatable, LocalizedError {
        case tooLarge(bytes: Int)
        case missingSamples
        case zipFailed(status: Int32)

        public var errorDescription: String? {
            switch self {
            case .tooLarge(let bytes):
                "This run is too large to submit (\(RunExport.sizeText(bytes)); the limit is 25 MB). "
                    + "Record a shorter run."
            case .missingSamples: "This run has no samples.csv, so there is nothing to send."
            case .zipFailed(let status): "Could not make the zip file (ditto exited with status \(status))."
            }
        }
    }

    // MARK: - Preview

    public static func preview(_ bundle: RunBundle, includeNotes: Bool) -> ExportPreview {
        let info = bundle.info
        let notes = Privacy.scrub(info.user.notes).trimmingCharacters(in: .whitespacesAndNewlines)
        let frameCount = bundle.frames?.count
            ?? (FileManager.default.fileExists(atPath: bundle.url.appendingPathComponent("frames.csv").path)
                ? countLines(bundle.url.appendingPathComponent("frames.csv")) : nil)
        let bytes = (try? plannedFiles(bundle, includeNotes: includeNotes))?.reduce(0) { $0 + $1.bytes } ?? 0
        return ExportPreview(
            game: info.game.title.flatMap { $0.isEmpty ? nil : $0 } ?? info.game.exe,
            stackLine: SummaryReport.stackLine(info.stack),
            mac: macLine(info.machine),
            settings: info.user.gameSettings,
            label: info.user.label,
            notes: includeNotes && !notes.isEmpty ? notes : nil,
            hasNotes: !notes.isEmpty,
            sampleCount: bundle.rows.count,
            columnCount: SampleColumns.all.count,
            frameCount: frameCount,
            bytes: bytes,
            privacyLine: privacyLine)
    }

    static func macLine(_ m: RunInfo.Machine) -> String {
        var chip = m.chip
        if let g = m.gpuCores { chip += "\(chip.isEmpty ? "" : " ")\(g)-core GPU" }
        return [m.modelID, chip, "\(m.memoryGB) GB", m.osVersion.isEmpty ? "" : "macOS \(m.osVersion)"]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// "312 KB", "1.4 MB" (binary units, as the 25 MB limit).
    public static func sizeText(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) bytes" }
        if bytes < 1024 * 1024 { return "\(Int((Double(bytes) / 1024).rounded())) KB" }
        return String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
    }

    private static func countLines(_ url: URL) -> Int? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return max(0, data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 } - 1)   // minus the header
    }

    // MARK: - Write

    /// One file of the upload: run.json from memory, the CSVs copied from the run folder.
    private struct Planned {
        let path: String
        let data: Data?
        let source: URL?
        let bytes: Int
    }

    private static func exportInfo(_ info: RunInfo, includeNotes: Bool) -> RunInfo {
        var r = info
        if !includeNotes { r.user.notes = "" }
        return Privacy.scrub(r)
    }

    private static func plannedFiles(_ bundle: RunBundle, includeNotes: Bool) throws -> [Planned] {
        let fm = FileManager.default
        let json = try RunBundleWriter.encodedInfo(exportInfo(bundle.info, includeNotes: includeNotes))
        var files = [Planned(path: "run.json", data: json, source: nil, bytes: json.count)]
        for name in ["samples.csv", "frames.csv"] {
            let url = bundle.url.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path) else {
                if name == "samples.csv" { throw Error.missingSamples }
                continue
            }
            let size = (try fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            files.append(Planned(path: name, data: nil, source: url, bytes: size))
        }
        return files.sorted { $0.path < $1.path }
    }

    /// The bundle's folder name, ending `.mptrun`.
    private static func folderName(_ bundle: RunBundle) -> String {
        let name = bundle.url.standardizedFileURL.lastPathComponent
        return name.hasSuffix(".mptrun") ? name : name + ".mptrun"
    }

    /// Writes `<dir>/<run>.mptrun.zip` (`-2`, `-3`, … before `.mptrun.zip` when taken) and returns it. Refuses a run
    /// whose files total more than `limit` bytes (`Error.tooLarge`), before writing anything. `appVersion` is the
    /// manifest's `app` (the exporting app; defaults to the version that recorded the run).
    @discardableResult
    public static func write(_ bundle: RunBundle, includeNotes: Bool, to dir: URL, appVersion: String? = nil,
                             limit: Int = maxBytes) throws -> URL {
        let fm = FileManager.default
        let files = try plannedFiles(bundle, includeNotes: includeNotes)
        let total = files.reduce(0) { $0 + $1.bytes }
        guard total <= limit else { throw Error.tooLarge(bytes: total) }

        let stagingRoot = fm.temporaryDirectory.appendingPathComponent("mpt-export-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: stagingRoot) }
        let name = folderName(bundle)
        let staging = stagingRoot.appendingPathComponent(name)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        var entries: [ManifestFile] = []
        for f in files {
            let target = staging.appendingPathComponent(f.path)
            if let data = f.data {
                try data.write(to: target)
            } else if let source = f.source {
                try fm.copyItem(at: source, to: target)
            }
            // Hash what was staged (a CSV may have grown since it was measured; the manifest describes the zip).
            let data = try Data(contentsOf: target, options: .mappedIfSafe)
            entries.append(ManifestFile(path: f.path, bytes: data.count,
                                        sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
        }
        let manifest = Manifest(format: format, schema: manifestSchema, files: entries,
                                app: appVersion ?? bundle.info.appVersion, includesNotes: includeNotes)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(manifest).write(to: staging.appendingPathComponent("manifest.json"))

        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = availableZip(in: dir, folderName: name)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--norsrc", "--noextattr", "--noqtn", "--noacl", "--keepParent",
                       staging.path, out.path]
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            try? fm.removeItem(at: out)
            throw Error.zipFailed(status: p.terminationStatus)
        }
        return out
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
