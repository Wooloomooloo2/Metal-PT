import Foundation
import MPTCore

/// The `launchctl` environment calls the FPS-logging lease needs. The real implementation runs
/// `/bin/launchctl`; tests substitute a fake and never touch the real launchd environment.
public protocol LaunchctlRunning: Sendable {
    /// `launchctl getenv NAME`; nil when unset (or unreadable).
    func getenv(_ name: String) -> String?
    func setenv(_ name: String, _ value: String) throws
    func unsetenv(_ name: String) throws
}

public enum FPSLoggingError: Error, CustomStringConvertible, Equatable {
    case stillSet([String])
    /// `launchctl <operation> <name>` failed (non-zero exit status; -1 if it could not be run).
    case commandFailed(operation: String, name: String, status: Int32)
    public var description: String {
        switch self {
        case .stillSet(let names):
            return "could not unset \(names.joined(separator: ", ")); try 'launchctl unsetenv NAME'"
        case .commandFailed(let op, let name, let status):
            return "launchctl \(op) \(name) failed (status \(status))"
        }
    }
}

/// Runs `/bin/launchctl` by absolute path.
///
/// The CLI (`mpt hud`) keeps its own small launchctl wrapper: its tool helpers live in the `mpt`
/// executable target, which cannot be imported, and the logic is three one-line calls. The variable
/// names and the read-back rule are the same in both.
public struct SystemLaunchctl: LaunchctlRunning {
    public init() {}
    private static let path = "/bin/launchctl"

    private func run(_ args: [String]) -> (status: Int32, out: String) {
        do { return try runThrowing(args) } catch { return (-1, "") }
    }

    private func runThrowing(_ args: [String]) throws -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    public func getenv(_ name: String) -> String? {
        let r = run(["getenv", name])
        guard r.status == 0 else { return nil }
        let v = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    public func setenv(_ name: String, _ value: String) throws {
        let r = run(["setenv", name, value])
        if r.status != 0 { throw FPSLoggingError.commandFailed(operation: "setenv", name: name, status: r.status) }
    }

    public func unsetenv(_ name: String) throws {
        let r = run(["unsetenv", name])
        if r.status != 0 { throw FPSLoggingError.commandFailed(operation: "unsetenv", name: name, status: r.status) }
    }
}

/// Apple's Metal HUD logging, held as a lease: `MTL_HUD_ENABLED` and `MTL_HUD_LOG_ENABLED` (and, while Apple's HUD is
/// hidden, `MTL_HUD_OPACITY=0`) are set in the launchd environment only while on, unset on turn-off and at quit, and
/// reconciled at launch (adopted if the user setting is on, otherwise stale values are unset). UI-free; call from the
/// main thread (not internally synchronised).
public final class FPSLogging {
    /// The two variables logging needs.
    public static let variables = MetalHUDEnvironment.required
    /// Every variable the lease may set (turn-off and quit unset all of them).
    public static let allVariables = MetalHUDEnvironment.all

    private let launchctl: LaunchctlRunning
    /// True when the variables are set (after a failed turn-off it stays true: it reflects reality).
    public private(set) var isOn = false
    /// Whether Apple's on-screen HUD is shown in games started while on (false: `MTL_HUD_OPACITY=0` hides it).
    public private(set) var showsHUD = false
    /// The most recent failure from any path (set/unset/reconcile/release); nil after a success.
    /// The app shows this as a banner or Settings warning.
    public private(set) var lastError: FPSLoggingError?

    public init(launchctl: LaunchctlRunning = SystemLaunchctl()) {
        self.launchctl = launchctl
    }

    private func matches(showHUD: Bool) -> Bool {
        let want = MetalHUDEnvironment.values(showHUD: showHUD)
        return Self.allVariables.allSatisfy { launchctl.getenv($0) == want[$0] }
    }
    private var anySet: Bool { Self.allVariables.contains { launchctl.getenv($0) != nil } }

    /// Call once at launch with the saved settings. Never throws: failures are logged and recorded in
    /// `lastError`; `isOn` reflects what is actually set.
    public func reconcileAtLaunch(enabled: Bool, showHUD: Bool = false) {
        showsHUD = showHUD
        if enabled {
            if matches(showHUD: showHUD) { isOn = true; lastError = nil; return }
            report { try setEnabled(true, showHUD: showHUD) }
        } else if anySet {
            report { try setEnabled(false, showHUD: showHUD) }
        } else {
            isOn = false
            lastError = nil
        }
    }

    /// Turns the variables on or off. On is atomic (a failure rolls back); off reads back and throws
    /// if any is still set. `showHUD` decides `MTL_HUD_OPACITY` while on.
    public func setEnabled(_ on: Bool, showHUD: Bool = false) throws {
        showsHUD = showHUD
        do {
            if on { try enable(showHUD: showHUD) } else { try disable() }
            lastError = nil
        } catch let e as FPSLoggingError {
            lastError = e
            throw e
        }
    }

    /// Shows or hides Apple's HUD in games started from now on. While off, only remembered for the next turn-on.
    public func setShowHUD(_ show: Bool) throws {
        if isOn { try setEnabled(true, showHUD: show) } else { showsHUD = show }
    }

    private func enable(showHUD: Bool) throws {
        do {
            let values = MetalHUDEnvironment.values(showHUD: showHUD)
            for name in Self.variables { try launchctl.setenv(name, values[name] ?? "1") }
            if let opacity = values[MetalHUDEnvironment.opacity] {
                try launchctl.setenv(MetalHUDEnvironment.opacity, opacity)
            } else if launchctl.getenv(MetalHUDEnvironment.opacity) != nil {
                try launchctl.unsetenv(MetalHUDEnvironment.opacity)
                if launchctl.getenv(MetalHUDEnvironment.opacity) != nil {
                    throw FPSLoggingError.stillSet([MetalHUDEnvironment.opacity])
                }
            }
        } catch {
            for name in Self.allVariables { try? launchctl.unsetenv(name) }
            isOn = Self.variables.contains { launchctl.getenv($0) != nil }
            throw error
        }
        isOn = true
    }

    private func disable() throws {
        var failed: [String] = []
        var firstError: FPSLoggingError?
        for name in Self.allVariables {
            do { try launchctl.unsetenv(name) } catch {
                firstError = firstError ?? (error as? FPSLoggingError)
                    ?? .commandFailed(operation: "unsetenv", name: name, status: -1)
            }
            if launchctl.getenv(name) != nil { failed.append(name) }
        }
        isOn = Self.variables.contains { failed.contains($0) }
        if !failed.isEmpty { throw firstError ?? FPSLoggingError.stillSet(failed) }
        if let firstError { throw firstError }
    }

    /// Hands the variables back at quit, even if we believe we never took them (recovery reads state).
    public func releaseAtQuit() {
        report { try setEnabled(false, showHUD: showsHUD) }
    }

    private func report(_ body: () throws -> Void) {
        do { try body() } catch {
            try? FileHandle.standardError.write(contentsOf: Data("Metal-PT FPS logging: \(error)\n".utf8))
        }
    }
}
