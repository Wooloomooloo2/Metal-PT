import CryptoKit
import Foundation
import Testing
@testable import MPTCore

@Suite struct RunExportTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("mptexport-\(UUID().uuidString)")
    private static let start = Date(timeIntervalSince1970: 1_800_000_000)
    /// The canonical folder name without `.mptrun`: `20270115-080000-hzd-exe`.
    private let base = String(RunBundle.directoryName(start: start, game: "hzd.exe").dropLast(".mptrun".count))

    /// A finished bundle with samples, frames, a summary.html and a stray dot-file (neither may be exported).
    private func makeBundle(notes: String = "Mountain path loop", frames: Bool = true,
                            folder: String? = nil) throws -> RunBundle {
        let dir = root.appendingPathComponent("runs/" + (folder ?? "\(base).mptrun"))
        let info = RunInfo(appVersion: "0.1-old",
                           machine: .init(modelID: "Mac16,5", chip: "Apple M4 Max", gpuCores: 40, memoryGB: 48,
                                          osVersion: "26.1", osBuild: "25B78"),
                           game: .init(exe: "hzd.exe"), stack: Stack(runtime: "Protium", translator: "FEX",
                                                                     graphics: ["DXMT"]),
                           user: .init(label: "Mountain path", gameSettings: "High, 1440p", notes: notes),
                           start: Self.start, fpsSource: "log", warnings: ["thermal: serious"])
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

    @Test func zipHasManifestAndSummaryJSONButNoSummaryHTML() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle()
        let zip = try RunExport.write(bundle, includeNotes: false, to: root.appendingPathComponent("exports"),
                                      appVersion: "9.9")
        let folder = try unzip(zip).appendingPathComponent("\(base).mptrun")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(names == ["frames.csv", "manifest.json", "run.json", "samples.csv", "summary.json"])
        let m = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
        #expect(m.format == "metal-pt-run")
        #expect(m.schema == 1)
        #expect(m.app == "9.9")
        #expect(m.includesNotes == false)
        #expect(m.files.map(\.path) == ["frames.csv", "run.json", "samples.csv", "summary.json"])
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
        #expect(entries.allSatisfy { $0.hasPrefix("\(base).mptrun/") })
        #expect(!entries.contains { $0.contains("__MACOSX") || $0.split(separator: "/").contains { $0.hasPrefix(".") } })
    }

    @Test func withoutFramesExportsNoFramesFile() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(frames: false)
        let zip = try RunExport.write(bundle, includeNotes: false, to: root.appendingPathComponent("exports"))
        let folder = try unzip(zip).appendingPathComponent("\(base).mptrun")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(names == ["manifest.json", "run.json", "samples.csv", "summary.json"])
        #expect(RunExport.preview(bundle, includeNotes: false).frameCount == nil)
    }

    @Test func notesExcludedByDefault() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle()
        let zip = try RunExport.write(bundle, includeNotes: false, to: root.appendingPathComponent("exports"))
        let folder = try unzip(zip).appendingPathComponent("\(base).mptrun")
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
        let folder = try unzip(zip).appendingPathComponent("\(base).mptrun")
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
        let folder = try unzip(zip).appendingPathComponent("\(base).mptrun")
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
        #expect(a.lastPathComponent == "\(base).mptrun.zip")
        #expect(b.lastPathComponent == "\(base)-2.mptrun.zip")
        #expect(c.lastPathComponent == "\(base)-3.mptrun.zip")
    }

    @Test func exportScrubsTheTitleAndLeavesTheExeAsASeparateKey() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle()
        var info = bundle.info
        info.game.title = "Ico at /Users/somebody/Games"
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(info).write(to: bundle.url.appendingPathComponent("run.json"))
        let zip = try RunExport.write(try RunBundle.load(bundle.url), includeNotes: false,
                                      to: root.appendingPathComponent("exports"))
        let folder = try unzip(zip).appendingPathComponent("\(base).mptrun")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("run.json")))
        let game = try #require((json as? [String: Any])?["game"] as? [String: Any])
        #expect(game["title"] as? String == "Ico at ~/Games")
        #expect(game["exe"] as? String == "hzd.exe")
        let p = RunExport.preview(try RunBundle.load(bundle.url), includeNotes: false)
        #expect(p.game == "Ico at /Users/somebody/Games".replacingOccurrences(of: "/Users/somebody", with: "~"))
        #expect(p.recordedApp == "hzd.exe")
    }

    @Test func previewHasNoRecordedAppRowWithoutADifferingTitle() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(RunExport.preview(try makeBundle(), includeNotes: false).recordedApp == nil)
    }

    @Test func previewDescribesTheRun() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let p = RunExport.preview(try makeBundle(), includeNotes: false)
        #expect(p.game == "hzd.exe")
        #expect(p.stackLine == "Protium · FEX · DXMT")
        #expect(p.mac == "Mac16,5 · Apple M4 Max 40-core GPU · 48 GB · macOS 26.1 (25B78)")
        #expect(p.warnings == ["thermal: serious"])
        #expect(p.settings == "High, 1440p")
        #expect(p.label == "Mountain path")
        #expect(p.sampleCount == 5)
        #expect(p.frameCount == 7)
        #expect(p.hasNotes)
        #expect(p.privacyLine == "No user name, home folder, computer name or serial number")
    }

    // MARK: - Fix round 1

    private func replace(_ name: String, in bundle: RunBundle, with text: String) throws {
        try Data(text.utf8).write(to: bundle.url.appendingPathComponent(name))
    }

    @Test func samplesTextCellsAreScrubbedAgain() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle()
        // A samples.csv not written by Metal-PT's writer (not scrubbed at write time), with an unknown text column.
        try replace("samples.csv", in: bundle, with: "elapsed_s,fps,fps_app,extra\n"
                    + "1,60.0,/Users/somebody/x.exe,on Johns-Studio\n"
                    + "2,61.0,\"Johns-Studio, /Users/somebody/y\",\n")
        let zip = try RunExport.write(try RunBundle.load(bundle.url), includeNotes: false,
                                      to: root.appendingPathComponent("exports"), hosts: ["Johns-Studio"])
        let folder = try unzip(zip).appendingPathComponent("\(base).mptrun")
        let text = try String(contentsOf: folder.appendingPathComponent("samples.csv"), encoding: .utf8)
        #expect(!text.contains("somebody"))
        #expect(!text.contains("Johns-Studio"))
        #expect(text == "elapsed_s,fps,fps_app,extra\n1,60.0,~/x.exe,on <host>\n2,61.0,\"<host>, ~/y\",\n")
        let m = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
        #expect(m.files.first { $0.path == "samples.csv" }?.bytes == Data(text.utf8).count)
    }

    @Test func framesAreReEmittedNumbersOnly() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle()
        try replace("frames.csv", in: bundle, with: "t_ms,interval_ms,present_delay_ms,who\n"
                    + "16.70,16.70,2.00,somebody\n/Users/somebody,1,2\n33.40,16.70,2.00")
        let zip = try RunExport.write(try RunBundle.load(bundle.url), includeNotes: false,
                                      to: root.appendingPathComponent("exports"))
        let folder = try unzip(zip).appendingPathComponent("\(base).mptrun")
        let text = try String(contentsOf: folder.appendingPathComponent("frames.csv"), encoding: .utf8)
        #expect(text == "t_ms,interval_ms,present_delay_ms\n16.70,16.70,2.00\n33.40,16.70,2.00\n")
    }

    @Test func zipNameIsRebuiltFromTheRunNotTheFolder() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(folder: "John Smith's run.mptrun")
        let zip = try RunExport.write(bundle, includeNotes: false, to: root.appendingPathComponent("exports"))
        #expect(zip.lastPathComponent == "\(base).mptrun.zip")
        let entries = try listZip(zip)
        #expect(entries.allSatisfy { $0.hasPrefix("\(base).mptrun/") })
        #expect(!entries.contains { $0.contains("John") })
    }

    @Test func frameCountWithoutTrailingNewline() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle()
        try replace("frames.csv", in: bundle, with: "t_ms,interval_ms,present_delay_ms\n1,1,1\n2,1,1\n3,1,1")
        let lean = try RunBundle.load(bundle.url, frames: false)
        #expect(RunExport.previews(lean).withoutNotes.frameCount == 3)
        try replace("frames.csv", in: bundle, with: "t_ms,interval_ms,present_delay_ms\n1,1,1\n2,1,1\n")
        #expect(RunExport.previews(lean).withoutNotes.frameCount == 2)
    }

    @Test func previewsShareTheCountAndDifferOnlyInNotes() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let p = RunExport.previews(try makeBundle())
        #expect(p.withoutNotes.notes == nil)
        #expect(p.withNotes.notes == "Mountain path loop")
        #expect(p.withNotes.frameCount == p.withoutNotes.frameCount)
    }

    @Test func manifestAppDefaultsToThisVersion() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let zip = try RunExport.write(try makeBundle(), includeNotes: false, to: root.appendingPathComponent("exports"))
        let folder = try unzip(zip).appendingPathComponent("\(base).mptrun")
        let m = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
        #expect(m.app == MetalPTVersion.current)
    }

    @Test func nonUTF8SamplesGiveAClearError() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle()
        try Data([0x65, 0x6C, 0x61, 0xFF, 0xFE, 0x0A]).write(to: bundle.url.appendingPathComponent("samples.csv"))
        #expect(throws: RunExport.Error.unreadableSamples("not UTF-8 text")) {
            try RunExport.write(try RunBundle.load(bundle.url), includeNotes: false,
                                to: root.appendingPathComponent("exports"))
        }
        let e = RunExport.Error.unreadableSamples("not UTF-8 text")
        #expect(e.localizedDescription.contains("could not be read"))
        #expect(!e.localizedDescription.contains("no samples.csv"))
        try FileManager.default.removeItem(at: bundle.url.appendingPathComponent("samples.csv"))
        #expect(throws: RunExport.Error.missingSamples) {
            try RunExport.write(try RunBundle.load(bundle.url), includeNotes: false,
                                to: root.appendingPathComponent("exports"))
        }
    }

    @Test func zipFailedCarriesDittoMessage() {
        let e = RunExport.Error.zipFailed(status: 1, message: "ditto: No space left on device")
        #expect(e.localizedDescription.contains("No space left on device"))
    }

    // MARK: - ditto's environment (byte-identical zips in every time zone)

    @Test func dittoRunsWithTZUTCAndNothingElseFromTheParent() {
        #expect(RunExport.dittoEnvironment == ["TZ": "UTC", "PATH": "/usr/bin:/bin", "LANG": "C"])
    }

    /// ditto stores entry times as local (DOS) time: another TZ changes the bytes, so fixing TZ is what keeps a run's
    /// zip (and its SHA-256, the site's duplicate check) the same on every Mac.
    @Test func zipBytesDependOnTZOnlyThroughTheFixedEnvironment() throws {
        let staged = try RunExport.stageFiles(try makeBundle(), includeNotes: false, hosts: [])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func zip(_ env: [String: String]?) throws -> Data {
            let out = root.appendingPathComponent("\(UUID().uuidString).zip")
            if let env {
                try RunExport.zip(staged, includeNotes: false, appVersion: "9.9", to: out, environment: env)
            } else {
                try RunExport.zip(staged, includeNotes: false, appVersion: "9.9", to: out)
            }
            return try Data(contentsOf: out)
        }
        let fixed = try zip(nil)
        let utc = try zip(["TZ": "UTC", "PATH": "/usr/bin:/bin", "LANG": "C"])
        let kiritimati = try zip(["TZ": "Pacific/Kiritimati", "PATH": "/usr/bin:/bin", "LANG": "C"])
        #expect(fixed == utc)
        #expect(kiritimati != utc)
        // The first local header's DOS time and date: 00:00:00 on 2026-01-01.
        #expect(fixed[fixed.startIndex] == 0x50 && fixed[fixed.startIndex + 1] == 0x4B)
        let time = UInt16(fixed[fixed.startIndex + 10]) | UInt16(fixed[fixed.startIndex + 11]) << 8
        let date = UInt16(fixed[fixed.startIndex + 12]) | UInt16(fixed[fixed.startIndex + 13]) << 8
        #expect(time == 0)
        #expect(date == UInt16((2026 - 1980) << 9 | 1 << 5 | 1))
    }
}
