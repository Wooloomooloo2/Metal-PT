import Foundation

/// One per-frame sample from a Metal HUD log line.
public struct FrameTime: Equatable, Sendable {
    public let intervalMs: Double
    public let presentDelayMs: Double

    public init(intervalMs: Double, presentDelayMs: Double) {
        self.intervalMs = intervalMs
        self.presentDelayMs = presentDelayMs
    }
}

/// A parsed `metal-HUD: <frames>,<a>,<b>,<interval>,<delay>,...` log line.
/// `frames` is the cumulative frame count. The per-frame list is empty when the
/// unified log redacted it (`<private>`).
public struct MetalHUDLine: Equatable, Sendable {
    public let frames: Int
    public let a: Double
    public let b: Double
    public let frameTimes: [FrameTime]

    public init(frames: Int, a: Double, b: Double, frameTimes: [FrameTime]) {
        self.frames = frames
        self.a = a
        self.b = b
        self.frameTimes = frameTimes
    }

    public static func parse(_ message: String) -> MetalHUDLine? {
        guard let marker = message.range(of: "metal-HUD: ") else { return nil }
        var rest = message[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        if rest.hasSuffix("<private>") { rest = String(rest.dropLast("<private>".count)) }
        let fields = rest.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard fields.count >= 3,
              let frames = Int(fields[0]),
              let a = Double(fields[1]),
              let b = Double(fields[2]) else { return nil }
        var times: [FrameTime] = []
        var i = 3
        while i + 1 < fields.count {
            guard let interval = Double(fields[i]), let delay = Double(fields[i + 1]) else { break }
            times.append(FrameTime(intervalMs: interval, presentDelayMs: delay))
            i += 2
        }
        return MetalHUDLine(frames: frames, a: a, b: b, frameTimes: times)
    }
}
