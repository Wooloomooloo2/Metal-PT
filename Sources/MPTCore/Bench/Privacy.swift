import Foundation
import SystemConfiguration

public enum Privacy {
    /// `/Users/<name>` (any case) — not the `users/<name>` folder inside a Wine prefix, which `winePrefixRegex` keeps.
    private static let homeRegex = try! NSRegularExpression(pattern: "(?<!drive_c)/users/[^/]+",
                                                            options: .caseInsensitive)
    /// Unix paths into a Wine prefix: `…/drive_c/users/<name>` (or a relative `drive_c/users/<name>`) becomes
    /// `…/drive_c/users/~`.
    private static let winePrefixRegex = try! NSRegularExpression(pattern: #"((?<![A-Za-z0-9_])drive_c/users/)[^/]+"#,
                                                                  options: .caseInsensitive)
    private static let wineRegex = try! NSRegularExpression(pattern: #"([A-Za-z]):\\[Uu][Ss][Ee][Rr][Ss]\\[^\\]+"#)
    private static let stoplist: Set<String> = ["localhost", "mac", "macbook"]

    /// This machine's host-name variants, computed once. Read locally (no DNS): `ProcessInfo.hostName` and
    /// `Host.current()` resolve the name through NSHost, which in the bundled app waits on mDNS / Local Network
    /// privacy and stalled a recording start (and quit) for over a minute.
    static let defaultHosts: [String] = hostVariants(of: localHostNames())

    /// Computes `defaultHosts` now (the app calls it at launch, off the main thread), so the first scrub does not.
    public static func prime() { _ = defaultHosts }

    /// `gethostname()`, the computer name ("Mark's MacBook Pro") and the Bonjour local host name
    /// ("Marks-MacBook-Pro"); none of them touches the network.
    static func localHostNames() -> [String] {
        var raw: [String] = []
        var buf = [CChar](repeating: 0, count: 256)
        if gethostname(&buf, buf.count) == 0 {
            let n = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if !n.isEmpty { raw.append(n) }
        }
        if let n = SCDynamicStoreCopyComputerName(nil, nil) as String? { raw.append(n) }
        if let n = SCDynamicStoreCopyLocalHostName(nil) as String? { raw.append(n) }
        return raw
    }

    /// Expands names into scrub candidates: minus ".local", first DNS label, and the LocalHostName-style
    /// form (apostrophes dropped, spaces to "-"). Names under 4 chars or on the stoplist are dropped.
    static func hostVariants(of names: [String]) -> [String] {
        var out = Set<String>()
        for n in names {
            var v = [n]
            let noLocal = n.lowercased().hasSuffix(".local") ? String(n.dropLast(6)) : n
            v.append(noLocal)
            if let first = noLocal.split(separator: ".").first { v.append(String(first)) }
            v.append(noLocal.replacingOccurrences(of: "'", with: "")
                .replacingOccurrences(of: "\u{2019}", with: "")
                .replacingOccurrences(of: " ", with: "-"))
            for c in v where c.count >= 4 && !stoplist.contains(c.lowercased()) { out.insert(c) }
        }
        return out.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
    }

    /// Home paths only: `/Users/<name>` (any case) and Wine `X:\Users\<name>` become `~`; inside a Wine prefix,
    /// `…/drive_c/users/<name>` becomes `…/drive_c/users/~`.
    public static func scrubPaths(_ text: String) -> String {
        var s = winePrefixRegex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1~")
        s = homeRegex.stringByReplacingMatches(
            in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "~")
        s = wineRegex.stringByReplacingMatches(
            in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1:\\\\Users\\\\~")
        return s
    }

    /// Home paths plus whole-word host names (replaced by `<host>`). For free-text fields.
    public static func scrub(_ text: String, hosts: [String]? = nil) -> String {
        var s = scrubPaths(text)
        for h in hosts ?? defaultHosts {
            let pattern = "(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: h) + "(?![A-Za-z0-9])"
            guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s),
                                            withTemplate: NSRegularExpression.escapedTemplate(for: "<host>"))
        }
        return s
    }

    public static func scrub(_ info: RunInfo, hosts: [String]? = nil) -> RunInfo {
        func t(_ s: String) -> String { scrub(s, hosts: hosts) }
        var r = info
        r.appVersion = scrubPaths(r.appVersion)
        r.machine.modelID = scrubPaths(r.machine.modelID)
        r.machine.chip = scrubPaths(r.machine.chip)
        r.machine.osVersion = scrubPaths(r.machine.osVersion)
        r.machine.osBuild = scrubPaths(r.machine.osBuild)
        r.game.exe = t(r.game.exe)
        r.game.title = r.game.title.map(t)
        r.game.storeAppID = r.game.storeAppID.map(t)
        r.stack.runtime = r.stack.runtime.map(t)
        r.stack.runtimeVersion = r.stack.runtimeVersion.map(t)
        r.stack.wineArch = r.stack.wineArch.map(t)
        r.stack.translator = r.stack.translator.map(t)
        r.stack.graphics = r.stack.graphics.map(t)
        r.settings.powerMode = r.settings.powerMode.map(t)
        r.user.label = t(r.user.label)
        r.user.gameSettings = t(r.user.gameSettings)
        r.user.notes = t(r.user.notes)
        r.user.videoURL = r.user.videoURL.map(t)
        r.fpsSource = scrubPaths(r.fpsSource)
        r.warnings = r.warnings.map(t)
        return r
    }
}
