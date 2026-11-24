import Foundation

public enum ProcessNames {
    /// Last path component, splitting on both `/` and `\` (Wine processes report Windows paths).
    public static func exeName(fromArgv0 argv0: String) -> String {
        argv0.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? argv0
    }

    /// argv[0] of a process via `sysctl KERN_PROCARGS2`; nil if unreadable.
    public static func displayName(pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        return argv0(fromProcArgs: Array(buf.prefix(size)))
    }

    /// Layout: argc (Int32), exec path, NUL padding, then argv strings.
    static func argv0(fromProcArgs b: [UInt8]) -> String? {
        var i = MemoryLayout<Int32>.size
        guard b.count > i else { return nil }
        while i < b.count, b[i] != 0 { i += 1 }      // exec path
        while i < b.count, b[i] == 0 { i += 1 }      // padding
        guard i < b.count else { return nil }
        var j = i
        while j < b.count, b[j] != 0 { j += 1 }
        return String(decoding: b[i..<j], as: UTF8.self)
    }
}
