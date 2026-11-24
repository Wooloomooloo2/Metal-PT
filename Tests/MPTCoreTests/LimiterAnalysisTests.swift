import Testing
import Foundation
@testable import MPTCore

@Suite struct LimiterAnalysisTests {
    private func bundle(_ rows: [[String: String]], gpuMaxMHz: Int? = 1600, steady: Bool = true) -> RunBundle {
        let info = RunInfo(appVersion: "0.2", machine: .init(modelID: "Mac16,5", chip: "M4 Max", memoryGB: 48,
                                                             osVersion: "27.0", osBuild: "26A", gpuMaxMHz: gpuMaxMHz),
                           game: .init(exe: "g"), start: Date(timeIntervalSince1970: 1_800_000_000),
                           steadyStartS: steady ? 1 : nil, steadyEndS: steady ? Double(rows.count) : nil,
                           fpsSource: "log")
        return RunBundle(url: URL(fileURLWithPath: "/x.mptrun"), info: info, rows: rows, frames: nil, warnings: [])
    }

    /// `n` rows at elapsed 1…n; `f` gives row i's cells. New-column defaults: full clock, normal pressure.
    private func rows(_ n: Int, newColumns: Bool = true, _ f: (Int) -> [String: String]) -> [[String: String]] {
        (0..<n).map { i in
            var r: [String: String] = ["elapsed_s": "\(i + 1)", "fps_app": "g", "thermal_state": "nominal"]
            if newColumns { r["gpu_mhz"] = "1578"; r["mem_pressure"] = "normal"; r["pageouts_per_s"] = "0" }
            for (k, v) in f(i) { r[k] = v }
            return r
        }
    }

    private func analyse(_ b: RunBundle) -> LimiterAnalysis { LimiterAnalysis(b, summary: RunSummary(b)) }

    private func share(_ a: LimiterAnalysis, _ l: Limiter) -> Double {
        a.shares.first { $0.0 == l }?.1 ?? 0
    }

    @Test func cyberpunkLikeIsGPU() {
        let a = analyse(bundle(rows(120) { _ in
            ["fps": "34.0", "gpu_busy_pct": "100.0", "cpu_core_max_pct": "55.0", "cpu_p_util_pct": "20.0"]
        }))
        #expect(a.primary == .gpu)
        #expect(share(a, .gpu) == 1.0)
        #expect(a.verdict == "Mostly GPU")
        #expect(a.missing.isEmpty)
        #expect(a.suggestion?.contains("MetalFX") == true)
        #expect(a.evidence.contains { $0.contains("GPU busy") && $0.contains("100 %") })
    }

    @Test func frameCapDetected() {
        let a = analyse(bundle(rows(120) { i in
            ["fps": i % 2 == 0 ? "60.5" : "59.5", "gpu_busy_pct": "70.0", "cpu_core_max_pct": "60.0",
             "cpu_p_util_pct": "30.0", "gpu_mhz": "560"]
        }))
        #expect(a.primary == .frameCap)
        #expect(share(a, .frameCap) == 1.0)
        #expect(a.suggestion == "Looks capped at 60 fps (V-Sync or an in-game limit): raise or remove the cap if you want more.")
    }

    /// The measured 60 fps load: busy 82–95 % at ~35 % clock is a frame cap, not GPU-bound (ruling L1).
    @Test func cappedWithHighBusyAtLowClockIsFrameCap() {
        let a = analyse(bundle(rows(100) { i in
            ["fps": "60.0", "gpu_busy_pct": ["82.0", "91.0", "95.0", "97.0"][i % 4], "gpu_mhz": "560",
             "cpu_core_max_pct": "60.0"]
        }))
        #expect(a.primary == .frameCap)
        #expect(share(a, .frameCap) == 1.0)
    }

