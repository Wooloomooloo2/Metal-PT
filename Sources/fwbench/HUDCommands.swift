import Foundation
import FWCore

/// `fwbench hud on|off`: the Metal HUD logging variables for apps launched afterwards (via launchd).
enum HUDCommands {
    static let usage = """
        hud on                         set MTL_HUD_ENABLED/MTL_HUD_LOG_ENABLED for apps launched from now
                                       on; stays on until Ctrl-C, then unsets them
        hud off                        unset both variables (if a previous run was killed)
        """

    static let variables = ["MTL_HUD_ENABLED", "MTL_HUD_LOG_ENABLED"]
    /// Environment added to a process we launch ourselves (`fwbench run`).
    static let environment = ["MTL_HUD_ENABLED": "1", "MTL_HUD_LOG_ENABLED": "1"]

    static func run(_ args: [String]) throws {
        switch args.first {
        case "on" where args.count == 1:
            try on()
        case "off" where args.count == 1:
            guard unset() else { exit(1) }
        default:
            throw UsageError("hud needs 'on' or 'off'")
        }
    }

    /// `launchctl getenv NAME`; nil if unset or unreadable.
    static func launchdValue(_ name: String) -> String? {
        guard let out = try? captureTool("/bin/launchctl", ["getenv", name]) else { return nil }
        let value = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Unsets both variables and reads them back; prints the outcome. False if either is still set.
    @discardableResult
    static func unset() -> Bool {
        var failed: [String] = []
        for name in variables {
            let status = (try? runTool("/bin/launchctl", ["unsetenv", name])) ?? -1
            if status != 0 || launchdValue(name) != nil { failed.append(name) }
        }
        if failed.isEmpty {
            print("HUD logging off")
            return true
        }
        printError("error: could not unset \(failed.joined(separator: ", ")); try 'launchctl unsetenv NAME'")
        return false
    }

    /// Holds the variables as a lease: Ctrl-C (or any catchable signal) unsets them.
    private static func on() throws {
        if launchdValue("MTL_HUD_ENABLED") != nil || launchdValue("MTL_HUD_LOG_ENABLED") != nil {
            throw BenchError("HUD logging is already on — a previous fwbench may have been killed; "
                             + "run 'fwbench hud off'")
        }
        let lease = Lease { print(""); unset() }
        lease.releaseOnSignals()
        for name in variables {
            let status = try runTool("/bin/launchctl", ["setenv", name, "1"])
            if status != 0 {
                lease.release()
                throw BenchError("launchctl setenv \(name) failed (status \(status))")
            }
        }
        print("HUD logging on for apps launched from now; Ctrl-C to turn off")
        print("(if fwbench is killed, run 'fwbench hud off')")
        // The signal sources run on a global queue; they release the lease and exit.
        while true { pause() }
    }
}
