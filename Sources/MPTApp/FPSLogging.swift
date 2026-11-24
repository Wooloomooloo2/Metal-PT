import Foundation

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
    public var description: String {
        switch self {
        case .stillSet(let names):
            return "could not unset \(names.joined(separator: ", ")); try 'launchctl unsetenv NAME'"
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

    private func run(_ args: [String]) throws -> (status: Int32, out: String) {
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
        guard let r = try? run(["getenv", name]) else { return nil }
        let v = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    public func setenv(_ name: String, _ value: String) throws {
        let r = try run(["setenv", name, value])
        if r.status != 0 { throw CocoaError(.fileWriteUnknown) }
    }

    public func unsetenv(_ name: String) throws {
        let r = try run(["unsetenv", name])
        if r.status != 0 { throw CocoaError(.fileWriteUnknown) }
    }
}

/// Apple's Metal HUD logging, held as a lease: `MTL_HUD_ENABLED` and `MTL_HUD_LOG_ENABLED` are set in
/// the launchd environment only while on, unset on turn-off and at quit, and reconciled at launch
/// (adopted if the user setting is on, otherwise stale values are unset). UI-free; call from the main
/// thread (not internally synchronised).
public final class FPSLogging {
    public static let variables = ["MTL_HUD_ENABLED", "MTL_HUD_LOG_ENABLED"]

    private let launchctl: LaunchctlRunning
    public private(set) var isOn = false

    public init(launchctl: LaunchctlRunning = SystemLaunchctl()) {
        self.launchctl = launchctl
    }

    private var allSet: Bool { Self.variables.allSatisfy { launchctl.getenv($0) != nil } }
    private var anySet: Bool { Self.variables.contains { launchctl.getenv($0) != nil } }

    /// Call once at launch with the saved setting. Never throws: failures are logged and `isOn`
    /// reflects what was read back.
    public func reconcileAtLaunch(enabled: Bool) {
        if enabled {
            if allSet { isOn = true; return }
            do { try setEnabled(true) } catch { log("could not enable: \(error)") }
        } else if anySet {
            do { try setEnabled(false) } catch { log("stale values: \(error)") }
        } else {
            isOn = false
        }
    }

    /// Turns both variables on or off. Off reads back and throws if either is still set.
    public func setEnabled(_ on: Bool) throws {
        if on {
            for name in Self.variables { try launchctl.setenv(name, "1") }
            isOn = true
            return
        }
        isOn = false
        var failed: [String] = []
        for name in Self.variables {
            do { try launchctl.unsetenv(name) } catch { failed.append(name); continue }
            if launchctl.getenv(name) != nil { failed.append(name) }
        }
        if !failed.isEmpty { throw FPSLoggingError.stillSet(failed) }
    }

    /// Hands the variables back at quit, even if we believe we never took them (recovery reads state).
    public func releaseAtQuit() {
        do { try setEnabled(false) } catch { log("release at quit: \(error)") }
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("Metal-PT FPS logging: \(message)\n".utf8))
    }
}
