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
        #expect(throws: PublishLimits.Refusal.self) {
            _ = try PublishPayload.make(try makeBundle(), includeNotes: false, hosts: [], limit: 10)
        }
    }

    // MARK: - PublishLimits (the site's web/src/config.ts numbers)

    @Test func limitsMatchTheSite() {
        #expect(PublishLimits.maxSteadySeconds == 5400)
        #expect(PublishLimits.maxSamplesBytes == 2 * 1024 * 1024)
        #expect(PublishLimits.maxUploadBytes == 25 * 1024 * 1024)
    }

    @Test func refusalOrderAndEdges() {
        #expect(PublishLimits.refusal(steadySeconds: 5400, samplesBytes: 2 * 1024 * 1024) == nil)
        #expect(PublishLimits.refusal(steadySeconds: 5401, samplesBytes: 10) == .tooLong(seconds: 5401))
        #expect(PublishLimits.refusal(steadySeconds: 60, samplesBytes: 2 * 1024 * 1024 + 1)
                == .samplesTooLarge(bytes: 2 * 1024 * 1024 + 1))
        #expect(PublishLimits.refusal(steadySeconds: 60, samplesBytes: 10, zipBytes: 25 * 1024 * 1024 + 1)
                == .zipTooLarge(bytes: 25 * 1024 * 1024 + 1))
        #expect(PublishLimits.refusal(steadySeconds: 60, samplesBytes: 10, zipBytes: 1,
                                      uploadBytes: 25 * 1024 * 1024 + 1) == .uploadTooLarge(bytes: 25 * 1024 * 1024 + 1))
        #expect(PublishLimits.Refusal.tooLong(seconds: 5820).localizedDescription
                == "Runs longer than 90 minutes can't be published yet — record a shorter run. "
                   + "This one's steady part is 97 minutes.")
    }

    /// A run with `seconds` 1 Hz rows with FPS (no warm-up mark: trimmed 10 s after the first FPS row).
    private func longBundle(seconds: Int, step: Double = 1, wide: Int = 0) throws -> RunBundle {
        let dir = root.appendingPathComponent("runs/\(UUID().uuidString).mptrun")
        let info = RunInfo(appVersion: "0.2.0",
                           machine: .init(modelID: "Mac16,5", chip: "Apple M4 Max", gpuCores: 40, memoryGB: 48,
                                          osVersion: "26.1", osBuild: "25B78"),
                           game: .init(exe: "hzd.exe"), start: Self.start, fpsSource: "log")
        let w = try RunBundleWriter(directory: dir, info: info)
        let pad = String(repeating: "x", count: wide)
        for i in 1...seconds {
            var row = ["elapsed_s": String(format: "%.1f", Double(i) * step), "fps": "60.0", "fps_app": "hzd.exe"]
            if wide > 0 { row["thermal_state"] = pad }
            try w.append(sample: row)
        }
        try w.finish { $0.end = $0.start.addingTimeInterval(Double(seconds) * step) }
        return try RunBundle.load(dir)
    }

    @Test func steadyOver90MinutesIsRefusedBeforeSending() throws {
        let long = try longBundle(seconds: 5420)   // steady from 11 s: 5410 s
        #expect(PublishLimits.steadySeconds(long, summary: RunSummary(long)) > 5400)
        #expect(throws: PublishLimits.Refusal.self) { _ = try PublishPayload.make(long, includeNotes: false, hosts: []) }
        let preview = RunExport.preview(long, includeNotes: false)
        #expect(preview.publishRefusal?.hasPrefix("Runs longer than 90 minutes") == true)

        let ok = try longBundle(seconds: 5400)   // 5390 s
        #expect(RunExport.preview(ok, includeNotes: false).publishRefusal == nil)
        _ = try PublishPayload.make(ok, includeNotes: false, hosts: [])
    }

    @Test func steadySpanCountsGaps() throws {
        // 3000 rows, one every 2 s: 2,990 s with FPS but a ~5,980 s span.
        let b = try longBundle(seconds: 3000, step: 2)
        #expect(PublishLimits.steadySeconds(b, summary: RunSummary(b)) > 5900)
        #expect(throws: PublishLimits.Refusal.self) { _ = try PublishPayload.make(b, includeNotes: false, hosts: []) }
    }

    @Test func samplesOverTheSiteCapAreRefused() throws {
        let b = try longBundle(seconds: 600, wide: 4000)   // ~2.4 MB of samples.csv
        let preview = RunExport.preview(b, includeNotes: false)
        #expect(preview.publishRefusal?.contains("samples are too large") == true)
        #expect(throws: PublishLimits.Refusal.self) { _ = try PublishPayload.make(b, includeNotes: false, hosts: []) }
    }

    @Test func uploadBytesCountsEveryPartAndTheFraming() throws {
        let p = try PublishPayload.make(try makeBundle(), includeNotes: false, hosts: [])
        #expect(p.uploadBytes == p.bundleZip.count + p.runJSON.count + p.samplesCSV.count + p.summaryJSON.count
                + PublishLimits.multipartOverhead)
    }

    // MARK: - publisherVersion

    @Test func summaryCarriesThePublishingAppsVersion() throws {
        let p = try PublishPayload.make(try makeBundle(), includeNotes: false, appVersion: "9.9", hosts: [])
        let json = try JSONSerialization.jsonObject(with: p.summaryJSON) as! [String: Any]
        #expect(json["publisherVersion"] as? String == "9.9")
        #expect(json["summaryVersion"] as? Int == 1)
        let none = String(decoding: try SiteSummary(bundle: try makeBundle(), publisherVersion: nil).encoded(), as: UTF8.self)
        #expect(!none.contains("publisherVersion"))
        #expect(SiteSummary(bundle: try makeBundle()).publisherVersion == MetalPTVersion.current)
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
