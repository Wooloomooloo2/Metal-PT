import Testing
import Foundation
@testable import FWCore

@Suite struct CompareTests {
    private func info(game: String = "Game.exe", stack: Stack = Stack(), onAC: Bool? = true,
                      build: String = "24B83", label: String = "", fpsSource: String = "log") -> RunInfo {
        var i = RunInfo(appVersion: "0.1", machine: .init(modelID: "Mac15,6", chip: "M3 Pro", memoryGB: 36,
                                                          osVersion: "15.1", osBuild: build),
                        game: .init(exe: game), stack: stack, settings: .init(powerMode: "automatic", onACAtStart: onAC),
                        start: Date(timeIntervalSince1970: 1_800_000_000),
                        end: Date(timeIntervalSince1970: 1_800_000_100), fpsSource: fpsSource)
        i.user.label = label
        return i
    }

    private func bundle(_ dir: String, _ info: RunInfo, fps: Double, seconds: Int = 90,
                        power: String = "smc_PSTR_w", watts: Double = 30) -> RunBundle {
        let rows: [[String: String]] = (0..<seconds).map { i in
            ["elapsed_s": "\(i)", "fps": CSV.number(fps, digits: 1), "fps_app": info.game.exe, "on_ac": "1",
             power: CSV.number(watts, digits: 2)]
        }
        return RunBundle(url: URL(fileURLWithPath: "/runs/\(dir)"), info: info, rows: rows, frames: nil, warnings: [])
    }

    private func pair(_ b: RunBundle) -> (RunBundle, RunSummary) { (b, RunSummary(b)) }

    @Test func differencesOnlyListsChanges() {
        let a = info(stack: Stack(runtime: "Protium", graphics: ["DXMT"]))
        let b = info(stack: Stack(runtime: "CrossOver", graphics: ["D3DMetal"]))
        let d = CompareReport.differences([a, b])
        #expect(d.map(\.field) == ["runtime", "graphics"])
        #expect(d.first?.values == ["Protium", "CrossOver"])
        #expect(d.last?.values == ["DXMT", "D3DMetal"])
    }

    @Test func differencesShowDashForEmptyAndJoinGraphics() {
        let a = info(stack: Stack(runtime: "Protium", graphics: ["DXMT", "vkd3d"]))
        let b = info(stack: Stack(runtime: "Protium"), label: "high")
        let d = CompareReport.differences([a, b])
        #expect(d.map(\.field) == ["graphics", "label"])
        #expect(d[0].values == ["DXMT + vkd3d", "—"])
        #expect(d[1].values == ["—", "high"])
    }

    @Test func warnsOnACvsBattery() {
        let w = CompareReport.warnings([(info(onAC: true), RunSummary(bundle("a", info(), fps: 60))),
                                        (info(onAC: false), RunSummary(bundle("b", info(), fps: 60)))])
        #expect(w.contains(CompareReport.acBatteryWarning))
        let same = CompareReport.warnings([(info(), RunSummary(bundle("a", info(), fps: 60))),
                                           (info(), RunSummary(bundle("b", info(), fps: 60)))])
        #expect(same.isEmpty)
    }

    @Test func warnsOnDifferentGames() {
        let w = CompareReport.warnings([(info(game: "A.exe"), RunSummary(bundle("a", info(game: "A.exe"), fps: 60))),
                                        (info(game: "B.exe"), RunSummary(bundle("b", info(game: "B.exe"), fps: 60)))])
        #expect(w.contains("different games: A.exe, B.exe"))
    }

    @Test func warnsOnShortAndUnevenSteadyTimes() {
        let w = CompareReport.warnings([(info(), RunSummary(bundle("a", info(), fps: 60, seconds: 200))),
                                        (info(), RunSummary(bundle("b", info(), fps: 60, seconds: 50)))])
        #expect(w.contains { $0.hasPrefix("steady times differ more than 2×") })
        #expect(w.contains { $0.hasPrefix("short steady time (under 60 s): run 2") })
    }

    @Test func warnsOnMachineBuildFPSSourceAndPower() {
        var other = info(build: "24C101", fpsSource: "stderr")
        other.machine.chip = "M4 Max"
        let w = CompareReport.warnings([
            (info(), RunSummary(bundle("a", info(), fps: 60))),
            (other, RunSummary(bundle("b", other, fps: 60, power: "gpu_w", watts: 5))),
        ])
        #expect(w.contains("different machines"))
        #expect(w.contains("different macOS builds"))
        #expect(w.contains("mixed FPS sources — 1 % lows only for runs launched with fwbench run"))
        #expect(w.contains(CompareReport.powerMismatchWarning))
    }

