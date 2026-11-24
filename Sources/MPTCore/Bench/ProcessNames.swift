import Foundation

public enum ProcessNames {
    /// Last path component, splitting on both `/` and `\` (Wine processes report Windows paths).
    public static func exeName(fromArgv0 argv0: String) -> String {
        argv0.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? argv0
    }

    /// argv[0] of a process via `sysctl KERN_PROCARGS2`; nil if unreadable.
    public static func displayName(pid: Int32) -> String? {
        procArgs(pid: pid).flatMap(argv0(fromProcArgs:))
    }

    /// The environment of a process via `sysctl KERN_PROCARGS2` (readable for the same user's processes); nil if
    /// unreadable (gone, another user's, or a malformed buffer). A process started without variables gives `[:]`.
    public static func environment(pid: Int32) -> [String: String]? {
        procArgs(pid: pid).flatMap(parseProcArgs)?.env
    }

    /// The raw `KERN_PROCARGS2` buffer of `pid`; nil if unreadable.
    static func procArgs(pid: Int32) -> [UInt8]? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        return Array(buf.prefix(size))
    }

    /// Parses a `KERN_PROCARGS2` buffer: argc (Int32, host order), exec path, NUL padding, `argc` argv strings, then
    /// `KEY=value` env strings up to the first empty string (or the end). Nil when argc or the argv strings are
    /// cut off. In env, a string cut off by the end of the buffer and strings without `=` are dropped; the first
    /// value of a repeated key wins. An empty argv[0] cannot be told apart from the padding (ps(1) has the same
    /// limit): it is absorbed, so argv takes the next string and env starts one string later.
    public static func parseProcArgs(_ b: [UInt8]) -> (argv: [String], env: [String: String])? {
        let n = MemoryLayout<Int32>.size
        guard b.count >= n else { return nil }
        let argc = b.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        // Each argv string takes at least one byte: an argc past the buffer is malformed (and is not looped over).
        guard argc >= 0, Int(argc) <= b.count - n else { return nil }
        var i = n
        while i < b.count, b[i] != 0 { i += 1 }      // exec path
        guard i < b.count else { return nil }
        while i < b.count, b[i] == 0 { i += 1 }      // padding
        /// The NUL-terminated string at `i`, or nil if the buffer ends first.
        func next() -> String? {
            var j = i
            while j < b.count, b[j] != 0 { j += 1 }
            guard j < b.count else { return nil }
            defer { i = j + 1 }
            return String(decoding: b[i..<j], as: UTF8.self)
        }
        var argv: [String] = []
        for _ in 0..<argc {
            guard let s = next() else { return nil }
            argv.append(s)
        }
        var env: [String: String] = [:]
        while i < b.count, let s = next(), !s.isEmpty {
            guard let eq = s.firstIndex(of: "=") else { continue }
            let key = String(s[..<eq])
            if env[key] == nil { env[key] = String(s[s.index(after: eq)...]) }
        }
        return (argv, env)
    }

    /// The process's start time in microseconds since 1970 (`proc_pidinfo` `PROC_PIDTBSDINFO`), which tells a reused
    /// PID apart from the process that had it before; nil if the process does not exist (or is not visible).
    public static func startTime(pid: Int32) -> UInt64? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec
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
