import Foundation
import FWCore

enum RecordCommands {
    static let usage = """
        record [--pid P | --name S] [--seconds N] [--warmup S] [--label TEXT]
                                       record telemetry + Metal HUD FPS until N seconds pass or Ctrl-C;
                                       follows the Metal process with the most frames unless --pid/--name
        run [--seconds N] [--warmup S] [--label TEXT] -- CMD ARGS...
                                       launch CMD with the HUD variables, record it and its per-frame times;
                                       stops at N seconds, when CMD exits or on Ctrl-C (CMD keeps running)
        stack PID                      print the detected runtime / translator / graphics stack as JSON
        ls                             list recorded runs
        (record/run/ls also take --out DIR to use DIR instead of ~/Documents/FW Benchmark/runs)
        """

    static let appVersion = "0.1.0-dev"
    static let noHUDHint = "no Metal HUD lines yet — run 'fwbench hud on' and relaunch the game"

    // MARK: - record / run

    static func record(_ args: [String]) throws {
        let o = try parseOptions(args, allowed: ["--pid", "--name", "--seconds", "--warmup", "--label", "--out"])
        if o["--pid"] != nil && o["--name"] != nil { throw UsageError("use --pid or --name, not both") }
        var follow = FollowRule.busiest
        var game: String?
        if let text = o["--pid"] {
            guard let pid = Int32(text), pid > 0 else { throw UsageError("--pid needs a process id") }
            follow = .pid(pid)
            game = ProcessNames.displayName(pid: pid).map(ProcessNames.exeName(fromArgv0:))
        } else if let name = o["--name"] {
            follow = .nameContains(name)
            game = name
        }
        let session = try Session(options: o, follow: follow, game: game)
        session.start(child: nil)
    }

    static func run(_ args: [String]) throws {
        guard let dash = args.firstIndex(of: "--"), dash + 1 < args.count else {
            throw UsageError("run needs -- CMD [ARGS...]")
        }
        let o = try parseOptions(Array(args[..<dash]), allowed: ["--seconds", "--warmup", "--label", "--out"])
        let command = Array(args[(dash + 1)...])
        let session = try Session(options: o, follow: .busiest,
                                  game: ProcessNames.exeName(fromArgv0: command[0]))
        session.start(child: command)
    }

    // MARK: - stack / ls

