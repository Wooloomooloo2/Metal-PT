import Foundation
import FWCore

/// One recording: telemetry timer, log stream, optional launched child, all handed back by one `Lease`.
final class Session: @unchecked Sendable {
    private let options: [String: String]
    private let follow: FollowRule
    /// Directory-name seed; nil means the placeholder "run" (renamed at finish once the game is known).
    private let game: String?
    /// The seed is only a guess (`run`'s command[0], often a launcher or wine): rename at finish to the identified
    /// exe as with the placeholder.
    private let seedIsGuess: Bool
    private let seconds: Double?
    private let warmup: Double
    private let root: URL
    private let sampler: TelemetrySampler
    private let machine: RunInfo.Machine
    private let settings: RunInfo.Settings

    private let queue = DispatchQueue(label: "fwbench.tick", qos: .utility)
    private let timer: DispatchSourceTimer
    private let done = DispatchSemaphore(value: 0)
    private let detections = DispatchGroup()
    private var lease: Lease!

    // Set up in `start` under `lock`; `stop` may run (from a signal) before they exist.
    private let lock = NSLock()
    private var startDate = Date()
    private var directory: URL?
    private var recorder: RunRecorder?
    private var stream: MetalHUDLogStream?

    // Touched only on `queue`.
    private var ticks = 0
    private var hinted = false
    private var warnedStream = false
    private var detected: Set<Int32> = []

    // Launched child (`run`).
    private var childPID: pid_t?
    private var childExited = false
    private var childName = ""
    /// Kept alive for the whole run: a deallocated handle closes the pipe.
    private var childStderr: FileHandle?
    private let stderrEOF = DispatchSemaphore(value: 0)

    /// Validates options and does the slow reads (pmset, battery, machine) before the run's start time is taken.
    init(options o: [String: String], follow: FollowRule, game: String?, seedIsGuess: Bool = false) throws {
        options = o
        self.follow = follow
        self.game = game
        self.seedIsGuess = seedIsGuess
        seconds = try number(o, "--seconds")
        if let seconds, seconds <= 0 { throw UsageError("--seconds needs a number > 0") }
        warmup = try number(o, "--warmup") ?? 0
        if let seconds, warmup >= seconds {
            throw UsageError("--warmup (\(CSV.number(warmup, digits: 1)) s) must be shorter than --seconds "
                             + "(\(CSV.number(seconds, digits: 1)) s)")
        }
        root = try RecordCommands.runsRoot(o["--out"], create: true)
        sampler = TelemetrySampler()
        _ = sampler.sample()   // prime IOReport so the first row has power and utilisation
        machine = MachineInfo.current()
        settings = MachineInfo.withMainDisplay(.init(powerMode: MachineInfo.powerMode(),
                                                      onACAtStart: (try? SmartBatteryReader.read())?.externalConnected))
        timer = DispatchSource.makeTimerSource(queue: queue)
    }

    /// Runs until `--seconds`, the child's exit, or a signal (which exits from the lease's handler). Never returns.
    func start(child command: [String]?) -> Never {
        lease = Lease { [self] in stop() }
        lease.releaseOnSignals()   // before anything is created; also ignores SIGPIPE (inherited by a child)

        do {
            try lock.withLock {
                startDate = Date()
                var info = RunInfo(appVersion: RecordCommands.appVersion, machine: machine, game: .init(exe: ""),
                                   settings: settings, start: startDate)
                info.user.label = options["--label"] ?? ""
                info.user.gameSettings = options["--settings"] ?? ""
                info.user.notes = options["--notes"] ?? ""
                let dir = RunBundle.availableDirectory(in: root, start: startDate, game: game ?? "run")
                let writer = try RunBundleWriter(directory: dir, info: info)
                let recorder = RunRecorder(writer: writer, telemetry: sampler,
                                           startTime: startDate.timeIntervalSince1970, follow: follow, warmup: warmup)
                directory = dir
                self.recorder = recorder
                stream = MetalHUDLogStream { recorder.hud($0) }
            }
            if let command { try spawn(command) }
            try stream?.start()
        } catch {
            printError("error: \(error)")
            lease.release()
            exit(1)
        }
        print("recording to \(directory?.path ?? "?") — Ctrl-C to stop")

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
        let (stream, recorder, dir, start) = lock.withLock { (self.stream, self.recorder, directory, startDate) }
        stream?.stop()
        guard let recorder, var dir else { return }
        // Let a stack detection that is under way land in run.json (lsof is bounded at 5 s; wait at most 2).
        _ = detections.wait(timeout: .now() + 2)
        do { try recorder.finish() } catch { printError("error finishing run: \(error)") }
        if game == nil || seedIsGuess, let exe = recorder.gameExe {
            do { dir = try RunBundle.rename(dir, start: start, game: exe) } catch {
                printError("could not rename the run folder: \(error)")
            }
        }
        print("saved \(dir.path)")
        do { print("summary \(try SummaryReport.write(bundleAt: dir).path)") } catch {
            printError("could not write the summary: \(error)")
        }
        let (pid, exited, name) = lock.withLock { (childPID, childExited, childName) }
        if let pid, !exited { print("\(name) is still running (pid \(pid))") }
    }

