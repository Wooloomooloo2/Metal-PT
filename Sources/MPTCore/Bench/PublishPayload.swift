import CryptoKit
import Foundation

/// `summary.json` (spec §4.A): the headline numbers the website re-checks, from `RunSummary` and `LimiterAnalysis`.
/// Encoded with sorted keys, no pretty printing; absent numbers are written as `null`.
public struct SiteSummary: Codable, Equatable, Sendable {
    public struct Limit: Codable, Equatable, Sendable {
        public var primary: String?
        public var verdict: String

        public init(primary: String?, verdict: String) {
            self.primary = primary
            self.verdict = verdict
        }

        enum CodingKeys: String, CodingKey { case primary, verdict }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(primary, forKey: .primary)
            try c.encode(verdict, forKey: .verdict)
        }
    }

    public var summaryVersion = 1
    public var medianFPS: Double?
    public var p1LowFPS: Double?
    public var fpsPerWatt: Double?
    public var meanSystemW: Double?
    public var steadyStartS: Double?
    public var steadyEndS: Double?
    public var limiter: Limit?
    /// "system" (smc_PSTR_w), "gpuOnly" (gpu_w) or "none".
    public var powerSource: String
    /// The version of the app that made this file (publishing or exporting it), which may be newer than the app that
    /// recorded the run (run.json `appVersion`). The site checks its minimum app version on this when present.
    /// Optional in summary version 1: left out when nil.
    public var publisherVersion: String?

    public init(bundle: RunBundle, publisherVersion: String? = MetalPTVersion.current) {
        self.init(bundle: bundle, summary: RunSummary(bundle), publisherVersion: publisherVersion)
    }

    public init(bundle: RunBundle, summary s: RunSummary, publisherVersion: String? = MetalPTVersion.current) {
        self.publisherVersion = publisherVersion
        medianFPS = s.medianFPS
        p1LowFPS = s.low1
        fpsPerWatt = s.fpsPerWatt
        switch s.powerColumn {
        case "smc_PSTR_w": powerSource = "system"
        case "gpu_w": powerSource = "gpuOnly"
        default: powerSource = "none"
        }
        meanSystemW = powerSource == "system" ? s.stats["smc_PSTR_w"]?.mean : nil
        steadyStartS = bundle.info.steadyStartS
        steadyEndS = bundle.info.steadyEndS
        let l = LimiterAnalysis(bundle, summary: s)
        limiter = Limit(primary: l.primary?.rawValue, verdict: l.verdict)
    }

    enum CodingKeys: String, CodingKey {
        case summaryVersion, medianFPS, p1LowFPS, fpsPerWatt, meanSystemW, steadyStartS, steadyEndS, limiter, powerSource,
             publisherVersion
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(summaryVersion, forKey: .summaryVersion)
        try c.encode(medianFPS, forKey: .medianFPS)
        try c.encode(p1LowFPS, forKey: .p1LowFPS)
        try c.encode(fpsPerWatt, forKey: .fpsPerWatt)
        try c.encode(meanSystemW, forKey: .meanSystemW)
        try c.encode(steadyStartS, forKey: .steadyStartS)
        try c.encode(steadyEndS, forKey: .steadyEndS)
        try c.encode(limiter, forKey: .limiter)
        try c.encode(powerSource, forKey: .powerSource)
        try c.encodeIfPresent(publisherVersion, forKey: .publisherVersion)
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(self)
    }
}

/// What metal-pt.com accepts, checked before anything is sent (the Submit sheet, `PublishPayload.make`,
/// `mpt publish`). The same numbers are in the site's `web/src/config.ts` (`MAX_STEADY_SECONDS`,
/// `MAX_SAMPLES_BYTES`, `MAX_UPLOAD_BYTES`) and `web/src/api/publish.ts` (`PART_CAPS`): change both sides together.
public enum PublishLimits {
    /// Longest steady window: 90 minutes (the larger of the steady seconds with FPS and the steady rows' span).
    public static let maxSteadySeconds: Double = 90 * 60
    /// Largest samples.csv: 2 MiB (~230 bytes per 1 Hz row in real runs, so 90 minutes is ~1.4 MB).
    public static let maxSamplesBytes = 2 * 1024 * 1024
    /// Largest zip, and largest whole upload (the multipart request): 25 MiB.
    public static let maxUploadBytes = RunExport.maxBytes
    /// Bytes the multipart framing adds to the four parts (boundaries and part headers; ~600 in practice).
    public static let multipartOverhead = 1024

    public enum Refusal: Error, Equatable, LocalizedError, Sendable {
        case tooLong(seconds: Double)
        case samplesTooLarge(bytes: Int)
        case zipTooLarge(bytes: Int)
        case uploadTooLarge(bytes: Int)