    @Test func highBusyAtLowClockIsNotGPU() {
        let a = analyse(bundle(rows(100) { _ in
            ["fps": "52.0", "gpu_busy_pct": "98.0", "gpu_mhz": "560", "cpu_core_max_pct": "60.0"]
        }))
        #expect(share(a, .gpu) == 0)
        #expect(a.primary == .unclear)
        #expect(a.verdict == "No single limit stood out")
        #expect(a.evidence.contains("GPU busy but running at 35 % of its top clock — the game isn't pushing it"))
    }

    @Test func oneThread() {
        let a = analyse(bundle(rows(100) { _ in
            ["fps": "52.0", "gpu_busy_pct": "60.0", "cpu_core_max_pct": "97.0", "cpu_p_util_pct": "40.0"]
        }))
        #expect(a.primary == .cpuOneThread)
        #expect(a.suggestion == "One CPU thread is the limit: lowering graphics settings is unlikely to help; reduce "
                + "CPU-heavy settings such as crowd density or simulation.")
        #expect(a.evidence.contains { $0.contains("97 %") })
    }

    @Test func cpuAcrossCores() {
        let a = analyse(bundle(rows(100) { _ in
            ["fps": "52.0", "gpu_busy_pct": "60.0", "cpu_core_max_pct": "85.0", "cpu_p_util_pct": "88.0"]
        }))
        #expect(a.primary == .cpu)
    }

    @Test func thermal() {
        let a = analyse(bundle(rows(100) { _ in
            ["fps": "41.0", "gpu_busy_pct": "99.0", "thermal_state": "serious"]
        }))
        #expect(a.primary == .gpuThermal)
        #expect(a.verdict == "Mostly GPU (thermal)")
        #expect(a.suggestion == "macOS reported serious thermal pressure while the GPU was fully busy; "
                + "performance may be limited by heat.")
    }

    /// Clock below 85 % of the run's highest clock while thermal ≥ fair → thermal, not plain GPU.
    @Test func thermalFromClockDrop() {
        let a = analyse(bundle(rows(100) { i in
            i < 20 ? ["fps": "41.0", "gpu_busy_pct": "99.0", "gpu_mhz": "1578"]
                   : ["fps": "37.0", "gpu_busy_pct": "99.0", "gpu_mhz": "1300", "thermal_state": "fair"]
        }))
        #expect(share(a, .gpuThermal) == 0.8)
        #expect(share(a, .gpu) == 0.2)
        #expect(a.primary == .gpuThermal)
        #expect(a.suggestion == "The GPU clock dropped to 82 % of its peak under heat: a cooler surface or (later) "
                + "a stronger fan curve with Metal-PT Helper may help.")
    }

    /// One warm-up sample at 1600 MHz must not make a steady 1300 MHz at thermal fair look like a heat drop: the
    /// reference is min(top clock, 95th percentile of steady clocks).
    @Test func warmupClockSpikeIsNotThermal() {
        var r = rows(100) { _ in
            ["fps": "37.0", "gpu_busy_pct": "99.0", "gpu_mhz": "1300", "thermal_state": "fair"]
        }
        r[0]["gpu_mhz"] = "1600"
        let b = bundle(r, steady: false)   // no FPS-app trimming issue: auto window drops the first 10 s
        let a = analyse(b)
        #expect(!RunSummary(b).steadySeconds.contains(0))
        #expect(share(a, .gpuThermal) == 0)
    }

    @Test func fpsCapBoundary() {
        let at = analyse(bundle(rows(50) { _ in ["fps": "59.0", "gpu_busy_pct": "70.0"] }))
        #expect(at.primary == .frameCap)
        let off = analyse(bundle(rows(50) { _ in ["fps": "58.5", "gpu_busy_pct": "70.0"] }))
        #expect(share(off, .frameCap) == 0)
    }

    @Test func gpuBusyBoundary() {
        let below = analyse(bundle(rows(50) { _ in ["fps": "52.0", "gpu_busy_pct": "94.9"] }))
        #expect(share(below, .gpu) == 0)
        let at = analyse(bundle(rows(50) { _ in ["fps": "52.0", "gpu_busy_pct": "95.0"] }))
        #expect(at.primary == .gpu)
    }

    @Test func clockExactly85PercentIsGPU() {
        let a = analyse(bundle(rows(50) { _ in ["fps": "52.0", "gpu_busy_pct": "99.0", "gpu_mhz": "1360"] }))
        #expect(a.primary == .gpu)
    }

    @Test func pageoutsAloneAreMemory() {
        let a = analyse(bundle(rows(50) { _ in ["fps": "52.0", "gpu_busy_pct": "99.0", "pageouts_per_s": "51"] }))
        #expect(a.primary == .memory)
        let calm = analyse(bundle(rows(50) { _ in ["fps": "52.0", "gpu_busy_pct": "99.0", "pageouts_per_s": "50"] }))
        #expect(calm.primary == .gpu)
    }

    @Test func mixedWithUnclearNamesIt() {
        let a = analyse(bundle(rows(100) { i in
            ["fps": "52.0", "gpu_busy_pct": i % 2 == 0 ? "100.0" : "90.0"]
        }))
        #expect(a.verdict == "Mixed: GPU and no single limit")
    }

    @Test func memory() {
        let a = analyse(bundle(rows(100) { i in
            ["fps": "52.0", "gpu_busy_pct": "100.0", "mem_pressure": i < 70 ? "warn" : "normal",
             "pageouts_per_s": i >= 70 && i < 80 ? "120" : "0"]
        }))
        #expect(a.primary == .memory)
        #expect(share(a, .memory) == 0.8)
        #expect(a.suggestion == "Memory is under pressure: close other apps or lower texture quality.")
    }

    @Test func mixedFiftyFifty() {
        let a = analyse(bundle(rows(100) { i in
            i % 2 == 0 ? ["fps": "52.0", "gpu_busy_pct": "100.0"]
                       : ["fps": "52.0", "gpu_busy_pct": "60.0", "cpu_core_max_pct": "97.0"]
        }))
        #expect(a.verdict == "Mixed: GPU and CPU (one thread)")
        #expect(a.primary == nil)
        #expect(share(a, .gpu) == 0.5)
    }

    @Test func oldRunWithoutNewColumns() {
        let a = analyse(bundle(rows(100, newColumns: false) { _ in
            ["fps": "34.0", "gpu_busy_pct": "100.0", "cpu_core_max_pct": "55.0", "cpu_p_util_pct": "20.0"]
        }, gpuMaxMHz: nil))
        #expect(a.primary == .gpu)
        #expect(a.missing.contains("no GPU clock recorded"))
        #expect(a.missing.contains("no memory pressure recorded"))
    }

    /// A clock column but no top clock in run.json: busy-only, and say so.
    @Test func clockWithoutTopClockFallsBackToBusy() {
        let a = analyse(bundle(rows(100) { _ in ["fps": "34.0", "gpu_busy_pct": "100.0", "gpu_mhz": "560"] },
                               gpuMaxMHz: nil))
        #expect(a.primary == .gpu)
        #expect(a.missing.contains("no GPU top clock recorded"))
    }

    @Test func noFPSSourceStillRuns() {
        let a = analyse(bundle(rows(30) { _ in ["gpu_busy_pct": "100.0"] }, steady: false))
        #expect(a.primary == .gpu)
        #expect(a.missing.contains("no FPS recorded"))
    }

    @Test func noSteadySeconds() {
        let a = analyse(bundle([], steady: false))
        #expect(a.primary == nil)
        #expect(a.shares.isEmpty)
        #expect(a.suggestion == nil)
    }

    @Test func thresholdsAreDescribed() {
        let t = LimiterAnalysis.thresholds
        #expect(t.gpuBusyPct == 95 && t.gpuClockFraction == 0.85 && t.frameCapMaxGPUBusyPct == 90)
        #expect(t.frameCaps == [30, 40, 45, 60, 90, 120, 144])
        let lines = LimiterAnalysis.describeThresholds()
        #expect(lines.count == 7)
        #expect(lines.contains { $0.contains("85 %") && $0.contains("top clock") })
    }
}
