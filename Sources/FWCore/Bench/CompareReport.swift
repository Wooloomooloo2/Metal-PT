import Foundation

/// The report for a `CompareProject`: every run against the baseline, what differed between them, and what makes
/// the comparison shaky. Written as `<project slug>.html` next to the project JSON.
public enum CompareReport {
    public static let acBatteryWarning = "some runs started on AC, some on battery"
    public static let powerMismatchWarning = "power measured differently (system vs GPU-only) — FPS/W not compared"
    static let mixedFPSWarning = "mixed FPS sources — 1 % lows only for runs launched with fwbench run"
    private static let dash = "—"

    // MARK: - Labels and numbers

    /// The entry's name, else "<runtime> <graphics>" from the stack, else the bundle folder name.
    public static func label(_ entry: CompareProject.Entry, _ info: RunInfo) -> String {
        if !entry.name.isEmpty { return entry.name }
        let parts = [info.stack.runtime ?? "", info.stack.graphics.joined(separator: " + ")].filter { !$0.isEmpty }
        if !parts.isEmpty { return parts.joined(separator: " ") }
        return (entry.bundle as NSString).lastPathComponent
    }

    /// Signed change against the baseline, one decimal, real minus sign: "+10.0 %", "−9.8 %", "0.0 %".
    public static func gain(_ value: Double?, baseline: Double?) -> String {
        guard let value, let baseline, value.isFinite, baseline.isFinite, baseline > 0 else { return dash }
        let pct = (value / baseline - 1) * 100
        let digits = CSV.number(abs(pct), digits: 1)
        if digits == "0.0" { return "0.0 %" }
        return (pct > 0 ? "+" : "\u{2212}") + digits + " %"
    }

    // MARK: - Differences

    /// The compared fields of one run, in display order; "—" when unknown.
    static func fields(_ i: RunInfo) -> [(field: String, value: String)] {
        func v(_ s: String?) -> String { (s ?? "").isEmpty ? dash : s! }
        let m = i.machine
        var machine = [m.modelID, m.chip].filter { !$0.isEmpty }
        if let g = m.gpuCores { machine.append("\(g)-core GPU") }
        if m.memoryGB > 0 { machine.append("\(m.memoryGB) GB") }
        let build = m.osBuild.isEmpty ? m.osVersion : "\(m.osVersion) (\(m.osBuild))"
        return [
            ("game", v(i.game.title ?? i.game.exe)),
            ("runtime", v(i.stack.runtime)),
            ("runtime version", v(i.stack.runtimeVersion)),
            ("translator", v(i.stack.translator)),
            ("graphics", v(i.stack.graphics.joined(separator: " + "))),
            ("game settings", v(i.user.gameSettings)),
            ("label", v(i.user.label)),
            ("power mode", v(i.settings.powerMode)),
            ("AC/battery", v(i.settings.onACAtStart.map { $0 ? "AC" : "battery" })),
            ("macOS build", v(build)),
            ("machine", v(machine.joined(separator: " · "))),
            ("FPS source", SummaryReport.fpsSourceText(i.fpsSource)),
        ]
    }

    /// Only the fields whose values are not the same in every run, values in run order.
    public static func differences(_ infos: [RunInfo]) -> [(field: String, values: [String])] {
        columns(infos).filter { Set($0.values).count > 1 }
    }

    /// Fields with one known value across every run.
    static func shared(_ infos: [RunInfo]) -> [(field: String, value: String)] {
        columns(infos).compactMap { c in
            guard let first = c.values.first, first != dash, Set(c.values).count == 1 else { return nil }
            return (c.field, first)
        }
    }

    private static func columns(_ infos: [RunInfo]) -> [(field: String, values: [String])] {
        let all = infos.map(fields)
        guard let names = all.first?.map(\.field) else { return [] }
        return names.enumerated().map { k, name in (name, all.map { $0[k].value }) }
    }

    // MARK: - Warnings

