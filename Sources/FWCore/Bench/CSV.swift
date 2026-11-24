import Foundation

public enum CSV {
    private static let posix = Locale(identifier: "en_US_POSIX")

    /// RFC-4180 line (no trailing newline): fields containing `,` `"` or a newline are quoted.
    public static func line(_ fields: [String]) -> String {
        fields.map { f in
            guard f.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return f }
            return "\"" + f.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }.joined(separator: ",")
    }

    /// Parses text with a header row into rows keyed by header name. Rows may be shorter than the
    /// header (missing keys); extra cells are ignored. Blank lines are skipped.
    public static func parse(_ text: String) -> [[String: String]] {
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var inQuotes = false
        var sawAny = false
        var chars = Array(text.unicodeScalars)
        chars.append("\u{0}")  // sentinel so the last record always terminates
        var i = 0
        let end = chars.count - 1
        func endRecord() {
            if sawAny { record.append(field); records.append(record) }
            record = []; field = ""; sawAny = false
        }
        while i < end {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < end, chars[i + 1] == "\"" { field.unicodeScalars.append("\""); i += 1 } else { inQuotes = false }
                } else { field.unicodeScalars.append(c) }
            } else if c == "\"" {
                inQuotes = true; sawAny = true
            } else if c == "," {
                record.append(field); field = ""; sawAny = true
            } else if c == "\n" {
                endRecord()
            } else if c == "\r" {
                // handled with the following \n, or as a lone terminator
                if !(i + 1 < end && chars[i + 1] == "\n") { endRecord() }
            } else {
                field.unicodeScalars.append(c); sawAny = true
            }
            i += 1
        }
        endRecord()
        guard let header = records.first else { return [] }
        return records.dropFirst().map { r in
            var row: [String: String] = [:]
            for (k, name) in header.enumerated() where k < r.count { row[name] = r[k] }
            return row
        }
    }

    /// Fixed-point with `.` decimal separator and no grouping, regardless of locale. nil/non-finite → "".
    public static func number(_ value: Double?, digits: Int) -> String {
        guard let value, value.isFinite else { return "" }
        return String(format: "%.\(max(0, digits))f", locale: posix, value)
    }
}

public enum SampleColumns {
    public static let all: [String] = [
        "t", "elapsed_s", "fps", "fps_pid", "fps_app", "ft_p99_ms", "ft_max_ms", "gpu_w",
        "cpu_p_util_pct", "cpu_e_util_pct", "cpu_core_max_pct", "gpu_busy_pct",
        "smc_PSTR_w", "smc_PDTR_w", "smc_PHPC_w", "smc_PHPS_w", "smc_PSVR_w", "smc_PZC0_w", "smc_PZC1_w",
        "smc_PMVC_w", "smc_PPMC_w", "smc_PPSC_w",
        "temp_max_c", "temp_battery_c", "fan0_rpm", "fan1_rpm", "mem_used_gb", "battery_pct", "battery_w",
        "on_ac", "thermal_state",
    ]

    static func digits(for column: String) -> Int {
        switch column {
        case "battery_pct", "fan0_rpm", "fan1_rpm": return 0
        case "fps", "fps_pid", "elapsed_s": return 1
        case "mem_used_gb": return 2
        default:
            if column.hasSuffix("_pct") || column.hasSuffix("_c") { return 1 }
            if column.hasSuffix("_rpm") { return 0 }
            return 2  // *_ms, *_w
        }
    }

    /// Formats a numeric cell by column name (R3 digits). nil → "".
    public static func format(_ value: Double?, column: String) -> String {
        CSV.number(value, digits: digits(for: column))
    }

    public static func format(onAC: Bool?) -> String { onAC.map { $0 ? "1" : "0" } ?? "" }

    /// ISO-8601 UTC with milliseconds, for the `t` column.
    public static func timestamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}
