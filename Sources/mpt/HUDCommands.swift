import Foundation
import MPTCore

/// `mpt hud on|off`: the Metal HUD logging variables for apps launched afterwards (via launchd).
enum HUDCommands {
    static let usage = """
        hud on [--show-hud]            set MTL_HUD_ENABLED/MTL_HUD_LOG_ENABLED for apps launched from now
                                       on; stays on until Ctrl-C, then unsets them; Apple's HUD panel is
                                       hidden (MTL_HUD_OPACITY=0, frame times unchanged) unless --show-hud
        hud off                        unset the variables (if a previous run was killed)
        """

    /// Every variable `hud on` may set (`hud off` and Ctrl-C unset all of them).
    static let variables = MetalHUDEnvironment.all

    static func run(_ args: [String]) throws {
        switch args.first {
        case "on" where args.count == 1:
            try on(showHUD: false)
        case "on" where args.count == 2 && args[1] == "--show-hud":
            try on(showHUD: true)
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

    /// Unsets the variables and reads them back; prints the outcome. False if any is still set.
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
    private static func on(showHUD: Bool) throws {
        if MetalHUDEnvironment.required.contains(where: { launchdValue($0) != nil }) {
            throw BenchError("HUD logging is already on — a previous mpt may have been killed; "
                             + "run 'mpt hud off'")
        }
        let lease = Lease { print(""); unset() }
        lease.releaseOnSignals()
        let values = MetalHUDEnvironment.values(showHUD: showHUD)
        // A leftover MTL_HUD_OPACITY (e.g. from a killed `hud on`) would hide the HUD that --show-hud asks for.
        if showHUD { _ = try? runTool("/bin/launchctl", ["unsetenv", MetalHUDEnvironment.opacity]) }
        for name in variables {
            guard let value = values[name] else { continue }
            let status = try runTool("/bin/launchctl", ["setenv", name, value])
            if status != 0 {
                lease.release()
                throw BenchError("launchctl setenv \(name) failed (status \(status))")
            }
        }
        print("HUD logging on for apps launched from now (Apple's HUD panel \(showHUD ? "shown" : "hidden")); "
              + "Ctrl-C to turn off")
        print("(if mpt is killed, run 'mpt hud off')")
        // The signal sources run on a global queue; they release the lease and exit.
        while true { pause() }
    }
}
