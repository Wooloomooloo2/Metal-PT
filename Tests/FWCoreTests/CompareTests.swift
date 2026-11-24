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

    @Test func runLabels() {
        let a = info(stack: Stack(runtime: "Protium", graphics: ["DXMT", "vkd3d"]))
        #expect(CompareReport.label(.init(bundle: "x.fwrun", name: "Mine"), a) == "Mine")
        #expect(CompareReport.label(.init(bundle: "x.fwrun", name: ""), a) == "Protium DXMT + vkd3d")
        #expect(CompareReport.label(.init(bundle: "/p/x.fwrun", name: ""), info()) == "x.fwrun")
    }
}
