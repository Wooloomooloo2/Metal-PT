import MPTApp
import MPTCore
import SwiftUI

// MARK: - Formatting

enum Fmt {
    /// "58", or "–" when unknown.
    static func int(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "–" }
        return String(Int(v.rounded()))
    }

    /// "01:23" (or "1:02:03").
    static func elapsed(_ s: Double) -> String {
        let t = max(0, Int(s))
        let h = t / 3600, m = (t / 60) % 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }

    /// "Protium · FEX · DXMT"; "native"; nil when unknown (still detecting).
    static func stack(_ s: Stack?) -> String? {
        guard let s else { return nil }
        var parts: [String] = []
        if let r = s.runtime { parts.append(r) }
        if let t = s.translator { parts.append(t) }
        parts += s.graphics
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// System power (SMC `PSTR`), watts.
    static func systemW(_ sample: TelemetrySample) -> Double? { sample.smcPower["PSTR"] }
}

// MARK: - Chart palette

/// Series colours for the Live charts: system colours (they adapt to light and dark), chosen to stay distinct for
/// the common colour-vision deficiencies (blue/orange carry the main pairs; green and purple are the third and
/// fourth). The same quantity keeps its colour on every chart: GPU is always orange.
enum ChartPalette {
    static let primary = Color.blue
    static let gpu = Color.orange
    static let third = Color.green
    static let fourth = Color.purple
}

// MARK: - Shared pieces

/// Followed game and its stack, or what to do when there is none.
struct GameHeader: View {
    @ObservedObject var model: AppModel
    @ObservedObject var hub: TelemetryHub
    var large = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                if let app = hub.latest?.followedApp, hub.latest?.followedPID != nil {
                    Text(app)
                        .font(large ? .title2.weight(.semibold) : .headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(Fmt.stack(hub.latest?.stack) ?? "Detecting stack…")
                        .font(large ? .body : .subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No game detected")
                        .font(large ? .title2.weight(.semibold) : .headline)
                    Text(model.fpsLoggingOn
                         ? "Start a game now; games started before FPS logging was on are not seen."
                         : "Turn on FPS logging in Settings, then start the game.")
                        .font(large ? .body : .subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            RecordingBadge(model: model, hub: hub)
        }
    }
}

/// "● REC 01:23" while recording, "Saving…" while finishing.
struct RecordingBadge: View {
    @ObservedObject var model: AppModel
    @ObservedObject var hub: TelemetryHub

    var body: some View {
        switch model.recordState {
        case .idle:
            EmptyView()
        case .starting:
            Label("Starting…", systemImage: "record.circle")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        case .recording:
            HStack(spacing: 4) {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text("REC \(Fmt.elapsed(hub.recording?.elapsed ?? 0))").monospacedDigit()
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.red)
        case .saving:
            Label("Saving…", systemImage: "square.and.arrow.down")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
    }
}

/// Record / Stop, with the hotkey as a hint.
struct RecordButton: View {
    @ObservedObject var model: AppModel
    var fullWidth = false

    var body: some View {
        let recording = model.recordState == .recording || model.recordState == .starting
        Button {
            model.toggleRecording()
        } label: {
            HStack {
                Image(systemName: recording ? "stop.fill" : "record.circle")
                Text(recording ? "Stop recording" : "Record")
                if fullWidth { Spacer(minLength: 4) }
                // On a prominent (filled) button `.secondary` is low-contrast; white at reduced opacity reads.
                Text(model.recordCombo.display).foregroundStyle(.white.opacity(0.75))
            }
            .frame(maxWidth: fullWidth ? .infinity : nil)
        }
        .controlSize(.large)
        .tint(recording ? .red : .accentColor)
        .buttonStyle(.borderedProminent)
        .disabled(model.recordState == .saving)
    }
}

/// Warnings: FPS logging lease, log stream, a game not reporting frames, hotkeys, recording start.
struct ProblemsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var hub: TelemetryHub

    private var lines: [String] {
        var l: [String] = []
        if let e = model.fpsLoggingError { l.append("FPS logging: \(e)") }
        if let e = hub.streamError { l.append("FPS log stream: \(e)") }
        if let w = model.frameReportingWarning { l.append(w) }
        l += model.hotkeyProblems
        if let e = model.recordingProblem { l.append(e) }
        return l
    }

    var body: some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(lines, id: \.self) { line in
                    Label {
                        Text(line).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
            }
            .font(.caption)
        }
    }
}
