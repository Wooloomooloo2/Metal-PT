import Testing
import Foundation
@testable import FWCore

@Suite struct SummaryReportTests {
    private func bundle(label: String = "", stack: Stack = Stack(), frames: [TimedFrame]? = nil,
                        fpsSource: String = "log", warnings: [String] = []) -> RunBundle {
        var info = RunInfo(appVersion: "0.1", machine: .init(modelID: "Mac15,6", chip: "M3 Pro", memoryGB: 36,
                                                             osVersion: "15.1", osBuild: "24B83"),
                           game: .init(exe: "Game.exe"), stack: stack,
                           start: Date(timeIntervalSince1970: 1_800_000_000),
                           end: Date(timeIntervalSince1970: 1_800_000_050), fpsSource: fpsSource, warnings: warnings)
        info.user.label = label
        let rows: [[String: String]] = (0..<50).map { i in
            ["elapsed_s": "\(i)", "fps": i < 3 ? "" : "60.0", "fps_app": "Game.exe", "gpu_w": "10.00",
             "smc_PSTR_w": "30.00", "cpu_p_util_pct": "40.0", "temp_max_c": "70.0", "fan0_rpm": "2000"]
        }
        return RunBundle(url: URL(fileURLWithPath: "/runs/20270115-080000-game-exe.fwrun"), info: info, rows: rows,
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
        #expect(out.contains("<meta name=\"fwhelper-run\" content=\"20270115-080000-game-exe.fwrun\">"))
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
        #expect(out.contains("needs fwbench run"))
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
}
