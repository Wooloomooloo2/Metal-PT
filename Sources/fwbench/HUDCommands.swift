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
            unset()
            print("HUD logging off")
        default:
            throw UsageError("hud needs 'on' or 'off'")
        }
    }

    static func unset() {
        for name in variables { _ = try? runTool("/bin/launchctl", ["unsetenv", name]) }
    }

    /// Holds the variables as a lease: Ctrl-C (or any catchable signal) unsets them.
    private static func on() throws {
        let lease = Lease { unset(); print("\nHUD logging off") }
        lease.releaseOnSignals()
        for name in variables {
            let status = try runTool("/bin/launchctl", ["setenv", name, "1"])
            if status != 0 {
                lease.release()
                throw BenchError("launchctl setenv \(name) failed (status \(status))")
            }
        }
        print("HUD logging on for apps launched from now; Ctrl-C to turn off")
        // The signal sources run on a global queue; they release the lease and exit.
        while true { pause() }
    }
}