    /// What makes these runs hard to compare. Runs are referred to by position ("run 2").
    public static func warnings(_ runs: [(RunInfo, RunSummary)]) -> [String] {
        var out: [String] = []
        func distinct(_ values: [String]) -> [String] {
            var seen = Set<String>()
            return values.filter { seen.insert($0).inserted }
        }
        let games = distinct(runs.map { $0.0.game.title ?? $0.0.game.exe })
        if games.count > 1 { out.append("different games: " + games.joined(separator: ", ")) }
        if Set(runs.compactMap { $0.0.settings.onACAtStart }).count > 1 { out.append(acBatteryWarning) }

        let steady = runs.map { $0.1.steadySeconds.count }
        if let lo = steady.min(), let hi = steady.max(), hi > 2 * lo {
            out.append("steady times differ more than 2× (\(lo) s to \(hi) s)")
        }
        let short = steady.enumerated().filter { $0.element < 60 }.map { "run \($0.offset + 1) (\($0.element) s)" }
        if !short.isEmpty { out.append("short steady time (under 60 s): " + short.joined(separator: ", ")) }

        let machines = Set(runs.map { i in fields(i.0).first { $0.field == "machine" }?.value ?? "" })
        if machines.count > 1 { out.append("different machines") }
        if Set(runs.map { $0.0.machine.osBuild }).count > 1 { out.append("different macOS builds") }
        if Set(runs.map { $0.0.fpsSource }).count > 1 { out.append(mixedFPSWarning) }
        if Set(runs.compactMap { $0.1.powerColumn }).count > 1 { out.append(powerMismatchWarning) }
        return out
    }

    // MARK: - Report

    private struct Item {
        let entry: CompareProject.Entry
        let bundle: RunBundle
        let summary: RunSummary
        let label: String
        var power: Double? { summary.powerColumn.flatMap { summary.stats[$0]?.mean } }
    }

    /// Loads the project's runs, writes the report next to `projectURL` (same name, `.html`) and returns its URL.
    @discardableResult
    public static func write(project: CompareProject, projectURL: URL, runsRoot: URL) throws -> URL {
        let url = projectURL.deletingPathExtension().appendingPathExtension("html")
        let loaded = project.loadRuns(runsRoot: runsRoot)
        try Data(html(project: project, runs: loaded.runs).utf8).write(to: url, options: .atomic)
        return url
    }

    private static func matches(_ entry: CompareProject.Entry, _ bundle: RunBundle) -> Bool {
        if entry.bundle.hasPrefix("/") {
            return URL(fileURLWithPath: entry.bundle).standardizedFileURL.path == bundle.url.standardizedFileURL.path
        }
        return bundle.url.lastPathComponent == entry.bundle
    }

    public static func html(project: CompareProject, runs: [(RunBundle, RunSummary)]) -> String {
        let e = HTML.escape

        // Pair entries with loaded runs, in project order; entries without one are missing.
        var unused = Array(runs.indices)
        var items: [Item] = []
        var missing: [CompareProject.Entry] = []
        var baseItem: Int?
        for (k, entry) in project.runs.enumerated() {
            guard let pos = unused.firstIndex(where: { matches(entry, runs[$0].0) }) else { missing.append(entry); continue }
            let (b, s) = runs[unused.remove(at: pos)]
            if k == project.baseline { baseItem = items.count }
            items.append(Item(entry: entry, bundle: b, summary: s, label: label(entry, b.info)))
        }
        for i in unused {
            let entry = CompareProject.Entry(bundle: runs[i].0.url.lastPathComponent)
            items.append(Item(entry: entry, bundle: runs[i].0, summary: runs[i].1, label: label(entry, runs[i].0.info)))
        }

        var warns: [String] = []
        if !items.isEmpty, baseItem == nil {
            warns.append("baseline run missing — comparing against \(items[0].label)")
        }
        let base = items.isEmpty ? nil : items[baseItem ?? 0]
        for m in missing {
            let shown = m.name.isEmpty ? (m.bundle as NSString).lastPathComponent : "\(m.name) (\((m.bundle as NSString).lastPathComponent))"
            warns.append("missing: \(shown) — the run folder is gone; it is left out")
        }
        warns += warnings(items.map { ($0.bundle.info, $0.summary) })
        for (n, it) in items.enumerated() {
            let notes = it.summary.notes.filter { $0.hasPrefix("thermal") || $0.hasPrefix("no ") }
            for w in it.bundle.warnings + notes { warns.append("run \(n + 1): \(w)") }
        }
        var seen = Set<String>()
        warns = warns.filter { seen.insert($0).inserted }

        // FPS/W only for runs measured like the baseline.
        let powerColumn = base?.summary.powerColumn ?? items.compactMap(\.summary.powerColumn).first
        let efficient = items.filter { $0.summary.powerColumn == powerColumn && $0.summary.fpsPerWatt != nil }
        let skipped = items.filter { $0.summary.fpsPerWatt != nil && $0.summary.powerColumn != powerColumn }

        let games = Array(Set(items.map { $0.bundle.info.game.title ?? $0.bundle.info.game.exe })).sorted()
        var body = "<div class=\"wrap\">\n<header>\n"
        body += "<div class=\"eyebrow\">fwbench compare · \(items.count) run\(items.count == 1 ? "" : "s")</div>\n"
        body += "<h1>\(e(project.name))</h1>\n"
        if let base {
            body += "<p class=\"lede\">Each run against the baseline, <strong>\(e(base.label))</strong>. "
            body += "Every number is over that run’s steady seconds.</p>\n"
        }
        body += "<dl class=\"meta\">\n"
        body += "<dt>\(games.count > 1 ? "Games" : "Game")</dt><dd>\(e(games.isEmpty ? dash : games.joined(separator: ", ")))</dd>\n"
        body += "<dt>Runs</dt><dd>\(items.count) loaded\(missing.isEmpty ? "" : ", \(missing.count) missing")</dd>\n"
        body += "</dl>\n</header>\n"

        if !warns.isEmpty {
            body += "<aside class=\"warn\"><h3>Read with care</h3><ul>"
            body += warns.map { "<li>\(e($0))</li>" }.joined()
            body += "</ul></aside>\n"
        }

        guard let base else {
            body += "<p class=\"note\">No runs to compare: add some with <span class=\"mono\">fwbench compare "
            body += "\(e(project.name)) add RUN…</span>.</p>\n</div>"
            return HTML.page(title: "\(project.name) · fwbench compare", body: body)
        }

        body += tiles(items, base: base, efficient: efficient)
        body += runLines(items, base: base)
        body += barCharts(items, base: base, efficient: efficient, skipped: skipped)
        body += differenceTable(items, base: base)
        body += "<footer>\(e(CompareProject.fileName(for: project.name))) · fwbench compare</footer>\n</div>"
        return HTML.page(title: "\(project.name) · fwbench compare", meta: [("fwhelper-compare", project.name)],
                         body: body)
    }

