import Foundation

/// Streams Metal HUD log lines from the unified log (`/usr/bin/log stream`)
/// and delivers them as `HUDEvent`s on a background queue.
public final class MetalHUDLogStream: @unchecked Sendable {
    private let onEvent: @Sendable (HUDEvent) -> Void
    private let lock = NSLock()
    private var process: Process?
    private var buffer = Data()

    public init(onEvent: @escaping @Sendable (HUDEvent) -> Void) {
        self.onEvent = onEvent
    }

    deinit { stop() }

    /// Decode one ndjson line; nil for the header, junk or non-HUD messages.
    public static func decode(ndjsonLine: String) -> HUDEvent? {
        guard let data = ndjsonLine.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let pid = obj["processID"] as? Int,
              let path = obj["processImagePath"] as? String,
              let message = obj["eventMessage"] as? String,
              let stamp = obj["timestamp"] as? String,
              let line = MetalHUDLine.parse(message),
              let time = parseTimestamp(stamp) else { return nil }
        return HUDEvent(pid: Int32(truncatingIfNeeded: pid), imagePath: path, time: time, line: line)
    }

    private static func parseTimestamp(_ s: String) -> Double? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        return f.date(from: s)?.timeIntervalSince1970
    }

    public func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard process == nil else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        p.arguments = ["stream", "--style", "ndjson",
                       "--predicate", #"eventMessage BEGINSWITH "metal-HUD""#]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        buffer = Data()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; return }
            self?.consume(chunk)
        }
        try p.run()
        process = p
    }

    public func stop() {
        lock.lock()
        let p = process
        process = nil
        lock.unlock()
        guard let p else { return }
        (p.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if p.isRunning { p.terminate() }
        p.waitUntilExit()
    }

    /// True while the `log` child is alive. False before `start`, after `stop`, or if `log` exited on its own.
    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return process?.isRunning ?? false
    }

    /// Appends `chunk` to `buffer` and returns the complete lines (without `\n`); a trailing partial line stays
    /// in `buffer`.
    public static func splitLines(_ buffer: inout Data, appending chunk: Data) -> [Data] {
        buffer.append(chunk)
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer.subdata(in: buffer.startIndex..<nl))
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        return lines
    }

    private func consume(_ chunk: Data) {
        lock.lock()
        let lines = Self.splitLines(&buffer, appending: chunk)
        lock.unlock()
        for d in lines {
            if let s = String(data: d, encoding: .utf8), let e = Self.decode(ndjsonLine: s) {
                onEvent(e)
            }
        }
    }
}
