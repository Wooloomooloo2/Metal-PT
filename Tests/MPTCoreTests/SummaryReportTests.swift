import Testing
import Foundation
@testable import MPTCore

@Suite struct SummaryReportTests {
    private func bundle(label: String = "", stack: Stack = Stack(), frames: [TimedFrame]? = nil,
                        fpsSource: String = "log", warnings: [String] = [],
                        extra: [String: String] = [:], gpuMaxMHz: Int? = nil) -> RunBundle {
        var info = RunInfo(appVersion: "0.1", machine: .init(modelID: "Mac15,6", chip: "M3 Pro", memoryGB: 36,
                                                             osVersion: "15.1", osBuild: "24B83",
                                                             gpuMaxMHz: gpuMaxMHz),
                           game: .init(exe: "Game.exe"), stack: stack,
                           start: Date(timeIntervalSince1970: 1_800_000_000),
                           end: Date(timeIntervalSince1970: 1_800_000_050), fpsSource: fpsSource, warnings: warnings)
        info.user.label = label
        let rows: [[String: String]] = (0..<50).map { i in
            ["elapsed_s": "\(i)", "fps": i < 3 ? "" : "60.0", "fps_app": "Game.exe", "gpu_w": "10.00",
             "smc_PSTR_w": "30.00", "cpu_p_util_pct": "40.0", "temp_max_c": "70.0", "fan0_rpm": "2000"]
                .merging(extra) { _, new in new }
        }
        return RunBundle(url: URL(fileURLWithPath: "/runs/20270115-080000-game-exe.mptrun"), info: info, rows: rows,
                         frames: frames, warnings: warnings)
    }

    private func html(_ b: RunBundle) -> String { SummaryReport.html(b, RunSummary(b)) }

    @Test func escapesUserText() {
        let out = html(bundle(label: "<script>alert(1)</script> & \"q\""))
        #expect(out.contains("&lt;script&gt;alert(1)&lt;/script&gt; &amp; &quot;q&quot;"))
        #expect(!out.contains("<script>alert"))
        #expect(HTML.escape("a<b>&'\"") == "a&lt;b&gt;&amp;&#39;&quot;")
    }

    @Test func containsTilesAndStack() {
        let out = html(bundle(stack: Stack(runtime: "Protium", translator: "FEX", graphics: ["DXMT"])))
        #expect(out.contains("60.0"))
        #expect(out.contains("Protium · FEX · DXMT"))
        #expect(out.contains("<meta name=\"mpt-run\" content=\"20270115-080000-game-exe.mptrun\">"))
        #expect(out.contains("<svg"))
        #expect(out.contains("2.00 FPS/W"))
    }

    @Test func noNetworkReferences() {
        let out = html(bundle(label: "x", stack: Stack(runtime: "CrossOver", runtimeVersion: "25.1",
                                                       translator: "Rosetta", graphics: ["D3DMetal"])))
        #expect(!out.contains("http://"))
        #expect(!out.contains("https://"))
        #expect(!out.lowercased().contains("<script"))
        #expect(out.contains("CrossOver 25.1 · Rosetta · D3DMetal"))
    }

    @Test func missingLowsShowDash() {
        let out = html(bundle(frames: nil, fpsSource: "log"))
        #expect(out.contains("1 % low"))
        #expect(out.contains("<div class=\"k\">—</div>"))
        #expect(out.contains("needs mpt run"))
    }

    @Test func mixedFrameTimesShowDashWithHint() {
        let frames = (0..<500).map { TimedFrame(tMs: 12_000 + Double($0) * 16.67, intervalMs: 16.67, presentDelayMs: 1) }
        let out = html(bundle(frames: frames, fpsSource: "stderr", warnings: [RunRecorder.mixedFramesWarning]))
        #expect(out.contains("frame times mixed"))
        #expect(out.contains(RunRecorder.mixedFramesWarning))
        #expect(!out.contains("from per-frame times"))
    }

    @Test func warningsAreDeduplicated() {
        let out = html(bundle(warnings: ["stack not detected", "stack not detected"]))
        #expect(out.components(separatedBy: "stack not detected").count == 2)
        #expect(out.contains("short run"))
    }

    @Test func lineChartBreaksAtGapsAndShadesUnsteady() {
        let svg = HTML.lineChart(series: [(name: "a", values: [1, 2, nil, 4, 5])], steady: [1, 3, 4], unit: "W")
        // Two path segments: M..L.. then a new M after the gap.
        let d = svg.components(separatedBy: "d=\"").dropFirst().first ?? ""
        #expect(d.components(separatedBy: "M").count - 1 == 2)
        #expect(svg.contains("class=\"shade\""))
        #expect(!svg.contains("NaN"))
    }

    @Test func barsShowDashForNil() {
        let out = HTML.bars([(label: "A", value: 10, note: "n"), (label: "B<", value: nil, note: "")], unit: "fps")
        #expect(out.contains("B&lt;"))
        #expect(out.contains("—"))
    }
    // MARK: - What held it back

    private let gpuBound = ["gpu_busy_pct": "100.0", "gpu_mhz": "1578", "mem_pressure": "normal",
                            "pageouts_per_s": "0", "thermal_state": "nominal", "cpu_core_max_pct": "50.0"]

