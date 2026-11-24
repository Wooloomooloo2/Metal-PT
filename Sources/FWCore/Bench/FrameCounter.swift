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
/// process to follow: the one with the most frames gained so far among the live ones. A process with no line for
/// longer than `staleAfter` is gone (exited, or a launcher that handed off), so a restarted game takes over at once.
public struct FrameCounter: Sendable {
    private struct State {
        var lastTime: Double
        var lastFrames: Int
        var lastFPS: Double?
        var total: Int
    }

    /// FPS older than this (seconds) is considered stale, and a process this quiet is treated as gone.
    public static let staleAfter = 2.5
    /// Same count within this many seconds of the previous line = duplicate log entry.
    private static let duplicateWindow = 0.25

    private var states: [Int32: State] = [:]
    public private(set) var followedPID: Int32?
    /// Time of the newest line seen from any process.
    public private(set) var latestTime: Double?

    public init() {}

    public mutating func add(_ event: HUDEvent) {
        let frames = event.line.frames
        guard frames >= 0, event.time.isFinite else { return }
        let pid = event.pid
        latestTime = max(latestTime ?? event.time, event.time)
        guard var s = states[pid] else {
            states[pid] = State(lastTime: event.time, lastFrames: frames, lastFPS: nil, total: 0)
            updateFollowed(pid, at: event.time)
            return
        }
        guard event.time > s.lastTime else { return }
        // The unified log can deliver each HUD line twice (empty subsystem, then `com.apple.metal.hud`), well under
        // a millisecond apart; HUD lines are ~1 s apart, so an unchanged count this soon is that duplicate.
        if frames == s.lastFrames && event.time - s.lastTime < Self.duplicateWindow { return }
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
        updateFollowed(pid, at: event.time)
    }

    public func fps(pid: Int32, at time: Double) -> Double? {
        guard let s = states[pid], time - s.lastTime <= Self.staleAfter else { return nil }
        return s.lastFPS
    }

    public func totalFrames(pid: Int32) -> Int { states[pid]?.total ?? 0 }

    /// True when `pid` sent a line within `staleAfter` of `time`.
    public func isLive(pid: Int32, at time: Double) -> Bool {
        guard let s = states[pid] else { return false }
        return time - s.lastTime <= Self.staleAfter
    }

    /// The live process with the most frames (ties: lower PID), optionally only among `candidates`.
    public func busiestLive(at time: Double, among candidates: [Int32]? = nil) -> Int32? {
        (candidates ?? Array(states.keys)).filter { isLive(pid: $0, at: time) }.max { a, b in
            let (fa, fb) = (totalFrames(pid: a), totalFrames(pid: b))
            return fa != fb ? fa < fb : a > b
        }
    }

    private mutating func updateFollowed(_ pid: Int32, at time: Double) {
        guard let current = followedPID, let cs = states[current] else {
            followedPID = pid
            return
        }
        if isLive(pid: current, at: time) {
            if let s = states[pid], s.total > cs.total { followedPID = pid }
        } else {
            followedPID = busiestLive(at: time) ?? current
        }
    }
}