    private static func powerText(_ it: Item) -> String {
        guard let p = it.power else { return "power —" }
        return "\(HTML.number(p, digits: 1)) W" + (it.summary.powerColumn == "gpu_w" ? " GPU-only" : "")
    }

    private static func tile(_ eyebrow: String, _ value: String, _ detail: String, hint: String = "") -> String {
        var t = "<div class=\"tile\"><div class=\"eyebrow\">\(HTML.escape(eyebrow))</div><div class=\"k\">\(value)</div>"
        if !detail.isEmpty { t += "<div class=\"d\">\(HTML.escape(detail))</div>" }
        if !hint.isEmpty { t += "<div class=\"hint\">\(HTML.escape(hint))</div>" }
        return t + "</div>"
    }

    private static func tiles(_ items: [Item], base: Item, efficient: [Item]) -> String {
        var out = "<div class=\"tiles\" style=\"--tiles:3\">"
        let baseFPS = base.summary.medianFPS
        if let fastest = items.filter({ $0.summary.medianFPS != nil }).max(by: { $0.summary.medianFPS! < $1.summary.medianFPS! }) {
            let isBase = fastest.bundle.url == base.bundle.url
            // A no-break space keeps "%" with its number when the detail wraps.
            let g = isBase ? "the baseline"
                : "\(gain(fastest.summary.medianFPS, baseline: baseFPS).replacingOccurrences(of: " %", with: "\u{00A0}%")) vs baseline"
            out += tile("Fastest", "\(HTML.number(fastest.summary.medianFPS, digits: 1))<small> fps</small>",
                        "\(fastest.label) · \(g)")
        } else {
            out += tile("Fastest", dash, "no FPS recorded")
        }
        out += tile("Baseline", "\(HTML.number(baseFPS, digits: 1))<small> fps</small>", base.label)
        if let best = efficient.max(by: { $0.summary.fpsPerWatt! < $1.summary.fpsPerWatt! }) {
            let gpuOnly = best.summary.powerColumn == "gpu_w"
            out += tile("Most efficient", "\(HTML.number(best.summary.fpsPerWatt, digits: 2))<small> FPS/W</small>",
                        best.label, hint: gpuOnly ? "GPU-only power, under-reads" : "")
        } else {
            out += tile("Most efficient", dash, "no FPS and power for the same runs")
        }
        return out + "</div>\n"
    }

