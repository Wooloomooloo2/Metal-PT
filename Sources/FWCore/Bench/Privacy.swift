import Foundation

public enum Privacy {
    private static let homeRegex = try! NSRegularExpression(pattern: "/Users/[^/]+")

    /// Replaces `/Users/<name>` with `~` and removes this machine's host names.
    public static func scrub(_ text: String) -> String {
        var s = homeRegex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "~")
        var names = [ProcessInfo.processInfo.hostName]
        if let n = Host.current().localizedName { names.append(n) }
        // Longest first so "Foo.local" goes before "Foo".
        for n in names.filter({ !$0.isEmpty }).sorted(by: { $0.count > $1.count }) {
            s = s.replacingOccurrences(of: n, with: "", options: .caseInsensitive)
        }
        return s
    }

    public static func scrub(_ info: RunInfo) -> RunInfo {
        var r = info
        r.appVersion = scrub(r.appVersion)
        r.machine.modelID = scrub(r.machine.modelID)
        r.machine.chip = scrub(r.machine.chip)
        r.machine.osVersion = scrub(r.machine.osVersion)
        r.machine.osBuild = scrub(r.machine.osBuild)
        r.game.exe = scrub(r.game.exe)
        r.game.title = r.game.title.map(scrub)
        r.game.storeAppID = r.game.storeAppID.map(scrub)
        r.stack.runtime = r.stack.runtime.map(scrub)
        r.stack.runtimeVersion = r.stack.runtimeVersion.map(scrub)
        r.stack.wineArch = r.stack.wineArch.map(scrub)
        r.stack.translator = r.stack.translator.map(scrub)
        r.stack.graphics = r.stack.graphics.map(scrub)
        r.settings.powerMode = r.settings.powerMode.map(scrub)
        r.user.label = scrub(r.user.label)
        r.user.gameSettings = scrub(r.user.gameSettings)
        r.user.notes = scrub(r.user.notes)
        r.fpsSource = scrub(r.fpsSource)
        r.warnings = r.warnings.map(scrub)
        return r
    }
}