        public var errorDescription: String? {
            switch self {
            case .tooLong(let seconds):
                "Runs longer than 90 minutes can't be published yet — record a shorter run. "
                    + "This one's steady part is \(Int((seconds / 60).rounded())) minutes."
            case .samplesTooLarge(let bytes):
                "This run's samples are too large to publish (\(RunExport.sizeText(bytes)); the limit is 2 MB). "
                    + "Record a shorter run."
            case .zipTooLarge(let bytes), .uploadTooLarge(let bytes):
                "This run is too large to publish (\(RunExport.sizeText(bytes)); the limit is 25 MB). "
                    + "Record a shorter run."
            }
        }
    }

    /// The steady window's length as the site measures it: the larger of the steady rows with an FPS value
    /// (1 Hz rows, so seconds) and the steady rows' elapsed span.
    public static func steadySeconds(_ bundle: RunBundle, summary: RunSummary) -> Double {
        let withFPS = Double(summary.stats["fps"]?.count ?? 0)
        let times = summary.steadySeconds.compactMap { bundle.rows[$0]["elapsed_s"].flatMap(Double.init) }
            .filter(\.isFinite)
        let span = (times.max() ?? 0) - (times.min() ?? 0)
        return max(withFPS, span)
    }

    /// The first limit the run breaks, or nil. `zipBytes` and `uploadBytes` are nil before the zip is made
    /// (the Submit sheet's preview).
    public static func refusal(steadySeconds: Double, samplesBytes: Int, zipBytes: Int? = nil,
                               uploadBytes: Int? = nil) -> Refusal? {
        if steadySeconds > maxSteadySeconds { return .tooLong(seconds: steadySeconds) }
        if samplesBytes > maxSamplesBytes { return .samplesTooLarge(bytes: samplesBytes) }
        if let z = zipBytes, z > maxUploadBytes { return .zipTooLarge(bytes: z) }
        if let u = uploadBytes, u > maxUploadBytes { return .uploadTooLarge(bytes: u) }
        return nil
    }
}

/// What the website receives (spec §4.B): the export zip, unopened, plus byte-identical copies of the zip's run.json,
/// samples.csv and summary.json (all four from one staging, `RunExport.stageFiles`).
public struct PublishPayload: Sendable {
    public var bundleZip: Data
    public var runJSON: Data
    public var samplesCSV: Data
    public var summaryJSON: Data

    /// Stages, zips and checks the run against `PublishLimits` (throws a `PublishLimits.Refusal`: too long,
    /// samples.csv too large, zip or whole upload over 25 MB). `appVersion` is the publishing app's version: the
    /// manifest's `app` and summary.json's `publisherVersion`. `limit` (tests) replaces the zip's limit.
    public static func make(_ bundle: RunBundle, includeNotes: Bool, appVersion: String = MetalPTVersion.current,
                            hosts: [String]? = nil, limit: Int = RunExport.maxBytes) throws -> PublishPayload {
        let fm = FileManager.default
        let summary = RunSummary(bundle)
        let steady = PublishLimits.steadySeconds(bundle, summary: summary)
        let staged = try RunExport.stageFiles(bundle, includeNotes: includeNotes, hosts: hosts,
                                              appVersion: appVersion, summary: summary)
        guard let run = staged.data("run.json"), let samples = staged.data("samples.csv"),
              let summaryJSON = staged.data("summary.json") else { throw RunExport.Error.missingSamples }
        if let r = PublishLimits.refusal(steadySeconds: steady, samplesBytes: samples.count) { throw r }
        let tmp = fm.temporaryDirectory.appendingPathComponent("mpt-payload-\(UUID().uuidString).zip")
        defer { try? fm.removeItem(at: tmp) }
        try RunExport.zip(staged, includeNotes: includeNotes, appVersion: appVersion, to: tmp)
        let zip = try Data(contentsOf: tmp)
        guard zip.count <= limit else { throw PublishLimits.Refusal.zipTooLarge(bytes: zip.count) }
        let payload = PublishPayload(bundleZip: zip, runJSON: run, samplesCSV: samples, summaryJSON: summaryJSON)
        if let r = PublishLimits.refusal(steadySeconds: steady, samplesBytes: samples.count, zipBytes: zip.count,
                                         uploadBytes: payload.uploadBytes) { throw r }
        return payload
    }

    /// The whole multipart request's size (the four parts plus `PublishLimits.multipartOverhead`).
    public var uploadBytes: Int {
        bundleZip.count + runJSON.count + samplesCSV.count + summaryJSON.count + PublishLimits.multipartOverhead
    }

    /// Lowercase hex SHA-256 of each part.
    public func hashes() -> (bundle: String, run: String, samples: String, summary: String) {
        func hex(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
        return (hex(bundleZip), hex(runJSON), hex(samplesCSV), hex(summaryJSON))
    }
}
