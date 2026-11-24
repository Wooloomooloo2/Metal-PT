import Foundation

/// Building blocks for the static HTML reports: escaping, one stylesheet with light/dark tokens, and inline SVG
/// charts. Output never references the network and contains no script; hover text comes from SVG `<title>`.
public enum HTML {
    // MARK: - Text

    public static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for c in text {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(c)
            }
        }
        return out
    }

    /// Fixed-point, `.` decimal point; nil or non-finite → "—".
    public static func number(_ value: Double?, digits: Int) -> String {
        let s = CSV.number(value, digits: digits)
        return s.isEmpty ? "—" : s
    }

    /// `m:ss`, or `h:mm:ss` from one hour.
    public static func duration(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// A complete document: the shared stylesheet, `<meta name=… content=…>` tags (escaped), and `body` (raw).
    public static func page(title: String, meta: [(name: String, content: String)] = [], body: String) -> String {
        var out = "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n"
        out += "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
        out += "<meta name=\"color-scheme\" content=\"light dark\">\n"
        for m in meta { out += "<meta name=\"\(escape(m.name))\" content=\"\(escape(m.content))\">\n" }
        out += "<title>\(escape(title))</title>\n<style>\n\(css)</style>\n</head>\n<body>\n\(body)\n</body>\n</html>\n"
        return out
    }

    // MARK: - Stylesheet

    private static let lightTokens = """
          --bg: #f7f8f9; --panel: #ffffff; --ink: #15171a; --ink-2: #4d525a; --ink-3: #747a84;
          --rule: #dfe2e6; --grid: #eceef1; --axis: #c9cdd3; --shade: rgba(21, 23, 26, 0.05);
          --hover: rgba(42, 120, 214, 0.10); --warn: #8a5d00; --warn-bg: #fdf6e7; --warn-rule: #ecd9ab;
          --s1: #2a78d6; --s2: #eb6834; --s3: #1baf7a; --s4: #6250d6; --s5: #e34948; --s6: #008300;
        """
    private static let darkTokens = """
          --bg: #131518; --panel: #1b1e22; --ink: #eef0f2; --ink-2: #b8bdc5; --ink-3: #8a909a;
          --rule: #2e3238; --grid: #252a30; --axis: #3a3f46; --shade: rgba(255, 255, 255, 0.05);
          --hover: rgba(57, 135, 229, 0.16); --warn: #e0b04a; --warn-bg: #2a2416; --warn-rule: #4a3d1c;
          --s1: #3987e5; --s2: #d95926; --s3: #199e70; --s4: #9085e9; --s5: #e66767; --s6: #0ca30c;
          color-scheme: dark;
        """

    /// One stylesheet for every report. Series colours are `--s1`…`--s6` (fixed order, never cycled).
    public static let css = """
        :root {
        \(lightTokens)
          --f-body: -apple-system, system-ui, sans-serif;
          --f-mono: ui-monospace, "SF Mono", Menlo, monospace;
        }
        @media (prefers-color-scheme: dark) {
          :root:not([data-theme="light"]) {
        \(darkTokens)
          }
        }
        :root[data-theme="dark"] {
        \(darkTokens)
        }
        * { box-sizing: border-box; }
        body { margin: 0; background: var(--bg); color: var(--ink); font: 15px/1.5 var(--f-body);
          -webkit-font-smoothing: antialiased; }
        .wrap { max-width: 780px; margin: 0 auto; padding: 36px 16px 56px; display: flex; flex-direction: column;
          gap: 28px; }
        h1, h2, h3 { margin: 0; letter-spacing: -0.01em; text-wrap: balance; }
        h1 { font-size: 1.9rem; line-height: 1.15; font-weight: 650; }
        h2 { font-size: 1.05rem; font-weight: 600; }
        p { margin: 0; max-width: 68ch; }
        .eyebrow { font: 500 0.7rem/1.2 var(--f-mono); text-transform: uppercase; letter-spacing: 0.08em;
          color: var(--ink-3); }
        header { display: flex; flex-direction: column; gap: 10px; }
        .lede { color: var(--ink-2); font-size: 1.05rem; }
        .mono { font-family: var(--f-mono); font-size: 0.9em; }
        dl.meta { display: grid; grid-template-columns: max-content 1fr; gap: 4px 18px; margin: 6px 0 0;
          font-size: 0.88rem; }
        dl.meta dt { color: var(--ink-3); }
        dl.meta dd { margin: 0; color: var(--ink); overflow-wrap: anywhere; }
        .warn { background: var(--warn-bg); border: 1px solid var(--warn-rule); border-radius: 6px;
          padding: 12px 16px; display: flex; flex-direction: column; gap: 6px; }
        .warn h3 { font-size: 0.85rem; font-weight: 600; color: var(--warn); }
        .warn ul { margin: 0; padding-left: 1.1em; font-size: 0.9rem; color: var(--ink-2); }
        .tiles { display: grid; grid-template-columns: repeat(var(--tiles, 5), minmax(0, 1fr)); gap: 10px; }
        .tile { background: var(--panel); border: 1px solid var(--rule); border-radius: 6px; padding: 12px 14px;
          display: flex; flex-direction: column; gap: 4px; min-width: 0; }
        .tile .k { font: 600 1.6rem/1.1 var(--f-body); font-variant-numeric: tabular-nums; letter-spacing: -0.02em; }
        .tile .k small { font-size: 0.85rem; color: var(--ink-3); font-weight: 500; letter-spacing: 0; }
        .tile .d { font-size: 0.78rem; color: var(--ink-2); }
        .tile .hint { font-size: 0.75rem; color: var(--ink-3); font-style: italic; }
        section { display: flex; flex-direction: column; gap: 10px; }
        .section-head { display: flex; flex-direction: column; gap: 2px; }
        .note { font-size: 0.82rem; color: var(--ink-3); }
        .chart { background: var(--panel); border: 1px solid var(--rule); border-radius: 6px; padding: 12px 12px 6px;
          display: flex; flex-direction: column; gap: 4px; break-inside: avoid; }
        .chart h3 { font-size: 0.85rem; font-weight: 600; color: var(--ink-2); padding: 0 4px; }
        .chart svg { display: block; width: 100%; height: auto; font-family: var(--f-mono); }
        .chart svg text { font-size: 10.5px; fill: var(--ink-3); }
        .chart svg .shade { fill: var(--shade); }
        .chart svg .hit { fill: transparent; }
        .chart svg .hit:hover { fill: var(--hover); }
        .chart svg .gap { fill: var(--ink-3); }
        .legend { display: flex; flex-wrap: wrap; gap: 4px 16px; font-size: 0.78rem; color: var(--ink-2); padding: 0 4px; }
        .legend span { display: inline-flex; align-items: center; gap: 6px; }
        .sw { width: 14px; height: 3px; border-radius: 2px; display: inline-block; }
        .sw.box { width: 11px; height: 11px; border-radius: 2px; border: 1px solid var(--axis); background: var(--shade); }
        .tbl { overflow-x: auto; background: var(--panel); border: 1px solid var(--rule); border-radius: 6px;
          padding: 4px 8px; }
        table { border-collapse: collapse; font-size: 0.84rem; width: 100%; }
        th, td { text-align: right; padding: 6px 8px; border-bottom: 1px solid var(--rule);
          font-variant-numeric: tabular-nums; white-space: nowrap; }
        tr:last-child td { border-bottom: 0; }
        td.num { font-family: var(--f-mono); font-size: 0.95em; }
        th:first-child, td:first-child { text-align: left; }
        th { font-weight: 600; color: var(--ink-2); font-size: 0.75rem; }
        td .key { color: var(--ink-3); font-family: var(--f-mono); font-size: 0.85em; margin-left: 6px; }
        .user { background: var(--panel); border: 1px solid var(--rule); border-radius: 6px; padding: 12px 16px;
          display: flex; flex-direction: column; gap: 8px; font-size: 0.9rem; }
        .user p { white-space: pre-wrap; color: var(--ink-2); }
        footer { font-size: 0.75rem; color: var(--ink-3); font-family: var(--f-mono); }
        @media (max-width: 640px) {
          .tiles { grid-template-columns: repeat(2, minmax(0, 1fr)); }
          h1 { font-size: 1.5rem; }
        }
        @media print {
          body { background: #fff; }
          .wrap { padding: 0; max-width: none; }
          .chart, .tile, .tbl, .warn, .user { break-inside: avoid; }
        }

        """

    // MARK: - Charts

    private static let chartWidth = 720.0

    /// Series colour slot `i` (0-based).
    public static func seriesColor(_ i: Int) -> String { "var(--s\(min(i, 5) + 1))" }

    /// A legend row: a line swatch per series (shown for two or more series), plus extra raw HTML items.
    public static func legend(_ names: [String], extra: String = "") -> String {
        guard names.count >= 2 || !extra.isEmpty else { return "" }
        var out = "<div class=\"legend\">"
        if names.count >= 2 {
            for (i, n) in names.enumerated() {
                out += "<span><i class=\"sw\" style=\"background:\(seriesColor(i))\"></i>\(escape(n))</span>"
            }
        }
        return out + extra + "</div>"
    }

    /// A 1-2-5 step that splits `span` into about `count` intervals.
    static func niceStep(_ span: Double, count: Double) -> Double {
        guard span > 0, span.isFinite else { return 1 }
        let raw = span / count
        let mag = pow(10, floor(log10(raw)))
        for m in [1.0, 2, 2.5, 5, 10] where m * mag >= raw { return m * mag }
        return 10 * mag
    }

    /// Time axis step in seconds, in steps a reader can count.
    static func timeStep(_ span: Double) -> Double {
        let raw = span / 6
        for s in [1.0, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600] where s >= raw { return s }
        return 3600 * ceil(raw / 3600)
    }

    /// Decimals needed to print multiples of `step` exactly (2.5 → 1, 0.25 → 2, 5 → 0).
    static func decimals(_ step: Double) -> Int {
        var d = 0
        while d < 4 && abs((step * pow(10, Double(d))).rounded() - step * pow(10, Double(d))) > 1e-6 { d += 1 }
        return d
    }

    private static func f(_ v: Double) -> String { CSV.number(v, digits: 1) }

    /// A static line chart over time. `values[i]` is plotted at `x[i]` (elapsed seconds; index when `x` is nil).
    /// nil values break the line. Indices not in `steady` are shaded. `yMin`/`yMax` pin the scale (otherwise the
    /// axis starts at 0 when the data are close enough to it). `reference` draws a dashed horizontal line.
    /// `minSpan` keeps a nearly flat series from being blown up into noise (the scale grows around the data).
    /// Hovering shows the values of the column under the pointer (`<title>`, no script).
    public static func lineChart(series: [(name: String, values: [Double?])], steady: [Int], unit: String,
                                 x: [Double]? = nil, yMin: Double? = nil, yMax: Double? = nil,
                                 reference: (label: String, value: Double)? = nil, digits: Int = 1,
                                 minSpan: Double = 0, height: Double = 190) -> String {
        let n = series.map(\.values.count).max() ?? 0
        let xs: [Double] = (0..<n).map { i in x.flatMap { i < $0.count && $0[i].isFinite ? $0[i] : nil } ?? Double(i) }
        let left = 58.0, right = 14.0, top = 12.0, bottom = 24.0
        let pw = chartWidth - left - right, ph = height - top - bottom

        // Scales.
        let all = series.flatMap { $0.values.compactMap { $0 } }.filter(\.isFinite) + (reference.map { [$0.value] } ?? [])
        var lo = yMin ?? all.min() ?? 0
        var hi = yMax ?? all.max() ?? 1
        if yMin == nil, lo >= 0, lo <= hi * 0.6 { lo = 0 }
        if hi - lo < minSpan {
            switch (yMin, yMax) {
            case (nil, nil):
                let mid = (lo + hi) / 2, nonNegative = lo >= 0
                lo = mid - minSpan / 2; hi = mid + minSpan / 2
                if nonNegative && lo < 0 { hi -= lo; lo = 0 }
            case (_?, nil): hi = lo + minSpan
            case (nil, _?): lo = hi - minSpan
            default: break
            }
        }
        if hi <= lo { hi = lo + (lo == 0 ? 1 : abs(lo) * 0.1) }
        let step = niceStep(hi - lo, count: 4)
        if yMin == nil { lo = floor(lo / step) * step }
        if yMax == nil { hi = ceil(hi / step - 1e-9) * step }
        if hi <= lo { hi = lo + step }
        // Time starts at 0 so the axis reads as "seconds into the run".
        let x0 = min(xs.first ?? 0, 0)
        var x1 = xs.max() ?? 1
        if x1 <= x0 { x1 = x0 + 1 }
        func px(_ v: Double) -> Double { left + (v - x0) / (x1 - x0) * pw }
        func py(_ v: Double) -> Double { top + (1 - (v - lo) / (hi - lo)) * ph }

        var svg = "<svg viewBox=\"0 0 \(f(chartWidth)) \(f(height))\" role=\"img\" aria-label=\""
        svg += escape(series.map(\.name).joined(separator: ", ")) + " over time\">"

        // Non-steady shading: contiguous runs of non-steady indices, each half a sample wide on either side.
        let steadySet = Set(steady)
        let half = n > 1 ? (x1 - x0) / Double(n - 1) / 2 : 0.5
        var i = 0
        while i < n {
            guard !steadySet.contains(i) else { i += 1; continue }
            var j = i
            while j + 1 < n && !steadySet.contains(j + 1) { j += 1 }
            let a = max(left, px(xs[i] - half)), b = min(left + pw, px(xs[j] + half))
            if b > a {
                svg += "<rect class=\"shade\" x=\"\(f(a))\" y=\"\(f(top))\" width=\"\(f(b - a))\" height=\"\(f(ph))\"/>"
            }
            i = j + 1
        }

        // Grid and y labels.
        var t = lo
        while t <= hi + step * 1e-6 {
            let y = py(t)
            let stroke = abs(t - lo) < step * 1e-6 ? "var(--axis)" : "var(--grid)"
            svg += "<line x1=\"\(f(left))\" x2=\"\(f(left + pw))\" y1=\"\(f(y))\" y2=\"\(f(y))\" stroke=\"\(stroke)\" stroke-width=\"1\"/>"
            let label = CSV.number(t, digits: decimals(step))
            let isTop = t + step > hi + step * 1e-6
            svg += "<text x=\"\(f(left - 6))\" y=\"\(f(y + 3.5))\" text-anchor=\"end\">\(label)\(isTop ? " " + escape(unit) : "")</text>"
            t += step
        }
        // X labels.
        let ts = timeStep(x1 - x0)
        let minutes = ts >= 60
        var tx = ceil(x0 / ts) * ts
        var xticks: [Double] = []
        while tx <= x1 + 1e-9 { xticks.append(tx); tx += ts }
        for (k, v) in xticks.enumerated() {
            let last = k == xticks.count - 1
            let text = minutes ? "\(Int(v / 60))\(last ? " min" : "")" : "\(Int(v))\(last ? " s" : "")"
            let anchor = last && px(v) > left + pw - 20 ? "end" : "middle"
            svg += "<line x1=\"\(f(px(v)))\" x2=\"\(f(px(v)))\" y1=\"\(f(top + ph))\" y2=\"\(f(top + ph + 4))\" stroke=\"var(--axis)\"/>"
            svg += "<text x=\"\(f(px(v)))\" y=\"\(f(top + ph + 16))\" text-anchor=\"\(anchor)\">\(text)</text>"
        }

        // Reference line.
        if let reference, reference.value.isFinite, reference.value >= lo, reference.value <= hi {
            let y = py(reference.value)
            svg += "<line x1=\"\(f(left))\" x2=\"\(f(left + pw))\" y1=\"\(f(y))\" y2=\"\(f(y))\" stroke=\"var(--ink-3)\" stroke-width=\"1\" stroke-dasharray=\"4 3\"/>"
            svg += "<text x=\"\(f(left + pw - 4))\" y=\"\(f(y - 5))\" text-anchor=\"end\">\(escape(reference.label))</text>"
        }

        // Lines: a new subpath after every gap; a lone point is a round-capped zero-length segment.
        for (k, s) in series.enumerated() {
            var d = ""
            var pen = false
            var segmentLength = 0
            for (idx, v) in s.values.enumerated() {
                guard let v, v.isFinite, idx < n else {
                    if pen && segmentLength == 1 { d += "h0" }
                    pen = false; continue
                }
                let p = "\(f(px(xs[idx]))) \(f(py(min(max(v, lo), hi))))"
                if pen { d += "L\(p)"; segmentLength += 1 } else { d += "M\(p)"; pen = true; segmentLength = 1 }
            }
            if pen && segmentLength == 1 { d += "h0" }
            guard !d.isEmpty else { continue }
            svg += "<path d=\"\(d)\" fill=\"none\" stroke=\"\(seriesColor(k))\" stroke-width=\"2\" stroke-linejoin=\"round\" stroke-linecap=\"round\"/>"
        }

        // Hover bands, at most ~240 per chart; wider bands show their mean.
        let bucket = max(1, Int((Double(n) / 240).rounded(.up)))
        var b = 0
        while b < n {
            let e = min(n, b + bucket) - 1
            let a = max(left, px(xs[b] - half)), z = min(left + pw, px(xs[e] + half))
            var tip = bucket == 1 ? "\(Int(xs[b].rounded())) s" : "\(Int(xs[b].rounded()))–\(Int(xs[e].rounded())) s"
            if !steadySet.contains(b) { tip += " (not steady)" }
            for s in series {
                let vals = (b...e).compactMap { $0 < s.values.count ? s.values[$0] : nil }.filter(\.isFinite)
                let v = vals.isEmpty ? nil : vals.reduce(0, +) / Double(vals.count)
                tip += "\n\(s.name): \(number(v, digits: digits))\(v == nil ? "" : " " + unit)"
            }
            if z > a {
                svg += "<rect class=\"hit\" x=\"\(f(a))\" y=\"\(f(top))\" width=\"\(f(z - a))\" height=\"\(f(ph))\"><title>\(escape(tip))</title></rect>"
            }
            b = e + 1
        }
        svg += "</svg>"
        return legend(series.map(\.name)) + svg
    }

    /// Horizontal bars, one row per item, scaled from 0 to the largest value. nil values show "—".
    /// `note` is a muted second line under the label.
    public static func bars(_ items: [(label: String, value: Double?, note: String)], unit: String,
                            digits: Int = 1) -> String {
        let row = 34.0, left = 200.0, right = 90.0, top = 6.0
        let height = top + Double(items.count) * row + 4
        let maxV = max(items.compactMap(\.value).filter(\.isFinite).max() ?? 1, 1e-9)
        let pw = chartWidth - left - right
        var svg = "<svg viewBox=\"0 0 \(f(chartWidth)) \(f(height))\" role=\"img\" aria-label=\"\(escape(unit)) by item\">"
        for (k, item) in items.enumerated() {
            let y = top + Double(k) * row
            let barH = 14.0, by = y + (row - barH) / 2 - 2
            svg += "<g><title>\(escape(item.label)): \(number(item.value, digits: digits)) \(escape(unit))"
            svg += item.note.isEmpty ? "" : "\n\(escape(item.note))"
            svg += "</title><rect class=\"hit\" x=\"0\" y=\"\(f(y))\" width=\"\(f(chartWidth))\" height=\"\(f(row))\"/>"
            let labelY = item.note.isEmpty ? by + barH - 3 : by + 6
            svg += "<text x=\"0\" y=\"\(f(labelY))\" style=\"fill:var(--ink);font-family:var(--f-body);font-size:12px\">\(escape(item.label))</text>"
            if !item.note.isEmpty {
                svg += "<text x=\"0\" y=\"\(f(labelY + 14))\" style=\"font-family:var(--f-body)\">\(escape(item.note))</text>"
            }
            if let v = item.value, v.isFinite {
                let w = max(0, v / maxV * pw)
                svg += "<rect x=\"\(f(left))\" y=\"\(f(by))\" width=\"\(f(w))\" height=\"\(f(barH))\" rx=\"2\" fill=\"\(seriesColor(0))\"/>"
                svg += "<text x=\"\(f(left + w + 6))\" y=\"\(f(by + barH - 3))\" style=\"fill:var(--ink)\">\(number(v, digits: digits)) \(escape(unit))</text>"
            } else {
                svg += "<text x=\"\(f(left))\" y=\"\(f(by + barH - 3))\">—</text>"
            }
            svg += "</g>"
        }
        return svg + "</svg>"
    }
}
