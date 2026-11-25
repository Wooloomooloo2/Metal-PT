import MPTApp
import MPTCore
import SwiftUI

// MARK: - Settings

/// Overlay style (Settings, T14): `auto` is the compact strip, expanding to the detailed panel while recording.
enum OverlayStyle: String, CaseIterable, Sendable {
    case auto, compact, detailed

    static let defaultValue = OverlayStyle.auto

    /// `UserDefaults` value, falling back to the default for a missing or unknown value.
    init(setting: String?) { self = setting.flatMap(OverlayStyle.init(rawValue:)) ?? .defaultValue }

    func showsDetailed(recording: Bool) -> Bool {
        switch self {
        case .auto: return recording
        case .compact: return false
        case .detailed: return true
        }
    }
}

/// The screen corner the overlay sits in. Default top-left: Apple's Metal HUD (which must be on for FPS) is top-right.
enum OverlayCorner: String, CaseIterable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight

    static let defaultValue = OverlayCorner.topLeft
    static let inset: CGFloat = 16

    init(setting: String?) { self = setting.flatMap(OverlayCorner.init(rawValue:)) ?? .defaultValue }

    /// The panel frame for content of `size` in `area` (AppKit coordinates, y up), `inset` points from both edges.
    func frame(size: CGSize, in area: CGRect, inset: CGFloat = OverlayCorner.inset) -> CGRect {
        let x: CGFloat, y: CGFloat
        switch self {
        case .topLeft, .bottomLeft: x = area.minX + inset
        case .topRight, .bottomRight: x = area.maxX - inset - size.width
        }
        switch self {
        case .topLeft, .topRight: y = area.maxY - inset - size.height
        case .bottomLeft, .bottomRight: y = area.minY + inset
        }
        return CGRect(origin: CGPoint(x: x.rounded(), y: y.rounded()), size: size)
    }
}

enum OverlayDefaults {
    /// "Background opacity": the background's alpha (0…1). Text stays fully opaque.
    static let opacity = 0.6
}

// MARK: - Text

/// The overlay's numbers as text (pure, unit-tested). Unknown values are left out of the strip rather than shown
/// as dashes, except FPS (always there, "–" without a game). No 1 % low (ruling R8): per-frame times are only in
/// recorded runs.
struct OverlayNumbers: Equatable {
    /// Recording elapsed seconds; nil when not recording.
    var recordingElapsed: Double?
    /// nil when no game is followed or no frames yet.
    var fps: Double?
    var systemW: Double?
    /// Mean FPS / mean system W over the last 10 s (`LiveEfficiency`); nil when not following or unknown.
    var fpsPerWatt: Double?
    var gpuPct: Double?
    var cpuPPct: Double?
    var cpuEPct: Double?
    var dieC: Double?
    var fanRPM: [Double] = []
    var stack: String?
    var app: String?

    init(recordingElapsed: Double? = nil, fps: Double? = nil, systemW: Double? = nil, fpsPerWatt: Double? = nil,
         gpuPct: Double? = nil, cpuPPct: Double? = nil, cpuEPct: Double? = nil, dieC: Double? = nil,
         fanRPM: [Double] = [], stack: String? = nil, app: String? = nil) {
        self.recordingElapsed = recordingElapsed
        self.fps = fps
        self.systemW = systemW
        self.fpsPerWatt = fpsPerWatt
        self.gpuPct = gpuPct
        self.cpuPPct = cpuPPct
        self.cpuEPct = cpuEPct
        self.dieC = dieC
        self.fanRPM = fanRPM
        self.stack = stack
        self.app = app
    }

    /// From the hub: FPS only while a game is followed; elapsed only while `recording`.
    @MainActor
    init(hub: TelemetryHub, recording: Bool) {
        let snap = hub.latest
        let s = snap?.sample
        let following = snap?.followedPID != nil
        self.init(recordingElapsed: recording ? (hub.recording?.elapsed ?? 0) : nil,
                  fps: following ? snap?.fps : nil,
                  systemW: s.flatMap(Fmt.systemW),
                  fpsPerWatt: following ? LiveEfficiency.fpsPerWatt(history: hub.history) : nil,
                  gpuPct: s?.gpuBusyPct,
                  cpuPPct: s?.cpuPUtilPct, cpuEPct: s?.cpuEUtilPct, dieC: s?.tempMaxC,
                  fanRPM: s?.fanRPM ?? [],
                  stack: following ? Fmt.stack(snap?.stack) : nil,
                  app: following ? snap?.followedApp : nil)
    }

    private static func known(_ v: Double?) -> Double? {
        guard let v, v.isFinite else { return nil }
        return v
    }

    /// "● 01:23" while recording.
    var recText: String? { recordingElapsed.map { "● \(Fmt.elapsed($0))" } }

    /// The strip after the recording mark: "58 fps · 41 W · GPU 92% · 78 °C".
    var stripParts: [String] {
        var p = ["\(Fmt.int(fps)) fps"]
        if let v = Self.known(systemW) { p.append("\(Fmt.int(v)) W") }
        if let v = Self.known(gpuPct) { p.append("GPU \(Fmt.int(v))%") }
        if let v = Self.known(dieC) { p.append("\(Fmt.int(v)) °C") }
        return p
    }

