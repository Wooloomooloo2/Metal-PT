import Foundation

/// A frame with its time in ms since run start.
public struct TimedFrame: Equatable, Sendable {
    public let tMs: Double
    public let intervalMs: Double
    public let presentDelayMs: Double
    public init(tMs: Double, intervalMs: Double, presentDelayMs: Double) {
        self.tMs = tMs; self.intervalMs = intervalMs; self.presentDelayMs = presentDelayMs
    }
}

public enum RunBundleError: Error { case missingFile(String) }

private let framesHeader = ["t_ms", "interval_ms", "present_delay_ms"]

public final class RunBundleWriter: @unchecked Sendable {
    private let directory: URL
    private var info: RunInfo
    private var samples: FileHandle?
    private var frames: FileHandle?
    private var finished = false
    private let lock = NSLock()

    public init(directory: URL, info: RunInfo) throws {
        self.directory = directory
        self.info = info
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let samplesURL = directory.appendingPathComponent("samples.csv")
        try Data((CSV.line(SampleColumns.all) + "\n").utf8).write(to: samplesURL)
        samples = try FileHandle(forWritingTo: samplesURL)
        try samples?.seekToEnd()
        try writeInfo()
    }

    private func writeInfo() throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(Privacy.scrub(info)).write(
            to: directory.appendingPathComponent("run.json"), options: .atomic)
    }

    private static let stringColumns: Set<String> = ["fps_app", "thermal_state"]

    /// Writes one row; missing columns become empty cells; free-text cells are privacy-scrubbed.
    /// Written through immediately. Appends after `finish` are silently ignored (a signal handler may
    /// finish while a tick is in flight).
    public func append(sample row: [String: String]) throws {
        lock.lock(); defer { lock.unlock() }
        guard !finished, let h = samples else { return }
        let cells = SampleColumns.all.map { col -> String in
            let v = row[col] ?? ""
            return Self.stringColumns.contains(col) ? Privacy.scrub(v) : v
        }
        try h.write(contentsOf: Data((CSV.line(cells) + "\n").utf8))
    }

    /// `endingAtMs` is the arrival time (ms since run start) of the last frame; earlier frames are
    /// placed backwards by the cumulative intervals of the frames after them.
    public func append(frames batch: [FrameTime], endingAtMs: Double) throws {
        lock.lock(); defer { lock.unlock() }
        guard !finished, !batch.isEmpty else { return }
        if frames == nil {
            let url = directory.appendingPathComponent("frames.csv")
            try Data((CSV.line(framesHeader) + "\n").utf8).write(to: url)
            frames = try FileHandle(forWritingTo: url)
            try frames?.seekToEnd()
        }
        var times = [Double](repeating: 0, count: batch.count)
        var t = endingAtMs
        for i in stride(from: batch.count - 1, through: 0, by: -1) {
            times[i] = t
            t -= batch[i].intervalMs
        }
        var out = ""
        for (i, f) in batch.enumerated() {
            out += CSV.line([CSV.number(times[i], digits: 2), CSV.number(f.intervalMs, digits: 2),
                             CSV.number(f.presentDelayMs, digits: 2)]) + "\n"
        }
        try frames?.write(contentsOf: Data(out.utf8))
    }

    /// Idempotent: the second call does nothing. Always attempts to close both files and write run.json,
    /// then rethrows the first error.
    public func finish(updating: (inout RunInfo) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        updating(&info)
        var firstError: Error?
        do { try samples?.close() } catch { firstError = error }
        samples = nil
        do { try frames?.close() } catch { firstError = firstError ?? error }
        frames = nil
        do { try writeInfo() } catch { firstError = firstError ?? error }
        if let firstError { throw firstError }
    }
}

public struct RunBundle {
    public let url: URL
    public let info: RunInfo
    public let rows: [[String: String]]
    public let frames: [TimedFrame]?
    public let warnings: [String]

    /// `frames: false` skips frames.csv (it can be large): for callers that show medians but not the lows.
    public static func load(_ url: URL, frames loadFrames: Bool = true) throws -> RunBundle {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let info = try dec.decode(RunInfo.self, from: Data(contentsOf: url.appendingPathComponent("run.json")))
        var warnings = info.warnings
        if info.schema > RunInfo.currentSchema { warnings.append("newer bundle format (schema \(info.schema))") }

        let rows: [[String: String]]
        if let text = try? String(contentsOf: url.appendingPathComponent("samples.csv"), encoding: .utf8) {
            rows = CSV.parse(text)
        } else {
            rows = []
            warnings.append("samples.csv missing")
        }
        var frames: [TimedFrame]?
        if loadFrames, let text = try? String(contentsOf: url.appendingPathComponent("frames.csv"), encoding: .utf8) {
            frames = CSV.parse(text).compactMap { r in
                guard let t = r["t_ms"].flatMap(Double.init), let i = r["interval_ms"].flatMap(Double.init),
                      let d = r["present_delay_ms"].flatMap(Double.init) else { return nil }
                return TimedFrame(tMs: t, intervalMs: i, presentDelayMs: d)
            }
        }
        return RunBundle(url: url, info: info, rows: rows, frames: frames, warnings: warnings)
    }

    /// `yyyyMMdd-HHmmss-<slug>.mptrun`, UTC so the name does not depend on the machine.
    public static func directoryName(start: Date, game: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "\(f.string(from: start))-\(slug(game)).mptrun"
    }

    static func slug(_ text: String) -> String {
        var out = ""
        var pendingDash = false
        for s in text.lowercased().unicodeScalars {
            if (s >= "a" && s <= "z") || (s >= "0" && s <= "9") {
                if pendingDash && !out.isEmpty { out += "-" }
                pendingDash = false
                out.unicodeScalars.append(s)
            } else { pendingDash = true }
        }
        var cut = String(out.prefix(40))
        while cut.hasSuffix("-") { cut.removeLast() }
        return cut.isEmpty ? "game" : cut
    }

    /// Moves a finished bundle created under a placeholder name to the name for `game` (non-colliding, same
    /// parent). Returns the new location, or `directory` unchanged when the name would not change.
    public static func rename(_ directory: URL, start: Date, game: String) throws -> URL {
        guard directoryName(start: start, game: game) != directory.lastPathComponent else { return directory }
        let target = availableDirectory(in: directory.deletingLastPathComponent(), start: start, game: game)
        try FileManager.default.moveItem(at: directory, to: target)
        return target
    }

    /// A non-colliding bundle directory in `parent`: appends -2, -3, ... before `.mptrun` while the
    /// target already holds a run.json.
    public static func availableDirectory(in parent: URL, start: Date, game: String) -> URL {
        let name = directoryName(start: start, game: game)
        let base = String(name.dropLast(".mptrun".count))
        var url = parent.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: url.appendingPathComponent("run.json").path) {
            url = parent.appendingPathComponent("\(base)-\(n).mptrun")
            n += 1
        }
        return url
    }
}
