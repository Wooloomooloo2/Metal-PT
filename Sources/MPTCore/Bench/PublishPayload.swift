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

    public init(bundle: RunBundle) {
        let s = RunSummary(bundle)
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
        case summaryVersion, medianFPS, p1LowFPS, fpsPerWatt, meanSystemW, steadyStartS, steadyEndS, limiter, powerSource
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
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(self)
    }
}

/// What the website receives (spec §4.B): the export zip, unopened, plus byte-identical copies of the zip's run.json,
/// samples.csv and summary.json (all four from one staging, `RunExport.stageFiles`).
public struct PublishPayload: Sendable {
    public var bundleZip: Data
    public var runJSON: Data
    public var samplesCSV: Data
    public var summaryJSON: Data

    public static func make(_ bundle: RunBundle, includeNotes: Bool, appVersion: String = MetalPTVersion.current,
                            hosts: [String]? = nil, limit: Int = RunExport.maxBytes) throws -> PublishPayload {
        let fm = FileManager.default
        let staged = try RunExport.stageFiles(bundle, includeNotes: includeNotes, hosts: hosts)
        let tmp = fm.temporaryDirectory.appendingPathComponent("mpt-payload-\(UUID().uuidString).zip")
        defer { try? fm.removeItem(at: tmp) }
        try RunExport.zip(staged, includeNotes: includeNotes, appVersion: appVersion, to: tmp)
        let zip = try Data(contentsOf: tmp)
        guard zip.count <= limit else { throw RunExport.Error.tooLarge(bytes: zip.count) }
        guard let run = staged.data("run.json"), let samples = staged.data("samples.csv"),
              let summary = staged.data("summary.json") else { throw RunExport.Error.missingSamples }
        return PublishPayload(bundleZip: zip, runJSON: run, samplesCSV: samples, summaryJSON: summary)
    }

    /// Lowercase hex SHA-256 of each part.
    public func hashes() -> (bundle: String, run: String, samples: String, summary: String) {
        func hex(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
        return (hex(bundleZip), hex(runJSON), hex(samplesCSV), hex(summaryJSON))
    }
}