    private func onTick() {
        guard let (recorder, stream) = lock.withLock({ self.recorder.map { ($0, self.stream) } }) else { return }
        let status: RecorderStatus?
        do { status = try recorder.tick(at: Date().timeIntervalSince1970) } catch {
            printError("error writing sample: \(error)")
            done.signal()
            return
        }
        guard let status else { return }
        ticks += 1

        if !warnedStream && !(stream?.isRunning ?? false) {
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
            DispatchQueue.global(qos: .utility).async(group: detections) {
                recorder.setStack(StackDetector.detect(pid: pid), for: pid)
            }
        }
        if let seconds, Double(ticks) >= seconds.rounded(.up) { done.signal() }
    }

    // MARK: - Launched child

    /// posix_spawn so the child gets its own process group (terminal Ctrl-C reaches only fwbench) and default
    /// handlers for the signals the lease ignores.
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
        // SIGPIPE is deliberately NOT reset: the lease ignores it and the game inherits that, so the game survives
        // writing to its stderr pipe after fwbench has exited (Ctrl-C or --seconds leave it running).
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
        lock.withLock { childPID = pid; childName = name }
        print("launched \(name) (pid \(pid))")

        readStderr(readFD, pid: pid)
        Thread.detachNewThread { [self] in
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            lock.withLock { childExited = true }
            // Its last HUD lines may still be in the pipe: wait for EOF (a grandchild can hold the pipe open, so
            // at most 1 s).
            _ = stderrEOF.wait(timeout: .now() + 1)
            print("\(name) exited")
            done.signal()
        }
    }

    /// HUD lines become frame times; everything else is passed through to our stderr.
    private func readStderr(_ fd: Int32, pid: pid_t) {
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        lock.withLock { childStderr = handle }
        let splitter = LineBuffer()
        let recorder = lock.withLock { self.recorder }
        let eof = stderrEOF
        handle.readabilityHandler = { h in
            let chunk = h.availableData
            let lines = chunk.isEmpty ? splitter.flush() : splitter.add(chunk)
            let now = Date().timeIntervalSince1970
            var passthrough = Data()
            for line in lines {
                let text = String(decoding: line, as: UTF8.self)
                if let hud = MetalHUDLine.parse(text) {
                    recorder?.frames(hud.frameTimes, pid: pid, at: now)
                } else {
                    passthrough.append(line)
                    passthrough.append(0x0A)
                }
            }
            if !passthrough.isEmpty { FileHandle.standardError.write(passthrough) }
            if chunk.isEmpty {
                h.readabilityHandler = nil
                eof.signal()
            }
        }
    }
}

/// Line splitter state for one pipe (readability handlers run serially).
final class LineBuffer: @unchecked Sendable {
    private var buffer = Data()
    func add(_ chunk: Data) -> [Data] { MetalHUDLogStream.splitLines(&buffer, appending: chunk) }
    func flush() -> [Data] {
        defer { buffer = Data() }
        return buffer.isEmpty ? [] : [buffer]
    }
}
