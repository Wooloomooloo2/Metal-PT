import Testing
import Foundation
@testable import MPTCore

private final class FakeTelemetry: TelemetrySource, @unchecked Sendable {
    var calls = 0
    func sample() -> TelemetrySample {
        calls += 1
        return TelemetrySample(gpuW: 12.5, smcPower: ["PSTR": 30], fanRPM: [1200, 1300], batteryPct: 80, onAC: true)
    }
}

private final class GPUMemoryTelemetry: TelemetrySource, @unchecked Sendable {
    func sample() -> TelemetrySample {
        TelemetrySample(gpuMHz: 957.6, memPressure: "warn", swapUsedGB: 4.567, compressedGB: 1.234, pageoutsPerS: 12.4)
    }
}

@Suite struct RunRecorderTests {
    private func makeWriter() throws -> (RunBundleWriter, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fwrec-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("x.mptrun")
        let info = RunInfo(appVersion: "test", machine: .init(modelID: "Mac16,5", chip: "Apple M4 Max",
                                                               memoryGB: 64, osVersion: "26.0", osBuild: "x"),
                           game: .init(exe: "run"), start: Date(timeIntervalSince1970: 0))
        return (try RunBundleWriter(directory: dir, info: info), dir)
    }

    private func event(pid: Int32, frames: Int, at t: Double, path: String = "/x/Game") -> HUDEvent {
        HUDEvent(pid: pid, imagePath: path, time: t, line: MetalHUDLine(frames: frames, a: 0, b: 0, frameTimes: []))
    }

    @Test func recorderWritesFPSFromHUD() throws {
        let (w, dir) = try makeWriter()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let r = RunRecorder(writer: w, telemetry: FakeTelemetry(), startTime: 0, follow: .busiest, argv0: { _ in nil })
        r.hud(event(pid: 9, frames: 0, at: 0))
        r.hud(event(pid: 9, frames: 60, at: 1))
        try r.tick(at: 1.2)
        try r.finish(at: 2)
        let b = try RunBundle.load(dir)
        #expect(b.rows.count == 1)
        #expect(b.rows[0]["fps"] == "60.0")
        #expect(b.rows[0]["fps_pid"] == "9")
        #expect(b.rows[0]["elapsed_s"] == "1.2")
        #expect(b.info.fpsSource == "log")
    }

    @Test func recorderWithoutFPSStillWritesSamples() throws {
        let (w, dir) = try makeWriter()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let r = RunRecorder(writer: w, telemetry: FakeTelemetry(), startTime: 100, follow: .busiest, argv0: { _ in nil })
        for i in 1...3 { try r.tick(at: 100 + Double(i)) }
        try r.finish(at: 104)
        let b = try RunBundle.load(dir)
        #expect(b.rows.count == 3)
        #expect(b.rows.allSatisfy { $0["fps"] == "" && $0["fps_pid"] == "" && $0["fps_app"] == "" })
        #expect(b.rows[0]["gpu_w"] == "12.50")
        #expect(b.rows[0]["smc_PSTR_w"] == "30.00")
        #expect(b.rows[0]["fan1_rpm"] == "1300")
        #expect(b.rows[0]["on_ac"] == "1")
        #expect(b.rows[0]["battery_pct"] == "80")
        #expect(b.rows[0]["thermal_state"] == "nominal")
        #expect(b.info.fpsSource == "none")
        #expect(b.frames == nil)
    }

    @Test func frameTimesGiveP99AndMax() throws {
        let (w, dir) = try makeWriter()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let r = RunRecorder(writer: w, telemetry: FakeTelemetry(), startTime: 0, follow: .busiest, argv0: { _ in nil })
        var times = [FrameTime](repeating: FrameTime(intervalMs: 16.67, presentDelayMs: 1), count: 100)
        times.insert(FrameTime(intervalMs: 50, presentDelayMs: 1), at: 40)
        r.frames(times, pid: 5, at: 1.0)
        try r.tick(at: 1.0)
        try r.tick(at: 2.0)  // nothing new since the last tick → empty
        try r.finish(at: 2)
        let b = try RunBundle.load(dir)
        #expect(b.rows[0]["ft_max_ms"] == "50.00")
        #expect(b.rows[0]["ft_p99_ms"] == "16.67")
        #expect(b.rows[1]["ft_max_ms"] == "")
        #expect(b.frames?.count == 101)
        #expect(b.frames?.last?.tMs == 1000)
        #expect(b.info.fpsSource == "stderr")
    }

