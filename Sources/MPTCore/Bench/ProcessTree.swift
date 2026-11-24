import Darwin
import Foundation

/// A process's ancestry, for naming the app that launched a game (Steam, a launcher, Terminal).
public enum ProcessTree {
    /// Most ancestors walked before giving up (a chain this long is a cycle or nonsense).
    static let maxDepth = 64

    /// The parent PID (`proc_pidinfo` `PROC_PIDTBSDINFO`) and executable path (`proc_pidpath`) of `pid`; nil if
    /// either is unreadable.
    public static func info(pid: Int32) -> (ppid: Int32, path: String)? {
        guard pid > 0 else { return nil }
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size else { return nil }
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        let path = String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return (Int32(bitPattern: bsd.pbi_ppid), path)
    }

    /// The launcher of `pid`, read from the live process table.
    public static func launcher(of pid: Int32) -> (name: String, pid: Int32)? {
        launcher(of: pid, info: { info(pid: $0) })
    }

    /// The first ancestor of `pid` (walking parent PIDs up to, not including, launchd) that is an app (its
    /// executable is in a bundle's `Contents/MacOS/`) other than the one `pid` itself belongs to; nil if none.
    /// The name is the outermost bundle's folder name without `.app` ("Steam" for both `/Applications/Steam.app`
    /// and Steam's real `…/Steam.AppBundle/Steam/Contents/MacOS/steam_osx`, which has no `.app` in its path).
    public static func launcher(of pid: Int32, info: (Int32) -> (ppid: Int32, path: String)?)
        -> (name: String, pid: Int32)? {
        guard let me = info(pid) else { return nil }
        let own = bundle(ofExecutable: me.path)?.path
        var seen: Set<Int32> = [pid]
        var current = me.ppid
        while current > 1, seen.count <= maxDepth, seen.insert(current).inserted, let node = info(current) {
            if let b = bundle(ofExecutable: node.path), b.path != own { return (b.name, current) }
            current = node.ppid
        }
        return nil
    }

    /// Folders inside a bundle's `Contents/` that hold nested bundles (helpers, login items, plug-ins).
    static let nestedBundleFolders: Set<String> = ["Frameworks", "Helpers", "Library", "PlugIns", "XPCServices",
                                                    "Resources", "SharedSupport", "Applications"]

    /// The outermost bundle holding an app executable: its path and its folder name without `.app`; nil when the
    /// path is not an app executable. The executable's own bundle is the path before the LAST `/Contents/MacOS/`;
    /// an enclosing bundle is a prefix followed by `/Contents/<one of nestedBundleFolders>/` or
    /// `/Contents/MacOS/<one of them>/` (measured: Steam's helpers are in `Steam/Contents/MacOS/Frameworks/`), so a
    /// helper belongs to its app while an ordinary folder named `Contents` above an app does not count. The
    /// outermost such prefix wins.
    public static func bundle(ofExecutable path: String) -> (path: String, name: String)? {
        guard let macOS = path.range(of: "/Contents/MacOS/", options: .backwards) else { return nil }
        var bundlePath = String(path[..<macOS.lowerBound])
        var search = bundlePath.startIndex..<bundlePath.endIndex
        while let r = bundlePath.range(of: "/Contents/", range: search) {
            var rest = bundlePath[r.upperBound...]
            if rest.hasPrefix("MacOS/") { rest = rest.dropFirst("MacOS/".count) }   // Steam: Contents/MacOS/Frameworks
            if let folder = rest.split(separator: "/", maxSplits: 1).first, nestedBundleFolders.contains(String(folder)),
               rest.contains("/") {
                bundlePath = String(bundlePath[..<r.lowerBound])
                break
            }
            search = r.upperBound..<bundlePath.endIndex
        }
        var name = (bundlePath as NSString).lastPathComponent
        if name.hasSuffix(".app") { name.removeLast(4) }
        guard !name.isEmpty else { return nil }
        return (bundlePath, name)
    }
}
