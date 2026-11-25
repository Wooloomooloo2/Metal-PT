import Foundation

/// Which translation stack a game process runs on.
public struct Stack: Codable, Equatable, Sendable {
    /// "Protium", "CrossOver", "Whisky", "Kegworks", "GPTK", "Wine (unknown)", "native"
    public var runtime: String?
    public var runtimeVersion: String?
    /// "arm64ec", "x86_64"
    public var wineArch: String?
    /// "FEX", "Rosetta", nil
    public var translator: String?
    /// e.g. ["DXMT", "vkd3d", "KosmicKrisp"], in table order
    public var graphics: [String]
    /// Versions of graphics layers that report one, by name ("D3DMetal": "4.0b3", the GPTK version). nil in runs
    /// recorded before 2026-11-25.
    public var graphicsVersions: [String: String]?

    /// The graphics layers with their versions: "D3DMetal 4.0b3 + MoltenVK".
    public var graphicsText: String {
        graphics.map { g in graphicsVersions?[g].map { "\(g) \($0)" } ?? g }.joined(separator: " + ")
    }

    public init(runtime: String? = nil, runtimeVersion: String? = nil, wineArch: String? = nil,
                translator: String? = nil, graphics: [String] = [], graphicsVersions: [String: String]? = nil) {
        self.graphicsVersions = graphicsVersions
        self.runtime = runtime
        self.runtimeVersion = runtimeVersion
        self.wineArch = wineArch
        self.translator = translator
        self.graphics = graphics
    }
}

public enum StackDetector {
    /// Matches the runtime app bundle: `…/Protium.app`, `…/Whisky.app`, `…/Kegworks.app`, `…/CrossOver*.app`.
    private static let appRegex = try! NSRegularExpression(
        pattern: #"^(.*?/(Protium|Whisky|Kegworks|CrossOver[^/]*)\.app)/"#)

    /// Runtimes recognised by a path alone, after the app bundles: (name, matcher), first match wins.
    private static let runtimePathTable: [(String, @Sendable (String) -> Bool)] = [
        // Kegworks wrappers live in `…/Kegworks/<Game>.app`.
        ("Kegworks", { $0.contains("/Kegworks/") }),
        ("GPTK", { $0.contains("game-porting-toolkit") || $0.contains("Game Porting Toolkit") }),
    ]

    /// A Wine build that no runtime above claims.
    private static func isWinePath(_ path: String) -> Bool {
        if path.contains("/lib/wine/") { return true }
        let name = (path as NSString).lastPathComponent
        return ["wine", "wine64", "wineserver", "wine-preloader", "wine64-preloader"].contains(name)
    }

    private static func appMatch(_ path: String) -> (bundle: String, runtime: String)? {
        let range = NSRange(path.startIndex..., in: path)
        guard let m = appRegex.firstMatch(in: path, range: range),
              let b = Range(m.range(at: 1), in: path), let n = Range(m.range(at: 2), in: path)
        else { return nil }
        let name = String(path[n])
        return (String(path[b]), name.hasPrefix("CrossOver") ? "CrossOver" : name)
    }

    /// Path of the runtime's `.app` bundle among the mapped paths, if any (pure).
    public static func appBundlePath(in mappedPaths: [String]) -> String? {
        for p in mappedPaths { if let m = appMatch(p) { return m.bundle } }
        return nil
    }

    /// Graphics layers in table order: (name, matcher).
    private static let graphicsTable: [(String, @Sendable (String) -> Bool)] = [
        ("DXMT", { $0.contains("winemetal.so") || $0.contains("/dxmt/") }),
        ("D3DMetal", { $0.contains("D3DMetal.framework") || $0.contains("libd3dshared") }),
        ("DXVK", { $0.contains("/dxvk/") }),
        ("MoltenVK", { $0.contains("libMoltenVK") }),
        ("KosmicKrisp", { $0.contains("libvulkan_kosmickrisp") }),
        // GPTK 4 ships its own d3d12core.dll next to D3DMetal (`…/apple_gptk/wine/…`): that one is not vkd3d.
        ("vkd3d", { $0.contains("libvkd3d") || ($0.contains("d3d12core.dll") && !$0.contains("apple_gptk")) }),
    ]

    /// The `…/D3DMetal.framework` folder the process mapped (CrossOver keeps one per GPTK version:
    /// `lib/apple_gptk`, `lib/apple_gptk3`, older builds `lib64/apple_gptk`), if any (pure).
    public static func frameworkPath(_ name: String, in mappedPaths: [String]) -> String? {
        let marker = "/\(name).framework/"
        for p in mappedPaths { if let r = p.range(of: marker) { return String(p[..<r.upperBound].dropLast()) } }
        return nil
    }

    public static func fingerprint(mappedPaths: [String]) -> Stack {
        var stack = Stack()
        stack.runtime = mappedPaths.lazy.compactMap { appMatch($0)?.runtime }.first
            ?? runtimePathTable.first { _, match in mappedPaths.contains(where: match) }?.0
            ?? (mappedPaths.contains(where: isWinePath) ? "Wine (unknown)" : "native")
        if mappedPaths.contains(where: { $0.contains("libarm64ecfex") }) {
            stack.translator = "FEX"
            stack.wineArch = "arm64ec"
        } else if mappedPaths.contains(where: { $0.contains("/usr/libexec/rosetta") || $0.contains("/oah/") || $0.contains("oahd") }) {
            stack.translator = "Rosetta"
        }
        stack.graphics = graphicsTable.filter { name, match in mappedPaths.contains(where: match) }.map(\.0)
        return stack
    }

    /// Fingerprints a live process from `lsof -Fn`. A failed or empty read gives `Stack(runtime: nil)` (unknown);
    /// "native" only means paths were read and none matched.
    public static func detect(pid: Int32) -> Stack {
        guard let paths = mappedPaths(pid: pid) else { return Stack(runtime: nil) }
        var stack = fingerprint(mappedPaths: paths)
        if let app = appBundlePath(in: paths),
           let plist = NSDictionary(contentsOfFile: app + "/Contents/Info.plist") {
            stack.runtimeVersion = plist["CFBundleShortVersionString"] as? String
        }
        if stack.graphics.contains("D3DMetal"), let fw = frameworkPath("D3DMetal", in: paths),
           let v = (NSDictionary(contentsOfFile: fw + "/Resources/Info.plist")
                    ?? NSDictionary(contentsOfFile: fw + "/Versions/A/Resources/Info.plist"))?["CFBundleShortVersionString"] as? String,
           !v.isEmpty {
            stack.graphicsVersions = ["D3DMetal": v]
        }
        return stack
    }

    /// nil when lsof can't run, times out (5 s), exits non-zero with no output, or prints no paths.
    private static func mappedPaths(pid: Int32, timeout: TimeInterval = 5) -> [String]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-b", "-Fn", "-p", String(pid)]   // -b: don't block in kernel calls
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        timer.cancel()
        if p.terminationReason == .uncaughtSignal { return nil }   // killed by the timeout
        let paths = String(decoding: data, as: UTF8.self).split(separator: "\n")
            .filter { $0.hasPrefix("n") }.map { String($0.dropFirst()) }
        return paths.isEmpty ? nil : paths
    }
}