    @Test func finishIsIdempotentAndClosesFiles() throws {
        let (w, dir) = try makeWriter()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let r = RunRecorder(writer: w, telemetry: FakeTelemetry(), startTime: 1000, follow: .busiest, warmup: 5, argv0: { _ in nil })
        try r.tick(at: 1001)
        try r.finish(at: 1030)
        try r.finish(at: 1099)
        // Late arrivals after finish (log stream, timer) are dropped without error.
        r.hud(event(pid: 3, frames: 10, at: 1031))
        r.frames([FrameTime(intervalMs: 10, presentDelayMs: 1)], pid: 3, at: 1031)
        try r.tick(at: 1032)
        let b = try RunBundle.load(dir)
        #expect(b.rows.count == 1)
        #expect(b.frames == nil)
        #expect(b.info.end == Date(timeIntervalSince1970: 1030))
        #expect(b.info.steadyStartS == 5)
        #expect(b.info.steadyEndS == 30)
        let text = try String(contentsOf: dir.appendingPathComponent("samples.csv"), encoding: .utf8)
        #expect(text.hasSuffix("\n"))
    }

    @Test func followsPIDRuleAndNameRule() throws {
        let (w, dir) = try makeWriter()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let byName = RunRecorder(writer: w, telemetry: FakeTelemetry(), startTime: 0, follow: .nameContains("game"),
                                 argv0: { _ in nil })
        // The launcher is busier, but the name rule picks the game.
        byName.hud(event(pid: 1, frames: 0, at: 0, path: "/Apps/Launcher"))
        byName.hud(event(pid: 1, frames: 120, at: 1, path: "/Apps/Launcher"))
        byName.hud(event(pid: 2, frames: 0, at: 0, path: "/Apps/MyGame.exe"))
        byName.hud(event(pid: 2, frames: 30, at: 1, path: "/Apps/MyGame.exe"))
        #expect(byName.followedPID == 2)
        try byName.tick(at: 1.1)
        try byName.finish(at: 2)
        let b = try RunBundle.load(dir)
        #expect(b.rows[0]["fps"] == "30.0")
        #expect(b.rows[0]["fps_pid"] == "2")
        #expect(b.info.game.exe == "MyGame.exe")

        let (w2, dir2) = try makeWriter()
        defer { try? FileManager.default.removeItem(at: dir2.deletingLastPathComponent()) }
        let byPID = RunRecorder(writer: w2, telemetry: FakeTelemetry(), startTime: 0, follow: .pid(1), argv0: { _ in nil })
        #expect(byPID.followedPID == 1)
        try byPID.finish(at: 1)
    }

    // The --name rule picks among live matching processes: a restarted game (new PID) takes over from the old one.
    @Test func nameRulePrefersLiveProcess() throws {
        let (w, dir) = try makeWriter()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let r = RunRecorder(writer: w, telemetry: FakeTelemetry(), startTime: 0, follow: .nameContains("game"),
                            argv0: { _ in nil })
        for t in 0...10 { r.hud(event(pid: 1, frames: t * 600, at: Double(t), path: "/Apps/Game")) }
        r.hud(event(pid: 2, frames: 0, at: 14, path: "/Apps/Game"))
        r.hud(event(pid: 2, frames: 60, at: 15, path: "/Apps/Game"))
        #expect(r.followedPID == 2)
        try r.tick(at: 15.2)
        try r.finish(at: 16)
        let b = try RunBundle.load(dir)
        #expect(b.rows[0]["fps"] == "60.0")
        #expect(b.rows[0]["fps_pid"] == "2")
    }