    private static func runLines(_ items: [Item], base: Item) -> String {
        var out = "<section><div class=\"section-head\"><div class=\"eyebrow\">Runs</div></div><ol class=\"runs\">"
        for it in items {
            let isBase = it.bundle.url == base.bundle.url
            let g = isBase ? "baseline" : gain(it.summary.medianFPS, baseline: base.summary.medianFPS)
            let line = "\(it.label): \(HTML.number(it.summary.medianFPS, digits: 1)) fps median (\(g)), "
                + "1 % low \(HTML.number(it.summary.low1, digits: 1)), \(powerText(it))"
            out += "<li\(isBase ? " class=\"base\"" : "")>\(HTML.escape(line))"
            out += "<span class=\"key\">\(HTML.escape(it.bundle.url.lastPathComponent))</span></li>"
        }
        return out + "</ol></section>\n"
    }

    /// Bar labels sit in a fixed column; long names are cut (the hover title keeps the full name).
    private static func short(_ s: String) -> String { s.count > 26 ? String(s.prefix(25)) + "…" : s }

    private static func barCharts(_ items: [Item], base: Item, efficient: [Item], skipped: [Item]) -> String {
        func baseNote(_ it: Item) -> String { it.bundle.url == base.bundle.url ? "baseline" : "" }
        func join(_ parts: String...) -> String { parts.filter { !$0.isEmpty }.joined(separator: " · ") }

        var out = "<section><div class=\"section-head\"><div class=\"eyebrow\">Side by side</div></div>\n"
        out += "<div class=\"chart\"><h3>Median FPS</h3>"
        out += HTML.bars(items.map { it in
            (label: short(it.label), value: it.summary.medianFPS,
             note: join(baseNote(it), "1 % low \(HTML.number(it.summary.low1, digits: 1))"))
        }, unit: "fps")
        out += "</div>\n"

        if items.contains(where: { $0.power != nil }) {
            out += "<div class=\"chart\"><h3>Mean power</h3>"
            out += HTML.bars(items.map { it in
                let kind = it.summary.powerColumn == "gpu_w" ? "GPU only (IOReport, under-reads)"
                    : it.summary.powerColumn == nil ? "" : "system"
                return (label: short(it.label), value: it.power, note: join(baseNote(it), kind))
            }, unit: "W")
            if items.contains(where: { $0.summary.powerColumn == "gpu_w" }) {
                out += "<p class=\"note\">\(HTML.escape(SummaryReport.gpuCaption))</p>"
            }
            out += "</div>\n"
        }

        if !efficient.isEmpty {
            out += "<div class=\"chart\"><h3>FPS per watt</h3>"
            out += HTML.bars(efficient.map { (label: short($0.label), value: $0.summary.fpsPerWatt, note: baseNote($0)) },
                             unit: "FPS/W", digits: 2)
            if !skipped.isEmpty {
                let names = skipped.map(\.label).joined(separator: ", ")
                out += "<p class=\"note\">Left out, power measured differently: \(HTML.escape(names)).</p>"
            }
            out += "</div>\n"
        }
        return out + "</section>\n"
    }

    private static func differenceTable(_ items: [Item], base: Item) -> String {
        let e = HTML.escape
        let infos = items.map(\.bundle.info)
        let diffs = differences(infos)
        let baseIndex = items.firstIndex { $0.bundle.url == base.bundle.url } ?? 0
        var out = "<section><div class=\"section-head\"><div class=\"eyebrow\">What differs</div>"
        if diffs.isEmpty {
            out += "<p class=\"note\">No recorded setting differs between these runs.</p></div>"
        } else {
            out += "<p class=\"note\">Highlighted cells differ from the baseline.</p></div>"
            out += "<div class=\"tbl text\"><table><thead><tr><th></th>"
            for (n, it) in items.enumerated() {
                out += "<th>\(n + 1) · \(e(it.label))\(n == baseIndex ? " <span class=\"key\">baseline</span>" : "")</th>"
            }
            out += "</tr></thead><tbody>"
            for d in diffs {
                out += "<tr><td>\(e(capitalised(d.field)))</td>"
                for v in d.values {
                    out += v == d.values[baseIndex] ? "<td>\(e(v))</td>" : "<td class=\"diff\">\(e(v))</td>"
                }
                out += "</tr>"
            }
            out += "</tbody></table></div>"
        }
        let same = shared(infos)
        if !same.isEmpty {
            out += "<p class=\"note\"><strong>Same in every run:</strong> "
            out += same.map { "\(e(capitalised($0.field))): \(e($0.value))" }.joined(separator: "; ") + "</p>"
        }
        return out + "</section>\n"
    }

    private static func capitalised(_ s: String) -> String {
        s.hasPrefix("macOS") ? s : s.prefix(1).uppercased() + s.dropFirst()
    }
}
