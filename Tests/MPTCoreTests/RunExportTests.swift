import CryptoKit
import Foundation
import Testing
@testable import MPTCore

@Suite struct RunExportTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("mptexport-\(UUID().uuidString)")

    /// A finished bundle with samples, frames, a summary.html and a stray dot-file (neither may be exported).
    private func makeBundle(notes: String = "Mountain path loop", frames: Bool = true) throws -> RunBundle {
        let dir = root.appendingPathComponent("runs/20261124-120000-hzd.mptrun")
        let info = RunInfo(appVersion: "0.2.0-dev",
                           machine: .init(modelID: "Mac16,5", chip: "Apple M4 Max", gpuCores: 40, memoryGB: 48,
                                          osVersion: "26.1", osBuild: "25B78"),
                           game: .init(exe: "hzd.exe"), stack: Stack(runtime: "Protium", translator: "FEX",
                                                                     graphics: ["DXMT"]),
                           user: .init(label: "Mountain path", gameSettings: "High, 1440p", notes: notes),
                           start: Date(timeIntervalSince1970: 1_800_000_000), fpsSource: "log")
        let w = try RunBundleWriter(directory: dir, info: info)
        for i in 1...5 { try w.append(sample: ["elapsed_s": "\(i)", "fps": "60.0"]) }
        if frames {
            try w.append(frames: (0..<7).map { _ in FrameTime(intervalMs: 16.7, presentDelayMs: 2) }, endingAtMs: 5000)
        }
        try w.finish { $0.end = $0.start.addingTimeInterval(5) }
        try SummaryReport.write(bundleAt: dir)
        try Data("x".utf8).write(to: dir.appendingPathComponent(".DS_Store"))
        return try RunBundle.load(dir)
    }

    private func unzip(_ zip: URL) throws -> URL {
        let out = root.appendingPathComponent("unzipped-\(UUID().uuidString)")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, out.path]
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        return out
    }

    private func listZip(_ zip: URL) throws -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        p.arguments = ["-1", zip.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    private struct Manifest: Decodable {
        struct File: Decodable { let path: String; let bytes: Int; let sha256: String }
        let format: String
        let schema: Int
        let files: [File]
        let app: String
        let includesNotes: Bool
    }

    private func runInfo(in folder: URL) throws -> RunInfo {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(RunInfo.self, from: Data(contentsOf: folder.appendingPathComponent("run.json")))
    }

    @Test func zipHasManifestAndNoSummary() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle()
        let zip = try RunExport.write(bundle, includeNotes: false, to: root.appendingPathComponent("exports"),
                                      appVersion: "9.9")
        let folder = try unzip(zip).appendingPathComponent("20261124-120000-hzd.mptrun")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(names == ["frames.csv", "manifest.json", "run.json", "samples.csv"])
        let m = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
        #expect(m.format == "metal-pt-run")
        #expect(m.schema == 1)
        #expect(m.app == "9.9")
        #expect(m.includesNotes == false)
        #expect(m.files.map(\.path) == ["frames.csv", "run.json", "samples.csv"])
        for f in m.files {
            let data = try Data(contentsOf: folder.appendingPathComponent(f.path))
            #expect(f.bytes == data.count)
            #expect(f.sha256 == SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        }
        // The CSVs go as recorded.
        #expect(try Data(contentsOf: folder.appendingPathComponent("samples.csv"))
                == Data(contentsOf: bundle.url.appendingPathComponent("samples.csv")))
    }

    @Test func zipHasNoAppleDoubleOrMacOSXEntries() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let zip = try RunExport.write(try makeBundle(), includeNotes: false, to: root.appendingPathComponent("exports"))
        let entries = try listZip(zip)
        #expect(!entries.isEmpty)
        #expect(entries.allSatisfy { $0.hasPrefix("20261124-120000-hzd.mptrun/") })
        #expect(!entries.contains { $0.contains("__MACOSX") || $0.split(separator: "/").contains { $0.hasPrefix(".") } })
    }

    @Test func withoutFramesExportsNoFramesFile() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(frames: false)
        let zip = try RunExport.write(bundle, includeNotes: false, to: root.appendingPathComponent("exports"))
        let folder = try unzip(zip).appendingPathComponent("20261124-120000-hzd.mptrun")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(names == ["manifest.json", "run.json", "samples.csv"])
        #expect(RunExport.preview(bundle, includeNotes: false).frameCount == nil)
    }

    @Test func notesExcludedByDefault() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle()
        let zip = try RunExport.write(bundle, includeNotes: false, to: root.appendingPathComponent("exports"))
        let folder = try unzip(zip).appendingPathComponent("20261124-120000-hzd.mptrun")
        let info = try runInfo(in: folder)
        #expect(info.user.notes == "")
        #expect(info.user.label == "Mountain path")
        #expect(info.user.gameSettings == "High, 1440p")
        let text = try String(contentsOf: folder.appendingPathComponent("run.json"), encoding: .utf8)
        #expect(!text.contains("Mountain path loop"))
        let preview = RunExport.preview(bundle, includeNotes: false)
        #expect(preview.notes == nil)
    }

    @Test func notesIncludedWhenOptedIn() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle()
        let zip = try RunExport.write(bundle, includeNotes: true, to: root.appendingPathComponent("exports"))
        let folder = try unzip(zip).appendingPathComponent("20261124-120000-hzd.mptrun")
        #expect(try runInfo(in: folder).user.notes == "Mountain path loop")
        let m = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
        #expect(m.includesNotes)
        let preview = RunExport.preview(bundle, includeNotes: true)
        #expect(preview.notes == "Mountain path loop")
        #expect(preview.bytes > RunExport.preview(bundle, includeNotes: false).bytes)
    }

    @Test func notesAreScrubbedAgain() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        // A run.json written by something other than Metal-PT (not scrubbed at write time).
        let bundle = try makeBundle()
        var info = bundle.info
        info.user.notes = "saved in /Users/somebody/Games"
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(info).write(to: bundle.url.appendingPathComponent("run.json"))
        let zip = try RunExport.write(try RunBundle.load(bundle.url), includeNotes: true,
                                      to: root.appendingPathComponent("exports"))
        let folder = try unzip(zip).appendingPathComponent("20261124-120000-hzd.mptrun")
        #expect(try runInfo(in: folder).user.notes == "saved in ~/Games")
    }

    @Test func refusesOver25MB() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(RunExport.maxBytes == 25 * 1024 * 1024)
        let bundle = try makeBundle()
        let exports = root.appendingPathComponent("exports")
        let bytes = RunExport.preview(bundle, includeNotes: false).bytes
        #expect(throws: RunExport.Error.tooLarge(bytes: bytes)) {
            try RunExport.write(bundle, includeNotes: false, to: exports, limit: bytes - 1)
        }
        // Nothing written.
        let written = (try? FileManager.default.contentsOfDirectory(atPath: exports.path)) ?? []
        #expect(written.isEmpty)
        let message = RunExport.Error.tooLarge(bytes: 30 * 1024 * 1024).localizedDescription
        #expect(message.contains("25 MB"))
    }

    @Test func fileNameEndsMptrunZip() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle()
        let exports = root.appendingPathComponent("exports")
        let a = try RunExport.write(bundle, includeNotes: false, to: exports)
        let b = try RunExport.write(bundle, includeNotes: false, to: exports)
        let c = try RunExport.write(bundle, includeNotes: false, to: exports)
        #expect(a.lastPathComponent == "20261124-120000-hzd.mptrun.zip")
        #expect(b.lastPathComponent == "20261124-120000-hzd-2.mptrun.zip")
        #expect(c.lastPathComponent == "20261124-120000-hzd-3.mptrun.zip")
    }

    @Test func previewDescribesTheRun() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let p = RunExport.preview(try makeBundle(), includeNotes: false)
        #expect(p.game == "hzd.exe")
        #expect(p.stackLine == "Protium · FEX · DXMT")
        #expect(p.mac == "Mac16,5 · Apple M4 Max 40-core GPU · 48 GB · macOS 26.1")
        #expect(p.settings == "High, 1440p")
        #expect(p.label == "Mountain path")
        #expect(p.sampleCount == 5)
        #expect(p.frameCount == 7)
        #expect(p.hasNotes)
        #expect(p.privacyLine == "No user name, home folder, computer name or serial number")
    }
}