    @Test func nameRuleMatchesWindowsArgv0() throws {
        let (w, dir) = try makeWriter()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let argv0: [Int32: String] = [10: #"Z:\Games\HZD\HorizonZeroDawnRemastered.exe"#, 11: "/Apps/Steam"]
        let r = RunRecorder(writer: w, telemetry: FakeTelemetry(), startTime: 0, follow: .nameContains("HORIZON"),
                            argv0: { argv0[$0] })
        r.hud(event(pid: 11, frames: 0, at: 0, path: "/Apps/Steam"))
        r.hud(event(pid: 11, frames: 500, at: 1, path: "/Apps/Steam"))
        r.hud(event(pid: 10, frames: 0, at: 0, path: "/Apps/wine64-preloader"))
        r.hud(event(pid: 10, frames: 59, at: 1, path: "/Apps/wine64-preloader"))
        try r.tick(at: 1.5)
        try r.finish(at: 2)
        let b = try RunBundle.load(dir)
        #expect(b.rows[0]["fps_pid"] == "10")
        #expect(b.rows[0]["fps_app"] == "HorizonZeroDawnRemastered.exe")
        #expect(b.info.game.exe == "HorizonZeroDawnRemastered.exe")
        #expect(r.gameExe == "HorizonZeroDawnRemastered.exe")
        #expect(b.info.warnings.isEmpty)
    }

    @Test func unidentifiedGameLeavesExeEmptyWithWarning() throws {
        let (w, dir) = try makeWriter()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let r = RunRecorder(writer: w, telemetry: FakeTelemetry(), startTime: 0, follow: .nameContains("hzd"),
                            argv0: { _ in nil })
        r.hud(event(pid: 3, frames: 0, at: 0, path: "/Apps/Other"))
        try r.finish(at: 1)
        let b = try RunBundle.load(dir)
        #expect(b.info.game.exe == "")
        #expect(b.info.warnings == ["game process never identified"])
        #expect(r.gameExe == nil)
    }

    @Test func framesWriteFailureBecomesWarning() throws {
        let (w, dir) = try makeWriter()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        // A directory where frames.csv should go makes every frames write fail.
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("frames.csv"),
                                                withIntermediateDirectories: false)
        let r = RunRecorder(writer: w, telemetry: FakeTelemetry(), startTime: 0, follow: .pid(4), argv0: { _ in "game" })
        r.frames([FrameTime(intervalMs: 16, presentDelayMs: 1)], pid: 4, at: 1)
        r.frames([FrameTime(intervalMs: 16, presentDelayMs: 1)], pid: 4, at: 2)
        try r.finish(at: 3)
        let b = try RunBundle.load(dir)
        let frameWarnings = b.info.warnings.filter { $0.hasPrefix("frames.csv write failed") }
        #expect(frameWarnings.count == 1)
    }

    // MARK: - Mixed stderr frames (several Metal processes under `mpt run`)

    private func frameBatch(_ n: Int) -> [FrameTime] {
        [FrameTime](repeating: FrameTime(intervalMs: 1000 / Double(max(n, 1)), presentDelayMs: 1), count: n)
    }

    /// Log: pid 9 at 60 fps. Stderr: `stderrPerSecond[k]` frames in second k+1. Pid 10 (a launcher) gains 5 frames
    /// in second k+1 when `extraGains[k]`; it is in the launched process group when `extraInGroup`. Returns the
    /// run's warnings.
    private func mixedRun(stderrPerSecond: [Int], extraGains: [Bool] = [], extraInGroup: Bool = true,
                          warmup: Double = 0, followedInGroup: Bool = true) throws -> [String] {
        let (w, dir) = try makeWriter()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let r = RunRecorder(writer: w, telemetry: FakeTelemetry(), startTime: 0, follow: .busiest, warmup: warmup,
                            argv0: { _ in "g" }, inLaunchedGroup: { ($0 == 9 && followedInGroup) || ($0 == 10 && extraInGroup) })
        r.hud(event(pid: 9, frames: 0, at: 0))
        var extra = 0
        if !extraGains.isEmpty { r.hud(event(pid: 10, frames: 0, at: 0, path: "/x/Launcher")) }
        for (k, n) in stderrPerSecond.enumerated() {
            let t = Double(k + 1)
            r.hud(event(pid: 9, frames: 60 * (k + 1), at: t - 0.1))
            if k < extraGains.count {
                if extraGains[k] { extra += 5 }
                r.hud(event(pid: 10, frames: extra, at: t - 0.1, path: "/x/Launcher"))
            }
            r.frames(frameBatch(n), pid: 77, at: t - 0.05)
            try r.tick(at: t)
        }
        try r.finish(at: Double(stderrPerSecond.count + 1))
        return try RunBundle.load(dir).info.warnings
    }

    @Test func stderrFramesAboveLogFPSForThreeSecondsAreFlagged() throws {
        let w = try mixedRun(stderrPerSecond: [60, 120, 120, 120, 60, 120, 120, 120])
        #expect(w.filter { $0 == RunRecorder.mixedFramesWarning }.count == 1)
    }

