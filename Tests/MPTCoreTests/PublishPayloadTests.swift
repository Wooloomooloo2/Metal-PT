import Foundation
import Testing
@testable import MPTCore

@Suite struct PublishPayloadTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("mptpayload-\(UUID().uuidString)")
    private static let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeBundle(extra: [String: String] = [:], notes: String = "Secret route") throws -> RunBundle {
        let dir = root.appendingPathComponent("runs/\(UUID().uuidString).mptrun")
        let info = RunInfo(appVersion: "0.2.0",
                           machine: .init(modelID: "Mac16,5", chip: "Apple M4 Max", gpuCores: 40, memoryGB: 48,
                                          osVersion: "26.1", osBuild: "25B78"),
                           game: .init(exe: "hzd.exe"), stack: Stack(runtime: "Protium", translator: "FEX", graphics: ["DXMT"]),
                           user: .init(label: "Loop", gameSettings: "High", notes: notes),
                           start: Self.start, fpsSource: "log")
        let w = try RunBundleWriter(directory: dir, info: info)
        for i in 1...30 {
            var row = ["elapsed_s": "\(i)", "fps": "60.0"]
            for (k, v) in extra { row[k] = v }
            try w.append(sample: row)
        }
        try w.append(frames: (0..<30).map { _ in FrameTime(intervalMs: 16.7, presentDelayMs: 2) }, endingAtMs: 5000)
        try w.finish { $0.end = $0.start.addingTimeInterval(30) }
        return try RunBundle.load(dir)
    }

    private func unzip(_ zip: Data) throws -> URL {
        let file = root.appendingPathComponent("\(UUID().uuidString).zip")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try zip.write(to: file)
        let out = root.appendingPathComponent("unzipped-\(UUID().uuidString)")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", file.path, out.path]
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        let folders = try FileManager.default.contentsOfDirectory(atPath: out.path)
        return out.appendingPathComponent(folders[0])
    }

    @Test func partsAreByteIdenticalToTheZipsCopies() throws {
        let payload = try PublishPayload.make(try makeBundle(), includeNotes: false, appVersion: "9.9", hosts: [])
        let dir = try unzip(payload.bundleZip)
        #expect(try Data(contentsOf: dir.appendingPathComponent("run.json")) == payload.runJSON)
        #expect(try Data(contentsOf: dir.appendingPathComponent("samples.csv")) == payload.samplesCSV)
        #expect(try Data(contentsOf: dir.appendingPathComponent("summary.json")) == payload.summaryJSON)
        let manifest = try String(contentsOf: dir.appendingPathComponent("manifest.json"), encoding: .utf8)
        #expect(manifest.contains("summary.json"))
        let h = payload.hashes()
        #expect(h.bundle.count == 64 && h.run.count == 64 && h.samples.count == 64 && h.summary.count == 64)
        #expect(h.bundle == h.bundle.lowercased())
        #expect(h.run != h.summary)
    }

    @Test func notesAreExcludedUnlessAsked() throws {
        let b = try makeBundle()
        let without = try PublishPayload.make(b, includeNotes: false, hosts: [])
        let with = try PublishPayload.make(b, includeNotes: true, hosts: [])
        #expect(!String(decoding: without.runJSON, as: UTF8.self).contains("Secret route"))
        #expect(String(decoding: with.runJSON, as: UTF8.self).contains("Secret route"))
    }

    @Test func tooLargeIsRefused() throws {
        #expect(throws: RunExport.Error.self) {
            _ = try PublishPayload.make(try makeBundle(), includeNotes: false, hosts: [], limit: 10)
        }
    }

    @Test func systemPower() throws {
        let s = SiteSummary(bundle: try makeBundle(extra: ["smc_PSTR_w": "30", "gpu_w": "10"]))
        #expect(s.powerSource == "system")
        #expect(s.meanSystemW == 30)
        #expect(s.fpsPerWatt == 2)
        #expect(s.medianFPS == 60)
        #expect(s.summaryVersion == 1)
    }

    @Test func gpuOnlyPower() throws {
        let s = SiteSummary(bundle: try makeBundle(extra: ["gpu_w": "10"]))
        #expect(s.powerSource == "gpuOnly")
        #expect(s.meanSystemW == nil)
        #expect(s.fpsPerWatt == 6)
    }

    @Test func noPower() throws {
        let s = SiteSummary(bundle: try makeBundle())
        #expect(s.powerSource == "none")
        #expect(s.meanSystemW == nil && s.fpsPerWatt == nil)
        #expect(s.limiter?.verdict.isEmpty == false)
        let json = String(decoding: try s.encoded(), as: UTF8.self)
        #expect(json.contains("\"fpsPerWatt\":null"))
        #expect(json.contains("\"powerSource\":\"none\""))
        #expect(!json.contains("\n"))
        #expect(json.hasPrefix("{\"fpsPerWatt\""))   // sorted keys
    }

    /// The site refuses a bundle it already has (409, by SHA-256): the same run must zip to the same bytes each time.
    @Test func sameRunZipsToTheSameBytes() throws {
        let b = try makeBundle()
        let first = try PublishPayload.make(b, includeNotes: false, hosts: [])
        Thread.sleep(forTimeInterval: 1.1)   // a later second: file times must not leak into the zip
        let second = try PublishPayload.make(b, includeNotes: false, hosts: [])
        #expect(first.bundleZip == second.bundleZip)
        #expect(first.hashes().bundle == second.hashes().bundle)
    }
}
