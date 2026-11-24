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
        /// The `.app` bundle, when it is one.
        var bundleURL: URL? = nil
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

    /// How to bring the running instance forward. A menu-bar-only app ignores activation, so a bundled one is
    /// opened again through LaunchServices, which sends it the reopen event (its delegate shows the window).
    enum HandOff: Equatable {
        case reopen(URL)
        case activate(Int32)
    }

    static func handOff(to other: Running) -> HandOff {
        if let url = other.bundleURL, url.pathExtension == "app" { return .reopen(url) }
        return .activate(other.pid)
    }

    /// Hands off to `other` and waits (up to 5 s) for LaunchServices to deliver the reopen event.
    @MainActor
    static func perform(_ handOff: HandOff) {
        switch handOff {
        case .reopen(let url):
            let done = DispatchSemaphore(value: 0)
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error {
                    try? FileHandle.standardError.write(contentsOf: Data(
                        "Metal-PT: could not reopen the running Metal-PT: \(error.localizedDescription)\n".utf8))
                }
                done.signal()
            }
            _ = done.wait(timeout: .now() + 5)
        case .activate(let pid):
            NSRunningApplication(processIdentifier: pid)?.activate(from: .current, options: [.activateAllWindows])
        }
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
            Running(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier, executablePath: $0.executableURL?.path,
                    bundleURL: $0.bundleURL)
        }
    }
}
