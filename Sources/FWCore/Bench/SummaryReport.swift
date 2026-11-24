import Foundation

/// The single-run report written to `<bundle>/summary.html`.
public enum SummaryReport {
    public static let fileName = "summary.html"

    /// Loads the bundle at `directory`, writes its summary next to it and returns the file's URL.
    @discardableResult
    public static func write(bundleAt directory: URL) throws -> URL {
        let bundle = try RunBundle.load(directory)
        let url = directory.appendingPathComponent(fileName)
        try Data(html(bundle, RunSummary(bundle)).utf8).write(to: url, options: .atomic)
        return url
    }

    // MARK: - Labels

    /// Runtime (+ version) · translator · graphics joined by " + "; nil when nothing is known.
    public static func stackLine(_ s: Stack) -> String? {
        var parts: [String] = []
        if let r = s.runtime { parts.append(r + (s.runtimeVersion.map { " \($0)" } ?? "")) }
        if let t = s.translator { parts.append(t) }
        if !s.graphics.isEmpty { parts.append(s.graphics.joined(separator: " + ")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    public static func fpsSourceText(_ source: String) -> String {
        switch source {
        case "log": return "per-second (system log)"
        case "stderr": return "per-frame (launched by fwbench)"
        default: return "none"
        }
    }

    static let columnNames: [String: String] = [
        "fps": "Frame rate", "ft_p99_ms": "Frame time p99", "ft_max_ms": "Frame time max",
        "gpu_w": "GPU power", "cpu_p_util_pct": "CPU P-cores busy", "cpu_e_util_pct": "CPU E-cores busy",
        "cpu_core_max_pct": "Busiest CPU core", "gpu_busy_pct": "GPU busy",
        // Only PSTR (system total) and PDTR (DC-in) have measured meanings (hardware-baseline.md); the other
        // SMC power keys are shown by key alone.
        "smc_PSTR_w": "System power", "smc_PDTR_w": "DC-in power", "temp_max_c": "Hottest die sensor", "temp_battery_c": "Battery temperature",
        "fan0_rpm": "Fan 1", "fan1_rpm": "Fan 2", "mem_used_gb": "Memory used", "battery_pct": "Battery charge",
        "battery_w": "Battery power",
    ]

    /// Display unit from the column's suffix.
    public static func unit(for column: String) -> String {
        if column == "fps" { return "fps" }
        if column.hasSuffix("_w") { return "W" }
        if column.hasSuffix("_pct") { return "%" }
        if column.hasSuffix("_c") { return "°C" }
        if column.hasSuffix("_rpm") { return "rpm" }
        if column.hasSuffix("_ms") { return "ms" }
        if column.hasSuffix("_gb") { return "GB" }
        if column.hasSuffix("_s") { return "s" }
        return ""
    }

    // MARK: - Report

    public static func html(_ bundle: RunBundle, _ summary: RunSummary) -> String {
        let info = bundle.info
        let e = HTML.escape
        let game = info.game.title ?? (info.game.exe.isEmpty ? "Unknown game" : info.game.exe)

        var body = "<div class=\"wrap\">\n<header>\n"
        body += "<div class=\"eyebrow\">fwbench run · \(e(startText(info.start)))</div>\n"
        body += "<h1>\(e(game))</h1>\n"
        if !info.user.label.isEmpty { body += "<p class=\"lede\">\(e(info.user.label))</p>\n" }
        body += "<dl class=\"meta\">\n"
        for (k, v) in metaRows(bundle, summary, game: game) { body += "<dt>\(e(k))</dt><dd>\(e(v))</dd>\n" }
        body += "</dl>\n</header>\n"

        // Warnings, in order, without repeats.
        var seen = Set<String>()
        let warnings = (summary.notes + bundle.warnings + info.warnings).filter { seen.insert($0).inserted }
        if !warnings.isEmpty {
            body += "<aside class=\"warn\"><h3>Read with care</h3><ul>"
            body += warnings.map { "<li>\(e($0))</li>" }.joined()
            body += "</ul></aside>\n"
        }

        body += tiles(info, summary)
        body += charts(bundle, summary)
        body += statsTable(summary)

        if !info.user.gameSettings.isEmpty || !info.user.notes.isEmpty {
            body += "<section><div class=\"section-head\"><div class=\"eyebrow\">Your notes</div></div><div class=\"user\">"
            if !info.user.gameSettings.isEmpty {
                body += "<div><div class=\"eyebrow\">Game settings</div><p>\(e(info.user.gameSettings))</p></div>"
            }
            if !info.user.notes.isEmpty {
                body += "<div><div class=\"eyebrow\">Notes</div><p>\(e(info.user.notes))</p></div>"
            }
            body += "</div></section>\n"
        }

        let version = info.appVersion.isEmpty ? "" : " \(info.appVersion)"
        body += "<footer>\(e(bundle.url.lastPathComponent)) · fwbench\(e(version))</footer>\n</div>"

        return HTML.page(title: "\(game) · fwbench", meta: [("fwhelper-run", bundle.url.lastPathComponent)],
                         body: body)
    }

    private static func startText(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    private static func metaRows(_ bundle: RunBundle, _ summary: RunSummary, game: String) -> [(String, String)] {
        let info = bundle.info
        var rows: [(String, String)] = []
        if info.game.title != nil, !info.game.exe.isEmpty { rows.append(("Executable", info.game.exe)) }
        rows.append(("Stack", stackLine(info.stack) ?? "not detected"))
        var duration = info.end.map { HTML.duration($0.timeIntervalSince(info.start)) } ?? "unfinished"
        duration += " · \(summary.steadySeconds.count) s steady"
        rows.append(("Duration", duration))
        let m = info.machine
        var machine = [m.modelID, m.chip].filter { !$0.isEmpty }
        if let g = m.gpuCores { machine.append("\(g)-core GPU") }
        machine.append("\(m.memoryGB) GB")
        rows.append(("Machine", machine.joined(separator: " · ")))
        rows.append(("macOS", "\(m.osVersion)" + (m.osBuild.isEmpty ? "" : " (\(m.osBuild))")))
        var power: [String] = []
        if let p = info.settings.powerMode { power.append("\(p) power mode") }
        if let ac = info.settings.onACAtStart { power.append(ac ? "on AC" : "on battery") }
        rows.append(("Power", power.isEmpty ? "unknown" : power.joined(separator: " · ")))
        if let w = info.settings.displayWidth, let h = info.settings.displayHeight {
            rows.append(("Display", "\(w)×\(h)" + (info.settings.refreshHz.map { " @ \(HTML.number($0, digits: 0)) Hz" } ?? "")))
        }
        rows.append(("FPS source", fpsSourceText(info.fpsSource)))
        return rows
    }

    private static func tile(_ eyebrow: String, _ value: String, _ detail: String, hint: String = "") -> String {
        var t = "<div class=\"tile\"><div class=\"eyebrow\">\(HTML.escape(eyebrow))</div><div class=\"k\">\(value)</div>"
        if !detail.isEmpty { t += "<div class=\"d\">\(HTML.escape(detail))</div>" }
        if !hint.isEmpty { t += "<div class=\"hint\">\(HTML.escape(hint))</div>" }
        return t + "</div>"
    }

    private static func tiles(_ info: RunInfo, _ s: RunSummary) -> String {
        let noFPS = s.medianFPS == nil ? "no FPS recorded" : ""
        let lowHint = info.fpsSource == "stderr" ? "" : "needs fwbench run"
        let lowDetail = info.fpsSource == "stderr" ? "from per-frame times" : ""
        var out = "<div class=\"tiles\">"
        out += tile("Median FPS", HTML.number(s.medianFPS, digits: 1),
                    s.medianFPS == nil ? noFPS : "over \(s.steadySeconds.count) steady s")
        out += tile("5 % second", HTML.number(s.p5FPS, digits: 1),
                    s.p5FPS == nil ? noFPS : "slowest 1 s in 20")
        out += tile("1 % low", HTML.number(s.low1, digits: 1), s.low1 == nil ? "" : lowDetail,
                    hint: s.low1 == nil ? lowHint : "")
        out += tile("0.1 % low", HTML.number(s.low01, digits: 1), s.low01 == nil ? "" : lowDetail,
                    hint: s.low01 == nil ? lowHint : "")
        let powerName = s.powerColumn == "smc_PSTR_w" ? "System power" : "GPU power"
        if let col = s.powerColumn, let mean = s.stats[col]?.mean {
            let perW = s.fpsPerWatt.map { "\(HTML.number($0, digits: 2)) FPS/W" } ?? "mean over steady seconds"
            out += tile(powerName, "\(HTML.number(mean, digits: 1))<small> W</small>", perW)
        } else {
            out += tile("Power", "—", "no power readings")
        }
        return out + "</div>\n"
    }

    private static func column(_ rows: [[String: String]], _ name: String) -> [Double?] {
        rows.map { r in r[name].flatMap { $0.isEmpty ? nil : Double($0) }.flatMap { $0.isFinite ? $0 : nil } }
    }

    private static func charts(_ bundle: RunBundle, _ s: RunSummary) -> String {
        let rows = bundle.rows
        guard !rows.isEmpty else { return "" }
        let x = rows.enumerated().map { i, r in r["elapsed_s"].flatMap(Double.init) ?? Double(i) }
        func has(_ values: [Double?]) -> Bool { values.contains { $0 != nil } }
        func chart(_ title: String, _ series: [(name: String, values: [Double?])], unit: String,
                   yMin: Double? = nil, yMax: Double? = nil, reference: (label: String, value: Double)? = nil,
                   digits: Int = 1, minSpan: Double = 0, height: Double = 190) -> String {
            let present = series.filter { has($0.values) }
            guard !present.isEmpty else { return "" }
            return "<div class=\"chart\"><h3>\(HTML.escape(title))</h3>"
                + HTML.lineChart(series: present, steady: s.steadySeconds, unit: unit, x: x, yMin: yMin, yMax: yMax,
                                 reference: reference, digits: digits, minSpan: minSpan, height: height)
                + "</div>\n"
        }

        var out = "<section><div class=\"section-head\"><div class=\"eyebrow\">Over time</div>"
        out += "<p class=\"note\">Shaded seconds are outside the steady window (warm-up, loading, menus) and are left "
        out += "out of every number on this page. Hover a chart for the values at that second.</p></div>\n"

        let fps = column(rows, "fps")
        if has(fps) {
            let ref = s.medianFPS.map { (label: "median \(HTML.number($0, digits: 1))", value: $0) }
            out += chart("Frame rate", [("FPS", fps)], unit: "fps", yMin: 0, reference: ref)
            out += chart("Frame time, slowest 1 % per second", [("p99 frame time", column(rows, "ft_p99_ms"))],
                         unit: "ms", yMin: 0, digits: 2, height: 140)
        } else {
            out += "<div class=\"chart\"><h3>Frame rate</h3><p class=\"note\">No FPS source: run "
            out += "<span class=\"mono\">fwbench hud on</span> and relaunch the game, or launch it with "
            out += "<span class=\"mono\">fwbench run</span>.</p></div>\n"
        }
        out += chart("Power", [("System", column(rows, "smc_PSTR_w")), ("GPU", column(rows, "gpu_w"))], unit: "W", yMin: 0)
        out += chart("Utilisation", [("CPU P-cores", column(rows, "cpu_p_util_pct")),
                                     ("CPU E-cores", column(rows, "cpu_e_util_pct")),
                                     ("GPU busy", column(rows, "gpu_busy_pct"))], unit: "%", yMin: 0, yMax: 100)
        out += chart("Hottest die sensor", [("Temperature", column(rows, "temp_max_c"))], unit: "°C",
                     minSpan: 20)
        out += chart("Fans", [("Fan 1", column(rows, "fan0_rpm")), ("Fan 2", column(rows, "fan1_rpm"))],
                     unit: "rpm", yMin: 0, digits: 0, minSpan: 2000, height: 140)
        return out + "</section>\n"
    }

    private static func statsTable(_ s: RunSummary) -> String {
        let columns = SampleColumns.all.filter { $0 != "elapsed_s" && s.stats[$0] != nil }
        guard !columns.isEmpty else { return "" }
        var out = "<section><div class=\"section-head\"><div class=\"eyebrow\">Steady-state statistics</div>"
        out += "<p class=\"note\">Per-second samples in the steady window. 5 % is the value 1 second in 20 is at or below.</p></div>"
        out += "<div class=\"tbl\"><table><thead><tr><th>Measure</th><th>Unit</th><th>Min</th><th>Mean</th>"
        out += "<th>Median</th><th>5 %</th><th>Max</th><th>Seconds</th></tr></thead><tbody>"
        for c in columns {
            guard let st = s.stats[c] else { continue }
            let d = SampleColumns.digits(for: c)
            let label = columnNames[c] ?? (c.hasPrefix("smc_") ? "SMC power key" : c)
            let name = "\(HTML.escape(label))<span class=\"key\">\(HTML.escape(c))</span>"
            out += "<tr><td>\(name)</td><td>\(HTML.escape(unit(for: c)))</td>"
            for v in [st.min, st.mean, st.median, st.p5, st.max] { out += "<td class=\"num\">\(HTML.number(v, digits: d))</td>" }
            out += "<td class=\"num\">\(st.count)</td></tr>"
        }
        return out + "</tbody></table></div></section>\n"
    }
}