    @Test func limiterSectionFollowsTiles() throws {
        let out = html(bundle(extra: gpuBound, gpuMaxMHz: 1578))
        let section = try #require(out.range(of: "What held it back"))
        let tiles = try #require(out.range(of: "<div class=\"tiles\">"))
        let charts = try #require(out.range(of: "Over time"))
        #expect(tiles.lowerBound < section.lowerBound && section.lowerBound < charts.lowerBound)
        #expect(out.contains("<p class=\"verdict\">Mostly GPU</p>"))
        #expect(out.contains("GPU busy median 100 %"))
        #expect(out.contains("MetalFX"))
        #expect(out.contains("class=\"callout\""))
        #expect(out.contains("How this is decided"))
        #expect(out.contains(HTML.escape(LimiterAnalysis.describeThresholds()[0])))
        #expect(out.contains("100 %</text>"))             // the GPU share bar
        #expect(out.contains("var(--limit-gpu)"))
        #expect(!out.contains("This run didn"))          // nothing missing
        #expect(!out.lowercased().contains("<script"))
    }

    @Test func limiterNamesMissingInputsOfOldRuns() {
        let out = html(bundle(extra: ["gpu_busy_pct": "100.0"]))
        #expect(out.contains("Mostly GPU"))
        #expect(out.contains("This run didn&#39;t record: GPU clock, memory pressure — newer runs do."))
    }

    @Test func noSingleLimitIsNotPresentedAsALimiter() {
        let out = html(bundle(extra: ["gpu_busy_pct": "90.0", "cpu_core_max_pct": "50.0"]))
        #expect(out.contains("<p class=\"verdict\">No single limit stood out</p>"))
        #expect(out.contains("var(--limit-none)"))
        #expect(!out.contains("class=\"callout\""))
    }

    @Test func summaryCarriesItsVersion() {
        let out = html(bundle())
        #expect(out.contains("<meta name=\"mpt-summary-version\" content=\"\(SummaryReport.version)\">"))
        #expect(SummaryReport.version >= 2)
        #expect(SummaryReport.fileVersion(of: out) == SummaryReport.version)
        #expect(SummaryReport.fileVersion(of: "<html><head><meta name=\"mpt-run\" content=\"x\"></head>") == 1)
    }
}

@Suite struct SummaryReportEdgeTests {
    private func clean(_ s: String) -> Bool {
        let l = s.lowercased()
        return !l.contains("nan") && !l.contains("inf")
    }

    @Test func escapesCombiningMarksAfterSpecials() {
        let out = HTML.escape("\"\u{301}<\u{301}")
        #expect(out == "&quot;\u{301}&lt;\u{301}")
        #expect(!out.unicodeScalars.contains("\""))
        #expect(!out.unicodeScalars.contains("<"))
    }

    @Test func chartEdgeCasesStayFinite() {
        let cases: [[(name: String, values: [Double?])]] = [
            [],
            [(name: "a", values: [])],
            [(name: "a", values: [nil, nil, nil])],
            [(name: "a", values: [5])],
            [(name: "a", values: [nil, 7, nil])],
            [(name: "a", values: [3, 3, 3, 3])],
            [(name: "a", values: [0, 0, 0])],
            [(name: "a", values: [-2, -2])],
        ]
        for series in cases {
            let svg = HTML.lineChart(series: series, steady: [], unit: "W")
            #expect(clean(svg), "\(series)")
            #expect(svg.contains("</svg>"))
        }
        let pinned = HTML.lineChart(series: [(name: "a", values: [1, 1])], steady: [0, 1], unit: "%", yMin: 0, yMax: 100,
                                    minSpan: 20)
        #expect(clean(pinned))
        #expect(clean(HTML.bars([], unit: "fps")))
        #expect(clean(HTML.bars([(label: "z", value: 0, note: "")], unit: "fps")))
    }

    @Test func singlePointIsDrawnAsDot() {
        let svg = HTML.lineChart(series: [(name: "a", values: [nil, 7, nil])], steady: [1], unit: "W")
        #expect(svg.contains("h0"))
    }

    @Test func gpuOnlyPowerIsFlagged() {
        let info = RunInfo(appVersion: "0.1", machine: .init(modelID: "M", chip: "C", memoryGB: 8, osVersion: "15",
                                                             osBuild: "1"),
                           game: .init(exe: "g"), start: Date(timeIntervalSince1970: 0), fpsSource: "log")
        let rows: [[String: String]] = (0..<30).map { ["elapsed_s": "\($0)", "fps": "60", "fps_app": "g", "gpu_w": "2.00"] }
        let b = RunBundle(url: URL(fileURLWithPath: "/r.mptrun"), info: info, rows: rows, frames: nil, warnings: [])
        let out = SummaryReport.html(b, RunSummary(b))
        #expect(out.contains("GPU power (IOReport)"))
        #expect(out.contains("no system power key — FPS/W not comparable"))
        #expect(out.contains("power is GPU-only (IOReport), FPS/W not comparable across runs"))
        #expect(out.contains("GPU (IOReport)"))
        #expect(out.contains("IOReport GPU energy can read low at light load; under heavy load it tracks the GPU (hardware-baseline E6)"))
        #expect(!out.contains("under-read"))
        #expect(!out.contains("averaged over"))
    }
}