    /// Detailed panel rows under the big FPS (rows with nothing known are left out).
    var detailLines: [String] {
        var lines: [String] = []
        if let f = Self.known(fps), f > 0 { lines.append(String(format: "avg frame %.1f ms", 1000 / f)) }
        lines.append(Self.pair("System", systemW, "W", "GPU", gpuPct, "%"))
        lines.append("FPS/W \(LiveEfficiency.text(fpsPerWatt))")
        lines.append(Self.pair("CPU P", cpuPPct, "%", "E", cpuEPct, "%"))
        var thermal = "Die \(Self.known(dieC).map { "\(Fmt.int($0)) °C" } ?? "–")"
        if let fan = fanRPM.filter(\.isFinite).max() { thermal += " · fans \(Fmt.int(fan))" }
        lines.append(thermal)
        return lines
    }

    /// "System 41 W · GPU 92%" (with "–" for unknown halves, without a space before "%").
    private static func pair(_ a: String, _ av: Double?, _ au: String, _ b: String, _ bv: Double?, _ bu: String)
        -> String {
        func v(_ x: Double?, _ u: String) -> String {
            guard let x = known(x) else { return "–" }
            return u == "%" ? "\(Fmt.int(x))%" : "\(Fmt.int(x)) \(u)"
        }
        return "\(a) \(v(av, au)) · \(b) \(v(bv, bu))"
    }

    /// The stack line, or the game, or a hint.
    var stackLine: String {
        if let stack { return stack }
        if app != nil { return "Detecting stack…" }
        return "No game detected"
    }
}

// MARK: - View

/// The in-game overlay content (spec §5, mockup option C): a compact one-line strip, or the detailed panel
/// (always in `detailed` style, while recording in `auto`). Always dark (it sits on games), white text.
struct OverlayView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var hub: TelemetryHub
    @AppStorage(SettingsKey.overlayStyle) private var styleSetting = OverlayStyle.defaultValue.rawValue
    @AppStorage(SettingsKey.overlayOpacity) private var opacity = OverlayDefaults.opacity

    static let sparkWindow = 60.0
    static let detailedWidth: CGFloat = 200

    private var recording: Bool { model.recordState == .recording }

    var body: some View {
        let numbers = OverlayNumbers(hub: hub, recording: recording)
        Group {
            if OverlayStyle(setting: styleSetting).showsDetailed(recording: recording) {
                detailed(numbers)
            } else {
                compact(numbers)
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.5), radius: 1, y: 0.5)
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }

    private static let red = Color(red: 1, green: 0.353, blue: 0.306)

    /// The background's black: the "Background opacity" setting is its alpha, clamped to 0…1 (0.6 default); text
    /// stays fully opaque so it reads over bright scenes.
    nonisolated static func backgroundAlpha(_ setting: Double) -> Double {
        setting.isNaN ? OverlayDefaults.opacity : min(1, max(0, setting))
    }

    /// "60 %", as Settings labels the slider.
    nonisolated static func opacityPercent(_ setting: Double) -> String {
        "\(Int((backgroundAlpha(setting) * 100).rounded())) %"
    }

    private var background: Color { .black.opacity(Self.backgroundAlpha(opacity)) }

    private func compact(_ n: OverlayNumbers) -> some View {
        HStack(spacing: 8) {
            if let rec = n.recText {
                Text(rec).foregroundStyle(Self.red)
            }
            Text(n.stripParts.joined(separator: " · "))
        }
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .monospacedDigit()
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(background))
    }

    private func detailed(_ n: OverlayNumbers) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(Fmt.int(n.fps)).font(.system(size: 20, weight: .bold, design: .monospaced))
                    Text("fps").font(.system(size: 11, design: .monospaced)).opacity(0.7)
                }
                Spacer(minLength: 6)
                if let e = n.recordingElapsed {
                    Text("● REC \(Fmt.elapsed(e))").foregroundStyle(Self.red)
                }
            }
            FPSSparkline(points: sparkPoints)
                .frame(height: 22)
                .padding(.vertical, 1)
            ForEach(n.detailLines, id: \.self) { Text($0) }
            Text(n.stackLine).opacity(0.7).lineLimit(1).truncationMode(.middle)
        }
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .monospacedDigit()
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: Self.detailedWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(background))
    }

    /// FPS over the last 60 s (only while a game is followed).
    private var sparkPoints: [LivePoint] {
        guard hub.latest?.followedPID != nil else { return [] }
        return LiveSeries.points(hub.history) { $0.fps }.filter { $0.secondsAgo >= -Self.sparkWindow }
    }
}

/// A minimal line of FPS (x = −60…0 s; y spans the data with headroom so dips show), broken at gaps.
private struct FPSSparkline: View {
    let points: [LivePoint]

    var body: some View {
        Canvas { ctx, size in
            guard !points.isEmpty else { return }
            let values = points.map(\.value)
            let hi = (values.max() ?? 0) + 4
            let lo = max(0, min(values.min() ?? 0, hi - 20) - 4)
            var path = Path()
            var segment: Int?
            for p in points {
                let pt = CGPoint(x: size.width * (1 + p.secondsAgo / OverlayView.sparkWindow),
                                 y: size.height * (1 - min(1, max(0, (p.value - lo) / (hi - lo)))))
                if segment == p.segment { path.addLine(to: pt) } else { path.move(to: pt) }
                segment = p.segment
            }
            ctx.stroke(path, with: .color(Color(red: 0.5, green: 0.82, blue: 1)),
                       style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }
}
