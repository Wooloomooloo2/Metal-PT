import Testing
import Foundation
@testable import FWCore

@Suite struct RunSummaryTests {
    private func bundle(rows: [[String: String]], frames: [TimedFrame]? = nil,
                        steadyStart: Double? = nil, steadyEnd: Double? = nil) -> RunBundle {
        let info = RunInfo(appVersion: "0.1", machine: .init(modelID: "Mac15,6", chip: "M3 Pro", memoryGB: 36,
                                                             osVersion: "15.1", osBuild: "24B83"),
                           game: .init(exe: "g.exe"), start: Date(timeIntervalSince1970: 1_800_000_000),
                           steadyStartS: steadyStart, steadyEndS: steadyEnd, fpsSource: "log")
        return RunBundle(url: URL(fileURLWithPath: "/x.fwrun"), info: info, rows: rows, frames: frames, warnings: [])
    }

    private func rows(_ n: Int, _ f: (Int) -> [String: String]) -> [[String: String]] {
        (0..<n).map { i in var r = f(i); r["elapsed_s"] = "\(i)"; return r }
    }

    @Test func trimsWarmupAndMenus() {
        let r = rows(80) { i in
            i < 5 ? [:] : ["fps": (i == 40 || i == 41) ? "300" : "60", "fps_app": "game"]
        }
        let s = RunSummary(bundle(rows: r))
        #expect(s.steadySeconds == Array(15..<80).filter { $0 != 40 && $0 != 41 })
        #expect(s.medianFPS == 60)
    }

    @Test func usesExplicitWindow() {
        let r = rows(30) { _ in ["fps": "50", "fps_app": "game"] }
        let s = RunSummary(bundle(rows: r, steadyStart: 5, steadyEnd: 9))
        #expect(s.steadySeconds == [5, 6, 7, 8, 9])
    }

    @Test func zeroSteadyStartFallsBackToAutomaticRules() {
        let r = rows(80) { i in ["fps": i == 40 ? "300" : "60", "fps_app": "game"] }
        let s = RunSummary(bundle(rows: r, steadyStart: 0, steadyEnd: 70))
        #expect(!s.steadySeconds.contains(5))
        #expect(!s.steadySeconds.contains(40))
        #expect(s.steadySeconds.first == 10)
    }

    @Test func lowsFromFrames() {
        let r = rows(60) { _ in ["fps": "60", "fps_app": "game"] }
        var frames = (0..<1000).map { TimedFrame(tMs: 12_000 + Double($0) * 16.67, intervalMs: 16.67, presentDelayMs: 1) }
        frames += (0..<20).map { TimedFrame(tMs: 30_000 + Double($0), intervalMs: 50, presentDelayMs: 1) }
        frames.append(TimedFrame(tMs: 500, intervalMs: 999, presentDelayMs: 1)) // outside window
        let s = RunSummary(bundle(rows: r, frames: frames))
        #expect(s.low1 == 20.0)
        #expect(s.low01 == 20.0)
        #expect(RunSummary(bundle(rows: r)).low1 == nil)
    }

    @Test func mixedFrameTimesHideLows() {
        let r = rows(60) { _ in ["fps": "60", "fps_app": "game"] }
        let frames = (0..<1000).map { TimedFrame(tMs: 12_000 + Double($0) * 16.67, intervalMs: 16.67, presentDelayMs: 1) }
        var b = bundle(rows: r, frames: frames)
        #expect(!RunSummary(b).lowsMixed)
        var info = b.info
        info.warnings = [RunRecorder.mixedFramesWarning]
        b = RunBundle(url: b.url, info: info, rows: b.rows, frames: b.frames, warnings: info.warnings)
        let s = RunSummary(b)
        #expect(s.lowsMixed)
        #expect(s.low1 == nil && s.low01 == nil)
        #expect(s.medianFPS == 60)
    }

    @Test func fpsShorterThanWarmupTrimDoesNotCrash() {
        let r = rows(10) { _ in ["fps": "60", "fps_app": "game"] }
        let s = RunSummary(bundle(rows: r))
        #expect(s.steadySeconds.isEmpty)
        #expect(s.medianFPS == nil)
    }

    @Test func summaryWithoutFPS() {
        let r = rows(70) { _ in ["gpu_w": "4.0"] }
        let s = RunSummary(bundle(rows: r))
        #expect(s.notes.contains("no FPS source"))
        #expect(s.medianFPS == nil)
        #expect(s.steadySeconds.count == 70)
        #expect(s.stats["gpu_w"]?.mean == 4.0)
        #expect(s.powerColumn == "gpu_w")
    }

    @Test func fpsPerWattUsesSystemPower() {
        let r = rows(80) { _ in ["fps": "60", "fps_app": "game", "gpu_w": "10", "smc_PSTR_w": "30"] }
        let s = RunSummary(bundle(rows: r))
        #expect(s.powerColumn == "smc_PSTR_w")
        #expect(s.fpsPerWatt == 2.0)
    }

    @Test func notesShortBatteryThermal() {
        let r = rows(20) { i in
            ["fps": "60", "fps_app": "game", "on_ac": i == 3 ? "0" : "1",
             "thermal_state": i < 4 ? "nominal" : (i < 6 ? "fair" : "serious")]
        }
        let s = RunSummary(bundle(rows: r, steadyStart: 1, steadyEnd: 19))
        #expect(s.notes.contains("short run (19 s steady)"))
        #expect(s.notes.contains("on battery"))
        #expect(s.notes.contains("thermal pressure: fair for 2 s"))
        #expect(s.notes.contains("thermal pressure: serious for 14 s"))
    }

    @Test func statsPercentileAndMedian() {
        let r = rows(4) { i in ["gpu_w": "\(i + 1)"] }
        let st = RunSummary(bundle(rows: r)).stats["gpu_w"]
        #expect(st?.median == 2.5)
        #expect(st?.p5 == 1)
        #expect(st?.max == 4)
        #expect(st?.count == 4)
    }

    @Test func emptySteadySetIsNotNoFPSSource() {
        let r = rows(30) { _ in ["fps": "60", "fps_app": "game"] }
        let s = RunSummary(bundle(rows: r, steadyStart: 100, steadyEnd: 200))
        #expect(s.steadySeconds.isEmpty)
        #expect(!s.notes.contains("no FPS source"))
        #expect(s.notes.contains("no steady FPS seconds"))
        #expect(s.notes.contains("short run (0 s steady)"))
    }

    @Test func menuMedianIsComputedAfterWarmupTrim() {
        let r = rows(18) { i in
            ["fps": i < 10 ? "200" : (i == 12 ? "300" : "60"), "fps_app": "game"]
        }
        let s = RunSummary(bundle(rows: r))
        #expect(s.steadySeconds == [10, 11, 13, 14, 15, 16, 17])
    }
}
