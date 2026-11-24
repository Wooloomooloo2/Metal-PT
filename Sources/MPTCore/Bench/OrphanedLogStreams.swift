import Foundation

/// A `MetalHUDLogStream` child outlives Metal-PT when Metal-PT crashes or is killed: `log` is re-parented to launchd
/// and keeps running until its next write fails. At launch Metal-PT ends those leftovers: processes whose command
/// line is exactly our stream's, whose parent is launchd (ppid 1) and which belong to this user. No other `log`
/// process is touched (any other predicate or option, another user's, or one with a live parent).
public enum OrphanedLogStreams {
    /// `ps`'s `command` column for our stream (argv joined by spaces).
    public static let commandLine = ([MetalHUDLogStream.executable] + MetalHUDLogStream.arguments)
        .joined(separator: " ")

    /// The PIDs in `ps -axww -o pid=,ppid=,uid=,command=` output that are our orphaned streams owned by `uid`.
    public static func orphans(psOutput: String, uid: uid_t) -> [Int32] {
        psOutput.split(separator: "\n").compactMap { line -> Int32? in
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count == 4, let pid = Int32(fields[0]), let ppid = Int32(fields[1]),
                  let owner = UInt32(fields[2]), ppid == 1, owner == uid,
                  fields[3].trimmingCharacters(in: .whitespaces) == commandLine else { return nil }
            return pid
        }
    }

    /// Lists processes with `/bin/ps` and sends SIGTERM to each of this user's orphaned streams. Returns their PIDs.
    /// Blocking (one `ps`): call off the main thread.
    @discardableResult
    public static func terminateAll() -> [Int32] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axww", "-o", "pid=,ppid=,uid=,command="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let pids = orphans(psOutput: String(decoding: data, as: UTF8.self), uid: getuid())
        for pid in pids { kill(pid, SIGTERM) }
        return pids
    }
}
