import Foundation
import MPTCore

/// "Game not reporting frames" (spec §B): the frontmost app keeps the GPU busy but logs no Metal HUD lines, and its
/// environment lacks the HUD variables — it was started (or its launcher was) before FPS logging was turned on.
///
/// Fed one `Input` per hub sample (1 Hz). Fires when FPS logging is on, the hub is sampling, the frontmost app is not
/// Metal-PT, no other process is sending HUD lines (GPU busy is system-wide: a game reporting in the background would
/// make the app in front look busy), GPU busy ≥ `busyPct` for `ticksNeeded` consecutive ticks with no HUD line from
/// that PID, and its environment is readable and lacks `MTL_HUD_LOG_ENABLED`. Says nothing for apps that have the
/// variable (they are just not Metal games) or whose environment cannot be read. Clears when HUD lines arrive from it
/// or from another process, a different app (not Metal-PT) comes to the front, the app quits, FPS logging goes off or
/// sampling stops; a GPU dip only restarts the count. Metal-PT itself (or nothing) in front leaves the state as it is.
///
/// Environment and launcher lookups (sysctl/proc_pidinfo) run at most once per PID per `lookupCacheSeconds`.
/// The message names apps; it is shown in the UI only and never written to run bundles.
public struct FrameReportingCheck {
    public struct Input: Sendable {
        /// Seconds (any monotonic-enough clock; the hub's sample time).
        public var now: Double
        public var fpsLoggingOn: Bool
        public var sampling: Bool
        public var frontmostPID: Int32?
        public var frontmostApp: String?
        public var selfPID: Int32
        public var gpuBusyPct: Double?
        /// The frontmost PID sent a HUD line recently (`TelemetryHub.hasLiveHUD(pid:)`).
        public var hudLive: Bool
        /// Another process (not the frontmost, not Metal-PT) sent a HUD line recently: GPU busy is system-wide, so
        /// a game reporting in the background (second display, windowed) must not be blamed on the app in front.
        public var otherHUDActive: Bool

        public init(now: Double, fpsLoggingOn: Bool, sampling: Bool, frontmostPID: Int32?, frontmostApp: String?,
                    selfPID: Int32, gpuBusyPct: Double?, hudLive: Bool, otherHUDActive: Bool) {
            self.now = now
            self.fpsLoggingOn = fpsLoggingOn
            self.sampling = sampling
            self.frontmostPID = frontmostPID
            self.frontmostApp = frontmostApp
            self.selfPID = selfPID
            self.gpuBusyPct = gpuBusyPct
            self.hudLive = hudLive
            self.otherHUDActive = otherHUDActive
        }
    }

    public static let busyPct = 50.0
    public static let ticksNeeded = 10
    public static let lookupCacheSeconds = 30.0
    /// The variable whose absence means the process started before FPS logging was on.
    public static let hudVariable = "MTL_HUD_LOG_ENABLED"

    public private(set) var warning: String?

    private let environment: (Int32) -> [String: String]?
    private let launcher: (Int32) -> (name: String, pid: Int32)?
    private let isAlive: (Int32) -> Bool
    private var pid: Int32?
    private var busyTicks = 0
    private var envCache: [Int32: (at: Double, env: [String: String]?)] = [:]
    private var launcherCache: [Int32: (at: Double, launcher: (name: String, pid: Int32)?)] = [:]

    public init(environment: @escaping (Int32) -> [String: String]? = { ProcessNames.environment(pid: $0) },
                launcher: @escaping (Int32) -> (name: String, pid: Int32)? = { ProcessTree.launcher(of: $0) },
                isAlive: @escaping (Int32) -> Bool = { kill($0, 0) == 0 || errno == EPERM }) {
        self.environment = environment
        self.launcher = launcher
        self.isAlive = isAlive
    }

    /// One tick; returns the warning to show (nil: none).
    @discardableResult
    public mutating func tick(_ i: Input) -> String? {
        guard i.fpsLoggingOn, i.sampling else {
            reset(pid: nil)
            return nil
        }
        // Metal-PT in front (the user clicked it to read the warning) or nothing in front: keep the state as it
        // is — no reset, no count — unless the tracked app has quit or a game is now reporting.
        guard let front = i.frontmostPID, front != i.selfPID else {
            if let p = pid, !isAlive(p) || i.otherHUDActive { reset(pid: nil) }
            return warning
        }
        if front != pid { reset(pid: front) }
        if i.hudLive || i.otherHUDActive {
            reset(pid: front)
            return nil
        }
        guard warning == nil else { return warning }
        if let g = i.gpuBusyPct, g >= Self.busyPct { busyTicks += 1 } else { busyTicks = 0 }
        guard busyTicks >= Self.ticksNeeded, let env = cachedEnvironment(front, now: i.now),
              env[Self.hudVariable] == nil else { return nil }
        let app = i.frontmostApp.flatMap { $0.isEmpty ? nil : $0 } ?? "The frontmost app"
        if let l = cachedLauncher(front, now: i.now) {
            warning = "\(app) started before FPS logging was on — quit it and \(l.name) and open them again."
        } else {
            warning = "\(app) started before FPS logging was on — quit it and open it again."
        }
        return warning
    }

    private mutating func reset(pid newPID: Int32?) {
        pid = newPID
        busyTicks = 0
        warning = nil
    }

    private mutating func cachedEnvironment(_ pid: Int32, now: Double) -> [String: String]? {
        if let c = envCache[pid], now - c.at < Self.lookupCacheSeconds { return c.env }
        envCache = envCache.filter { now - $0.value.at < Self.lookupCacheSeconds }
        let env = environment(pid)
        envCache[pid] = (now, env)
        return env
    }

    private mutating func cachedLauncher(_ pid: Int32, now: Double) -> (name: String, pid: Int32)? {
        if let c = launcherCache[pid], now - c.at < Self.lookupCacheSeconds {
            return c.launcher
        }
        launcherCache = launcherCache.filter { now - $0.value.at < Self.lookupCacheSeconds }
        let l = launcher(pid)
        launcherCache[pid] = (now, l)
        return l
    }
}