    @Test func gainAgainstBaseline() {
        #expect(CompareReport.gain(55, baseline: 50) == "+10.0 %")
        #expect(CompareReport.gain(45.1, baseline: 50) == "\u{2212}9.8 %")
        #expect(CompareReport.gain(50, baseline: 50) == "0.0 %")
        #expect(CompareReport.gain(nil, baseline: 50) == "—")
        #expect(CompareReport.gain(50, baseline: 0) == "—")
    }

    @Test func projectRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = CompareProject(name: "Elden Ring: DXMT vs D3DMetal", baseline: 1,
                               runs: [.init(bundle: "20270115-080000-eldenring-exe.fwrun", name: "Protium DXMT"),
                                      .init(bundle: "/Volumes/x/run.fwrun", name: "")])
        let url = dir.appendingPathComponent(CompareProject.fileName(for: p.name))
        #expect(url.lastPathComponent == "elden-ring-dxmt-vs-d3dmetal.json")
        try p.save(to: url)
        let q = try CompareProject.load(url)
        #expect(q.name == p.name)
        #expect(q.baseline == 1)
        #expect(q.runs.map(\.bundle) == p.runs.map(\.bundle))
        #expect(q.runs.map(\.name) == p.runs.map(\.name))
    }

    @Test func reportComparesAgainstBaselineAndHighlightsDifferences() {
        let a = bundle("20270115-080000-game-exe.fwrun", info(stack: Stack(runtime: "Protium", graphics: ["DXMT"])),
                       fps: 60, watts: 30)
        let b = bundle("20270115-090000-game-exe.fwrun",
                       info(stack: Stack(runtime: "CrossOver", graphics: ["D3DMetal"]), label: "<b>&"),
                       fps: 54.1, watts: 61.2)
        let project = CompareProject(name: "Test <proj>", baseline: 0,
                                     runs: [.init(bundle: a.url.lastPathComponent, name: ""),
                                            .init(bundle: b.url.lastPathComponent, name: "")])
        let out = CompareReport.html(project: project, runs: [pair(a), pair(b)])
        #expect(out.contains("Test &lt;proj&gt;"))
        #expect(out.contains("&lt;b&gt;&amp;"))
        #expect(!out.contains("<b>&"))
        #expect(out.contains("CrossOver D3DMetal: 54.1 fps median (\u{2212}9.8 %), 1 % low —, 61.2 W"))
        #expect(out.contains("class=\"diff\""))
        #expect(out.contains("Same in every run:"))
        #expect(!out.lowercased().contains("<script"))
        #expect(!out.contains("http://") && !out.contains("https://"))
        #expect(!out.lowercased().contains("nan"))
    }

    @Test func reportListsMissingRunsAndSkipsMismatchedFPSPerWatt() {
        let a = bundle("a.fwrun", info(stack: Stack(runtime: "Protium", graphics: ["DXMT"])), fps: 60, watts: 30)
        let b = bundle("b.fwrun", info(stack: Stack(runtime: "Whisky", graphics: ["D3DMetal"])), fps: 50,
                       power: "gpu_w", watts: 5)
        let project = CompareProject(name: "p", baseline: 0,
                                     runs: [.init(bundle: "a.fwrun", name: "A run"),
                                            .init(bundle: "gone.fwrun", name: "Gone"),
                                            .init(bundle: "b.fwrun", name: "B run")])
        let out = CompareReport.html(project: project, runs: [pair(a), pair(b)])
        #expect(out.contains("missing: Gone (gone.fwrun)"))
        #expect(out.contains(CompareReport.powerMismatchWarning))
        // FPS/W bars carry only the baseline's power measure: A at 2.00, B (GPU-only) left out.
        #expect(out.contains("A run: 2.00 FPS/W"))
        #expect(!out.contains("B run: 10.00 FPS/W"))
    }

    @Test func mixedFrameTimesShowDashLowsInCompare() {
        var i = info(fpsSource: "stderr")
        i.warnings = [RunRecorder.mixedFramesWarning]
        let frames = (0..<6000).map { TimedFrame(tMs: Double($0) * 15, intervalMs: 15, presentDelayMs: 1) }
        let a0 = bundle("a.fwrun", i, fps: 60)
        let a = RunBundle(url: a0.url, info: i, rows: a0.rows, frames: frames, warnings: i.warnings)
        let project = CompareProject(name: "p", baseline: 0, runs: [.init(bundle: "a.fwrun", name: "A")])
        let out = CompareReport.html(project: project, runs: [pair(a)])
        #expect(out.contains("1 % low — (frame times mixed)"))
    }

    @Test func gpuOnlyPowerIsHedgedInCompare() {
        let a = bundle("a.fwrun", info(), fps: 60, power: "gpu_w", watts: 5)
        let project = CompareProject(name: "p", baseline: 0, runs: [.init(bundle: "a.fwrun", name: "A")])
        let out = CompareReport.html(project: project, runs: [pair(a)])
        #expect(out.contains("may under-read"))
        #expect(!out.contains("under-reads"))
    }

    @Test func unidentifiedGameIsNamed() {
        let w = CompareReport.warnings([(info(game: ""), RunSummary(bundle("a", info(game: ""), fps: 60))),
                                        (info(game: "B.exe"), RunSummary(bundle("b", info(game: "B.exe"), fps: 60)))])
        #expect(w.contains("different games: unidentified, B.exe"))
        let a = bundle("a.fwrun", info(game: ""), fps: 60)
        let project = CompareProject(name: "p", baseline: 0, runs: [.init(bundle: "a.fwrun", name: "A")])
        let out = CompareReport.html(project: project, runs: [pair(a)])
        #expect(out.contains("<dt>Game</dt><dd>unidentified</dd>"))
    }

    @Test func loadRunsSaysWhyARunIsMissing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fwcmp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        for name in ["bad.fwrun", "old.fwrun", "empty.fwrun"] {
            try fm.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data("{".utf8).write(to: root.appendingPathComponent("bad.fwrun/run.json"))
        try Data(#"{"schema":1,"game":{"exe":"g"},"start":"2026-11-24T12:00:00Z"}"#.utf8)
            .write(to: root.appendingPathComponent("old.fwrun/run.json"))
        let project = CompareProject(name: "p", runs: [.init(bundle: "gone.fwrun"), .init(bundle: "bad.fwrun"),
                                                       .init(bundle: "old.fwrun"), .init(bundle: "empty.fwrun")])
        let loaded = project.loadRuns(runsRoot: root)
        #expect(loaded.runs.isEmpty)
        #expect(loaded.missing.map(\.index) == [0, 1, 2, 3])
        let reasons = loaded.missing.map(\.reason)
        #expect(reasons[0] == "the run folder is gone")
        #expect(reasons[1].hasPrefix("run.json unreadable or incompatible: "))
        #expect(reasons[2] == "run.json unreadable or incompatible: missing \"machine\"")
        #expect(reasons[3] == "run.json unreadable or incompatible: no run.json")

        let out = CompareReport.html(project: project, runs: loaded.runs,
                                     problems: Dictionary(uniqueKeysWithValues: loaded.missing.map { ($0.index, $0.reason) }))
        #expect(out.contains("missing: gone.fwrun — run 1, the run folder is gone; it is left out"))
        #expect(out.contains("missing: old.fwrun — run 3, run.json unreadable or incompatible: missing &quot;machine&quot;; it is left out"))
    }

    @Test func displayIsACompareField() {
        var a = info(), b = info()
        a.settings.displayWidth = 1728; a.settings.displayHeight = 1117; a.settings.refreshHz = 120
        b.settings.displayWidth = 1728; b.settings.displayHeight = 1117; b.settings.refreshHz = 60
        let d = CompareReport.differences([a, b])
        #expect(d.map(\.field) == ["display"])
        #expect(d[0].values == ["1728×1117 @ 120 Hz", "1728×1117 @ 60 Hz"])
        #expect(CompareReport.differences([info(), info()]).isEmpty)
    }

    @Test func runLabels() {
        let a = info(stack: Stack(runtime: "Protium", graphics: ["DXMT", "vkd3d"]))
        #expect(CompareReport.label(.init(bundle: "x.fwrun", name: "Mine"), a) == "Mine")
        #expect(CompareReport.label(.init(bundle: "x.fwrun", name: ""), a) == "Protium DXMT + vkd3d")
        #expect(CompareReport.label(.init(bundle: "/p/x.fwrun", name: ""), info()) == "x.fwrun")
    }

    // MARK: - Fix round 1

    private func entries(_ pairs: [(String, String)]) -> [CompareProject.Entry] {
        pairs.map { CompareProject.Entry(bundle: $0.0, name: $0.1) }
    }

    @Test func pageNumbersFollowProjectEntries() {
        let a = bundle("a.fwrun", info(), fps: 60)
        let b = bundle("b.fwrun", info(label: "other"), fps: 50, seconds: 50)
        let project = CompareProject(name: "p", baseline: 0,
                                     runs: entries([("a.fwrun", "A run"), ("gone.fwrun", "Gone"), ("b.fwrun", "B run")]))
        let out = CompareReport.html(project: project, runs: [pair(a), pair(b)])
        #expect(out.contains("short steady time (under 60 s): run 3 (B run) at 40 s"))
        #expect(out.contains("<li value=\"2\" class=\"missing\">"))
        #expect(out.contains("<li value=\"3\">"))
        #expect(out.contains("3 · B run"))
        #expect(!out.contains("2 · B run"))
        // The public function keeps position-based names.
        let w = CompareReport.warnings([(a.info, RunSummary(a)), (b.info, RunSummary(b))])
        #expect(w.contains("short steady time (under 60 s): run 2 at 40 s"))
    }

    @Test func invalidBaselineIndexFallsBack() {
        let a = bundle("a.fwrun", info(), fps: 60)
        for bad in [5, -1] {
            let project = CompareProject(name: "p", baseline: bad, runs: entries([("a.fwrun", "A")]))
            let out = CompareReport.html(project: project, runs: [pair(a)])
            #expect(out.contains("baseline index \(bad + 1) is not in the project — using run 1"))
            #expect(!out.contains("is missing — using"))
        }
        let project = CompareProject(name: "p", baseline: 1, runs: entries([("a.fwrun", "A"), ("gone.fwrun", "Gone")]))
        let out = CompareReport.html(project: project, runs: [pair(a)])
        #expect(out.contains("baseline run 2 (Gone) is missing — using run 1"))
        #expect(!out.contains("is not in the project"))
    }

    @Test func zeroLoadedRunsStillRender() {
        let project = CompareProject(name: "p", baseline: 0, runs: entries([("x.fwrun", "X"), ("y.fwrun", "")]))
        let out = CompareReport.html(project: project, runs: [])
        #expect(out.contains("missing: X (x.fwrun)"))
        #expect(out.contains("missing: y.fwrun"))
        #expect(out.contains("<li value=\"1\" class=\"missing\">"))
        #expect(out.contains("</html>"))
    }

    @Test func baselineWithoutFPSGivesDashGains() {
        for fps in [0.0, -1] {
            var b0 = bundle("a.fwrun", info(), fps: 60)
            let rows = b0.rows.map { r -> [String: String] in var r = r; r["fps"] = fps < 0 ? "" : "0.0"; return r }
            b0 = RunBundle(url: b0.url, info: b0.info, rows: rows, frames: nil, warnings: [])
            let b1 = bundle("b.fwrun", info(), fps: 55)
            let project = CompareProject(name: "p", baseline: 0, runs: entries([("a.fwrun", "A"), ("b.fwrun", "B")]))
            let out = CompareReport.html(project: project, runs: [pair(b0), pair(b1)])
            #expect(out.contains("B: 55.0 fps median (—)"))
            #expect(!out.lowercased().contains("nan") && !out.lowercased().contains("inf"))
        }
    }

    @Test func duplicateEntryMarksOnlyBaselineIndex() {
        let a = bundle("a.fwrun", info(), fps: 60)
        let project = CompareProject(name: "p", baseline: 1, runs: entries([("a.fwrun", "First"), ("a.fwrun", "Second")]))
        let out = CompareReport.html(project: project, runs: [pair(a), pair(a)])
        #expect(out.components(separatedBy: "class=\"base\"").count == 2)
        #expect(out.contains("<li value=\"2\" class=\"base\">"))
        #expect(out.contains("First: 60.0 fps median (0.0 %)"))
    }

    @Test func fpsPerWattReferenceFromOtherRunIsNoted() {
        var a = bundle("a.fwrun", info(), fps: 60)
        a = RunBundle(url: a.url, info: a.info, rows: a.rows.map { r in r.filter { $0.key != "smc_PSTR_w" } },
                      frames: nil, warnings: [])
        let b = bundle("b.fwrun", info(), fps: 50)
        let project = CompareProject(name: "p", baseline: 0, runs: entries([("a.fwrun", "A"), ("b.fwrun", "B")]))
        let out = CompareReport.html(project: project, runs: [pair(a), pair(b)])
        #expect(out.contains("The baseline has no power readings; FPS/W compares runs measured like run 2 (B)."))
    }
}