    static func stack(_ args: [String]) throws {
        guard args.count == 1, let pid = Int32(args[0]), pid > 0 else { throw UsageError("stack needs a PID") }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try enc.encode(StackDetector.detect(pid: pid)), as: UTF8.self))
    }

    static func ls(_ args: [String]) throws {
        let o = try parseOptions(args, allowed: ["--out"])
        let root = try runsRoot(o["--out"], create: false)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { $0.hasSuffix(".fwrun") }.sorted()
        guard !names.isEmpty else { print("no runs in \(root.path)"); return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        var rows: [[String]] = [["RUN", "GAME", "STACK", "DURATION"]]
        for name in names {
            let url = root.appendingPathComponent(name).appendingPathComponent("run.json")
            guard let data = try? Data(contentsOf: url), let info = try? dec.decode(RunInfo.self, from: data) else {
                rows.append([name, "?", "?", "unreadable run.json"])
                continue
            }
            let duration = info.end.map { formatDuration($0.timeIntervalSince(info.start)) } ?? "unfinished"
            rows.append([name, info.game.exe.isEmpty ? "-" : info.game.exe, describe(info.stack), duration])
        }
        let widths = (0..<4).map { c in rows.map { $0[c].count }.max() ?? 0 }
        for r in rows {
            print(r.enumerated().map { c, cell in c == 3 ? cell : cell.padding(toLength: widths[c], withPad: " ",
                                                                               startingAt: 0) }
                .joined(separator: "  "))
        }
    }

    static func describe(_ s: Stack) -> String {
        guard let runtime = s.runtime else { return "unknown" }
        var parts = [runtime + (s.runtimeVersion.map { " \($0)" } ?? "")]
        if let arch = s.wineArch { parts.append(arch) }
        if let t = s.translator { parts.append(t) }
        parts += s.graphics
        return parts.joined(separator: " / ")
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// `--out DIR`, else `~/Documents/FW Benchmark/runs`.
    static func runsRoot(_ out: String?, create: Bool) throws -> URL {
        let root: URL
        if let out {
            root = URL(fileURLWithPath: (out as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
            root = docs.appendingPathComponent("FW Benchmark/runs", isDirectory: true)
        }
        if create { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        return root
    }
}

/// One recording: telemetry timer, log stream, optional launched child, all handed back by one `Lease`.
private final class Session: @unchecked Sendable {
    let directory: URL
    let recorder: RunRecorder
    let stream: MetalHUDLogStream
    let seconds: Double?
    let queue = DispatchQueue(label: "fwbench.tick", qos: .utility)
    let timer: DispatchSourceTimer
    let done = DispatchSemaphore(value: 0)
    private(set) var lease: Lease!

    // Touched only on `queue`.
    private var ticks = 0
    private var hinted = false
    private var warnedStream = false
    private var detected: Set<Int32> = []

    // Launched child (`run`).
    private let childLock = NSLock()
    private var childPID: pid_t?
    private var childExited = false
    private var childName = ""
    /// Kept alive for the whole run: a deallocated handle closes the pipe.
    private var childStderr: FileHandle?

    init(options o: [String: String], follow: FollowRule, game: String?) throws {
        seconds = try number(o, "--seconds")
        if let seconds, seconds <= 0 { throw UsageError("--seconds needs a number > 0") }
        let warmup = try number(o, "--warmup") ?? 0
        let root = try RecordCommands.runsRoot(o["--out"], create: true)

        let sampler = TelemetrySampler()
        _ = sampler.sample()   // prime IOReport so the first row has power and utilisation

        let start = Date()
        var info = RunInfo(appVersion: RecordCommands.appVersion, machine: MachineInfo.current(),
                           game: .init(exe: game ?? ""),
                           settings: .init(powerMode: MachineInfo.powerMode(),
                                           onACAtStart: (try? SmartBatteryReader.read())?.externalConnected),
                           start: start)
        info.user.label = o["--label"] ?? ""
        directory = RunBundle.availableDirectory(in: root, start: start, game: game ?? "run")
        let writer = try RunBundleWriter(directory: directory, info: info)
        let recorder = RunRecorder(writer: writer, telemetry: sampler, startTime: start.timeIntervalSince1970,
                                   follow: follow, warmup: warmup)
        self.recorder = recorder
        stream = MetalHUDLogStream { recorder.hud($0) }
        timer = DispatchSource.makeTimerSource(queue: queue)
    }

    /// Runs until `--seconds`, the child's exit, or a signal (which exits from the lease's handler). Never returns.
    func start(child command: [String]?) -> Never {
        lease = Lease { [self] in stop() }
        lease.releaseOnSignals()   // also ignores SIGPIPE, which a launched child inherits (see `spawn`)

        do {
            if let command { try spawn(command) }
            try stream.start()
        } catch {
            printError("error: \(error)")
            lease.release()
            exit(1)
        }
        print("recording to \(directory.path) — Ctrl-C to stop")

        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { [self] in onTick() }
        timer.resume()

        done.wait()
        lease.release()
        exit(0)
    }

    /// Lease restore: runs once, on normal end or on a signal.
    private func stop() {
        timer.cancel()
        stream.stop()
        do { try recorder.finish() } catch { printError("error finishing run: \(error)") }
        print("saved \(directory.path)")
        let (pid, exited, name) = childLock.withLock { (childPID, childExited, childName) }
        if let pid, !exited { print("\(name) is still running (pid \(pid))") }
    }

    private func onTick() {
        let status: RecorderStatus?
        do { status = try recorder.tick(at: Date().timeIntervalSince1970) } catch {
            printError("error writing sample: \(error)")
            done.signal()
            return
        }
        guard let status else { return }
        ticks += 1

        if !warnedStream && !stream.isRunning {
            warnedStream = true
            printError("log stream stopped unexpectedly; still recording telemetry")
        }
        if ticks % 5 == 0 {
            let fps = status.fps.map { CSV.number($0, digits: 1) } ?? "--"
            let gpu = status.gpuW.map { CSV.number($0, digits: 1) } ?? "--"
            print("\(Int(status.elapsedS.rounded())) s  \(fps) fps  \(status.app ?? "-")  GPU \(gpu) W")
        }
        if ticks >= 5 && !hinted && !status.sawFPSSource {
            hinted = true
            printError(RecordCommands.noHUDHint)
        }
        if let pid = recorder.followedPID, !detected.contains(pid) {
            detected.insert(pid)
            let recorder = recorder
            DispatchQueue.global(qos: .utility).async { recorder.setStack(StackDetector.detect(pid: pid), for: pid) }
        }
        if let seconds, Double(ticks) >= seconds.rounded(.up) { done.signal() }
    }

    // MARK: - Launched child

    /// posix_spawn so the child gets its own process group (terminal Ctrl-C reaches only fwbench) and default
    /// handlers for the signals the lease ignores. SIGPIPE stays ignored so the child survives fwbench exiting
    /// while it still writes to the stderr pipe.
    private func spawn(_ command: [String]) throws {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw BenchError("pipe failed: errno \(errno)") }
        let (readFD, writeFD) = (fds[0], fds[1])

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
                                              | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attr, 0)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for s in [SIGINT, SIGTERM, SIGHUP, SIGQUIT] { sigaddset(&defaults, s) }
        posix_spawnattr_setsigdefault(&attr, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attr, &mask)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addinherit_np(&actions, 1)
        posix_spawn_file_actions_adddup2(&actions, writeFD, 2)

        var env = ProcessInfo.processInfo.environment
        for (k, v) in HUDCommands.environment { env[k] = v }
        let argv = command.map { strdup($0) } + [nil]
        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }

        var spawned: pid_t = 0
        let rc = posix_spawnp(&spawned, command[0], &actions, &attr, argv, envp)
        close(writeFD)
        guard rc == 0 else {
            close(readFD)
            throw BenchError("cannot launch \(command[0]): \(String(cString: strerror(rc)))")
        }
        let name = ProcessNames.exeName(fromArgv0: command[0])
        let pid = spawned
        childLock.withLock { childPID = pid; childName = name }
        print("launched \(name) (pid \(pid))")

        readStderr(readFD, pid: pid)
        Thread.detachNewThread { [self] in
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            childLock.withLock { childExited = true }
            print("\(name) exited")
            done.signal()
        }
    }

    /// HUD lines become frame times; everything else is passed through to our stderr.
    private func readStderr(_ fd: Int32, pid: pid_t) {
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        childLock.withLock { childStderr = handle }
        let splitter = LineBuffer()
        let recorder = recorder
        handle.readabilityHandler = { h in
            let chunk = h.availableData
            let lines = chunk.isEmpty ? splitter.flush() : splitter.add(chunk)
            if chunk.isEmpty { h.readabilityHandler = nil }
            let now = Date().timeIntervalSince1970
            var passthrough = Data()
            for line in lines {
                let text = String(decoding: line, as: UTF8.self)
                if let hud = MetalHUDLine.parse(text) {
                    recorder.frames(hud.frameTimes, pid: pid, at: now)
                } else {
                    passthrough.append(line)
                    passthrough.append(0x0A)
                }
            }
            if !passthrough.isEmpty { FileHandle.standardError.write(passthrough) }
        }
    }
}

/// Line splitter state for one pipe (readability handlers run serially).
private final class LineBuffer: @unchecked Sendable {
    private var buffer = Data()
    func add(_ chunk: Data) -> [Data] { MetalHUDLogStream.splitLines(&buffer, appending: chunk) }
    func flush() -> [Data] {
        defer { buffer = Data() }
        return buffer.isEmpty ? [] : [buffer]
    }
}