    @Test func briefOrSmallStderrExcessIsNotFlagged() throws {
        // Two seconds over, then back; and 10 % over for a long time.
        #expect(try mixedRun(stderrPerSecond: [60, 120, 120, 60, 120, 120, 60]).isEmpty)
        #expect(try mixedRun(stderrPerSecond: [66, 66, 66, 66, 66]).isEmpty)
    }

    // An unrelated `hud on` app at 60 fps is followed while the launched game renders 120 fps to stderr: the log
    // FPS is not the launched process's, so the excess rule does not apply.
    @Test func excessRuleIgnoresFollowedProcessOutsideLaunchedGroup() throws {
        #expect(try mixedRun(stderrPerSecond: [120, 120, 120, 120], followedInGroup: false).isEmpty)
        #expect(try mixedRun(stderrPerSecond: [120, 120, 120, 120]) == [RunRecorder.mixedFramesWarning])
    }

    @Test func excessRuleIgnoresWarmup() throws {
        // Excess only in the warm-up seconds (elapsed 1…4 with warm-up 4), steady after.
        #expect(try mixedRun(stderrPerSecond: [120, 120, 120, 120, 60, 60, 60], warmup: 4).isEmpty)
        // Straddling: two excess ticks in warm-up, two in the steady window: never 3 steady in a row.
        #expect(try mixedRun(stderrPerSecond: [120, 120, 120, 120, 60], warmup: 2).isEmpty)
    }

    @Test func threeTicksOfTwoInGroupProcessesAreFlagged() throws {
        let w = try mixedRun(stderrPerSecond: [60, 60, 60, 60, 60], extraGains: [false, true, true, true, false])
        #expect(w == [RunRecorder.mixedFramesWarning])
    }

    @Test func twoTickInGroupOverlapInSteadyWindowIsNotFlagged() throws {
        #expect(try mixedRun(stderrPerSecond: [60, 60, 60, 60, 60, 60],
                             extraGains: [false, false, true, true, false, false], warmup: 1).isEmpty)
    }

    @Test func oneTickInGroupOverlapDuringWarmupIsNotFlagged() throws {
        #expect(try mixedRun(stderrPerSecond: [60, 60, 60, 60, 60],
                             extraGains: [false, true, false, false, false], warmup: 3).isEmpty)
    }

    @Test func unrelatedProcessGainingFramesIsIgnored() throws {
        #expect(try mixedRun(stderrPerSecond: [60, 60, 60, 60, 60], extraGains: Array(repeating: true, count: 5),
                             extraInGroup: false).isEmpty)
    }

    @Test func secondLogProcessWithoutStderrFramesIsNotFlagged() throws {
        #expect(try mixedRun(stderrPerSecond: [0, 0, 0, 0], extraGains: [true, true, true, true]).isEmpty)
    }

    @Test func stackIsWrittenForFollowedPID() throws {
        let (w, dir) = try makeWriter()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let r = RunRecorder(writer: w, telemetry: FakeTelemetry(), startTime: 0, follow: .busiest, argv0: { _ in nil })
        r.hud(event(pid: 4, frames: 0, at: 0))
        r.setStack(Stack(runtime: "Protium", graphics: ["DXMT"]), for: 4)
        r.setStack(Stack(runtime: "CrossOver"), for: 99)   // not followed: ignored
        try r.finish(at: 1)
        let b = try RunBundle.load(dir)
        #expect(b.info.stack.runtime == "Protium")
    }
    @Test func gpuClockAndMemoryColumnsRoundTrip() throws {
        let tail = ["gpu_mhz", "mem_pressure", "swap_used_gb", "compressed_gb", "pageouts_per_s"]
        #expect(Array(SampleColumns.all.suffix(5)) == tail)
        #expect(Array(SampleColumns.all.prefix(31)).last == "thermal_state")
        let (w, dir) = try makeWriter()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let r = RunRecorder(writer: w, telemetry: GPUMemoryTelemetry(), startTime: 0, follow: .busiest,
                            argv0: { _ in nil })
        try r.tick(at: 1)
        try r.finish(at: 2)
        let b = try RunBundle.load(dir)
        #expect(b.rows[0]["gpu_mhz"] == "958")
        #expect(b.rows[0]["mem_pressure"] == "warn")
        #expect(b.rows[0]["swap_used_gb"] == "4.57")
        #expect(b.rows[0]["compressed_gb"] == "1.23")
        #expect(b.rows[0]["pageouts_per_s"] == "12")
        #expect(RunBundleWriter.stringColumns.contains("mem_pressure"))
    }

    /// One list of free-text columns: scrubbed by the writer and never summarised as numbers.
    @Test func textColumnsAreSharedByWriterAndSummary() {
        #expect(SampleColumns.text == ["fps_app", "thermal_state", "mem_pressure"])
        #expect(RunBundleWriter.stringColumns == SampleColumns.text)
        #expect(RunSummary.skipColumns.isSuperset(of: SampleColumns.text))
        #expect(SampleColumns.text.isSubset(of: Set(SampleColumns.all)))
    }

    @Test func emptyGPUClockAndMemoryCellsStayEmpty() throws {
        let (w, dir) = try makeWriter()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let r = RunRecorder(writer: w, telemetry: FakeTelemetry(), startTime: 0, follow: .busiest, argv0: { _ in nil })
        try r.tick(at: 1)
        try r.finish(at: 2)
        let b = try RunBundle.load(dir)
        for c in ["gpu_mhz", "mem_pressure", "swap_used_gb", "compressed_gb", "pageouts_per_s"] {
            #expect(b.rows[0][c] == "")
        }
    }

    @Test func gpuMaxMHzIsOptionalInRunJSON() throws {
        let old = #"{"schema":1,"machine":{"modelID":"Mac16,5","chip":"Apple M4 Max","memoryGB":48,"#
            + #""osVersion":"27.0","osBuild":"x"},"game":{"exe":"g"},"start":0}"#
        let decoder = JSONDecoder()
        let info = try decoder.decode(RunInfo.self, from: Data(old.utf8))
        #expect(info.machine.gpuMaxMHz == nil)
        var m = info.machine
        m.gpuMaxMHz = 1578
        let back = try decoder.decode(RunInfo.Machine.self, from: try JSONEncoder().encode(m))
        #expect(back.gpuMaxMHz == 1578)
    }
}

