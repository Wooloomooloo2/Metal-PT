import AppKit
import Foundation

/// One Metal-PT at a time: two instances would fight over the launchctl HUD variables (one quitting or reconciling
/// unsets them under the other, and under the user's game). A second launch activates the first and exits before
/// anything touches launchctl. Debug builds may run a second instance with `MPT_ALLOW_SECOND_INSTANCE=1`; that
/// instance never changes the launchctl variables.
enum SingleInstance {
    static let bundleID = "io.github.wooloomooloo2.metal-pt"
    /// Debug only: run although another instance is running, without launchctl changes.
    static let allowSecondKey = "MPT_ALLOW_SECOND_INSTANCE"

    struct Running: Equatable {
        let pid: Int32
        let bundleID: String?
        let executablePath: String?
    }

    enum Decision: Equatable {
        case run
        /// Debug override: run, but never change the launchctl variables.
        case runWithoutLaunchctl
        /// Another instance is running: activate it and exit.
        case handOff(to: Int32)
    }

    /// The installed app (bundle id) or an unbundled dev build (executable `Metal-PT` / `MetalPT`).
    static func isMetalPT(_ r: Running) -> Bool {
        if r.bundleID == bundleID { return true }
        guard let path = r.executablePath else { return false }
        return path.hasSuffix("/Metal-PT") || path.hasSuffix("/MetalPT")
    }

    static func decide(selfPID: Int32, running: [Running], allowSecond: Bool) -> Decision {
        if allowSecond { return .runWithoutLaunchctl }
        if let other = running.first(where: { $0.pid != selfPID && isMetalPT($0) }) { return .handOff(to: other.pid) }
        return .run
    }

    /// `MPT_ALLOW_SECOND_INSTANCE=1` in a debug build; always false in release builds.
    static func allowSecond(env: [String: String]) -> Bool {
        #if DEBUG
        env[allowSecondKey] == "1"
        #else
        false
        #endif
    }

    /// This user's running applications.
    @MainActor
    static func runningInstances() -> [Running] {
        NSWorkspace.shared.runningApplications.map {
            Running(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier, executablePath: $0.executableURL?.path)
        }
    }
}
