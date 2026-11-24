import Foundation

/// A held process activity (`ProcessInfo.beginActivity`). `end()` is idempotent.
public protocol ActivityToken: AnyObject, Sendable {
    func end()
}

/// Where activities come from: `SystemActivities` (the process's App Nap / idle-sleep assertions), or a fake in tests.
public protocol ActivityProviding: Sendable {
    func begin(_ options: ProcessInfo.ActivityOptions, reason: String) -> ActivityToken
}

/// What Metal-PT holds while it must not be throttled when hidden (App Nap slows timers of an app with no visible
/// window, and a recording's 1 Hz tick that slips by more than 5 s ends the steady window as "spanned a sleep").
public enum AppActivity {
    /// Held from a recording's start until it is finished (or fails to start): no App Nap, no idle system sleep.
    public static let recording: ProcessInfo.ActivityOptions = [.userInitiated, .idleSystemSleepDisabled]
    public static let recordingReason = "Recording a game run"
    /// Held while the overlay is shown: no App Nap, but the Mac may still idle-sleep.
    public static let overlay: ProcessInfo.ActivityOptions = .userInitiatedAllowingIdleSystemSleep
    public static let overlayReason = "Showing the in-game overlay"
}

/// `ProcessInfo.processInfo.beginActivity` / `endActivity`.
public struct SystemActivities: ActivityProviding {
    public init() {}

    public func begin(_ options: ProcessInfo.ActivityOptions, reason: String) -> ActivityToken {
        SystemActivity(ProcessInfo.processInfo.beginActivity(options: options, reason: reason))
    }
}

/// Ends the activity on `end()` or, if never ended, on deinit.
private final class SystemActivity: ActivityToken, @unchecked Sendable {
    private let lock = NSLock()
    private var activity: NSObjectProtocol?

    init(_ activity: NSObjectProtocol) { self.activity = activity }

    func end() {
        let a: NSObjectProtocol? = lock.withLock {
            defer { activity = nil }
            return activity
        }
        if let a { ProcessInfo.processInfo.endActivity(a) }
    }

    deinit { end() }
}