@Suite struct MachineInfoTests {
    @Test func displaySettingsTreatZeroAsUnknown() {
        let s = MachineInfo.displaySettings(width: 1728, height: 1117, refreshHz: 120, base: .init(powerMode: "high"))
        #expect(s.displayWidth == 1728 && s.displayHeight == 1117 && s.refreshHz == 120)
        #expect(s.powerMode == "high")
        let unknown = MachineInfo.displaySettings(width: 0, height: 0, refreshHz: 0, base: .init())
        #expect(unknown.displayWidth == nil && unknown.displayHeight == nil && unknown.refreshHz == nil)
    }

    @Test func parsesPowerMode() {
        #expect(MachineInfo.powerMode(fromPMSet: "System-wide power settings:\n sleep  1\n powermode            0\n") == "automatic")
        #expect(MachineInfo.powerMode(fromPMSet: " powermode 2") == "high")
        #expect(MachineInfo.powerMode(fromPMSet: " sleep 1\n") == nil)
    }
}

@Suite struct TelemetrySamplerTests {
    @Test func maxTemperatureUsesDieSensors() {
        let r = [TemperatureReading(name: "PMU tcal", celsius: 51.9), TemperatureReading(name: "PMU tdie2", celsius: 41.0),
                 TemperatureReading(name: "PMU tdie8", celsius: 43.5), TemperatureReading(name: "gas gauge", celsius: 60)]
        #expect(TelemetrySampler.maxTemperature(r) == 43.5)
    }

    @Test func maxTemperatureFallsBackWithoutDieSensors() {
        let r = [TemperatureReading(name: "PMU tcal", celsius: 51.9), TemperatureReading(name: "PMU tcalx", celsius: 30),
                 TemperatureReading(name: "NAND", celsius: 38)]
        #expect(TelemetrySampler.maxTemperature(r) == 38)
        #expect(TelemetrySampler.maxTemperature([TemperatureReading(name: "PMU tcal", celsius: 51.9)]) == nil)
        #expect(TelemetrySampler.isDieSensor("PMU tdie10"))
        #expect(!TelemetrySampler.isDieSensor("PMU tcal"))
    }

}
