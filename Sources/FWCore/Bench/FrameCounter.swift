import Foundation

/// One parsed Metal HUD line with its source process and arrival time
/// (`time` is epoch seconds, `Date().timeIntervalSince1970`).
public struct HUDEvent: Sendable {
    public let pid: Int32
    public let imagePath: String
    public let time: Double
    public let line: MetalHUDLine

    public init(pid: Int32, imagePath: String, time: Double, line: MetalHUDLine) {
        self.pid = pid
        self.imagePath = imagePath
        self.time = time
        self.line = line
    }
}

/// Turns cumulative per-process frame counts into per-second FPS and picks the
/// process to follow (most frames gained so far).
public struct FrameCounter: Sendable {
    private struct State {
        var lastTime: Double
        var lastFrames: Int
        var lastFPS: Double?
        var total: Int
    }

    /// FPS older than this (seconds) is considered stale.
    private static let staleAfter = 2.5

    private var states: [Int32: State] = [:]
    public private(set) var followedPID: Int32?

    public init() {}

    public mutating func add(_ event: HUDEvent) {
        let frames = event.line.frames
        guard frames >= 0, event.time.isFinite else { return }
        let pid = event.pid
        guard var s = states[pid] else {
            states[pid] = State(lastTime: event.time, lastFrames: frames, lastFPS: nil, total: 0)
            updateFollowed(pid)
            return
        }
        guard event.time > s.lastTime else { return }
        if frames >= s.lastFrames {
            let delta = frames - s.lastFrames
            let fps = Double(delta) / (event.time - s.lastTime)
            s.lastFPS = fps.isFinite && fps >= 0 ? fps : nil
            s.total += delta
        } else {
            s.lastFPS = nil   // counter reset: start over
        }
        s.lastTime = event.time
        s.lastFrames = frames
        states[pid] = s
        updateFollowed(pid)
    }

    public func fps(pid: Int32, at time: Double) -> Double? {
        guard let s = states[pid], time - s.lastTime <= Self.staleAfter else { return nil }
        return s.lastFPS
    }

    public func totalFrames(pid: Int32) -> Int { states[pid]?.total ?? 0 }

    private mutating func updateFollowed(_ pid: Int32) {
        guard let current = followedPID, let cs = states[current] else {
            followedPID = pid
            return
        }
        if let s = states[pid], s.total > cs.total { followedPID = pid }
    }
}
