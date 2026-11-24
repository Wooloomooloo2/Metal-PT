import AppKit
import MPTApp
import MPTCore
import SwiftUI

/// The menu-bar item's title: red "● 02:31 · 35 fps" while recording ("● starting…" / "saving…" around it), else
/// "◉ 58 fps · 41 W" while a game is followed, else an icon. The elapsed time follows the recording's 1 Hz ticks:
/// no timer of its own.
struct MenuBarLabel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var hub: TelemetryHub

    struct Title: Equatable {
        let text: String
        /// Drawn red (the recording states).
        let recording: Bool
    }

    static func title(state: AppModel.RecordState, status: SessionStatus?, snapshot: HubSnapshot?) -> Title? {
        switch state {
        case .starting:
            return Title(text: "● starting…", recording: true)
        case .saving:
            return Title(text: "saving…", recording: true)
        case .recording:
            var s = "● \(Fmt.elapsed(status?.elapsed ?? 0))"
            if let fps = status?.fps { s += " · \(Fmt.int(fps)) fps" }
            return Title(text: s, recording: true)
        case .idle:
            guard let snapshot, snapshot.followedPID != nil else { return nil }
            var s = "◉ \(Fmt.int(snapshot.fps)) fps"
            if let w = Fmt.systemW(snapshot.sample) { s += " · \(Fmt.int(w)) W" }
            return Title(text: s, recording: false)
        }
    }

    /// `text` drawn red as a non-template image. A `MenuBarExtra` label's `Text` becomes the status item's plain
    /// title and an SF Symbol's palette colours reach only the symbol, so a red title needs an image with
    /// `isTemplate == false` (checked on the real status item: macOS 26, see the task-4 report).
    static func redImage(_ text: String) -> NSImage {
        let r = ImageRenderer(content: Text(text)
            .font(Font(NSFont.menuBarFont(ofSize: 0)))
            .monospacedDigit()
            .foregroundStyle(Color(nsColor: .systemRed)))
        r.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = r.nsImage ?? NSImage()
        image.isTemplate = false
        return image
    }

    var body: some View {
        if let title = Self.title(state: model.recordState, status: hub.recording, snapshot: hub.latest) {
            if title.recording {
                Image(nsImage: Self.redImage(title.text)).accessibilityLabel(title.text)
            } else {
                Text(title.text).monospacedDigit()
            }
        } else {
            Image(systemName: "gauge.with.dots.needle.67percent")
        }
    }
}

/// The menu-bar dropdown (spec §5): current game + stack, live numbers, Record/Stop, overlay, recent runs,
/// Open Metal-PT, Quit.
struct MenuBarView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var hub: TelemetryHub
    @Environment(\.openWindow) private var openWindow

    static let width: CGFloat = 320

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GameHeader(model: model, hub: hub)
            if hub.latest?.followedPID != nil, let snap = hub.latest {
                StatsGrid(snapshot: snap)
            }
            RecordButton(model: model, fullWidth: true)
            ProblemsView(model: model, hub: hub)

            Divider()

            MenuRow(title: "Overlay", value: model.overlayOn ? "On" : "Off", shortcut: model.overlayCombo.display) {
                model.toggleOverlay()
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Recent runs").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if model.recentRuns.isEmpty {
                    Text("No runs yet").foregroundStyle(.tertiary)
                } else {
                    ForEach(model.recentRuns.prefix(5), id: \.self) { name in
                        Text(name).lineLimit(1).truncationMode(.middle)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                MenuRow(title: "Open Metal-PT", shortcut: nil) {
                    openWindow(id: MetalPTApp.mainWindowID)
                    NSApp.activate()
                }
                MenuRow(title: "Quit Metal-PT", shortcut: "⌘Q") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: Self.width, alignment: .leading)
    }
}

/// The live numbers for the followed game (mockup: FPS, System W, GPU, CPU P, Die, Fans).
private struct StatsGrid: View {
    let snapshot: HubSnapshot

    var body: some View {
        let s = snapshot.sample
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            GridRow {
                Stat(name: "FPS", value: Fmt.int(snapshot.fps), unit: nil)
                Stat(name: "System", value: Fmt.int(Fmt.systemW(s)), unit: "W")
            }
            GridRow {
                Stat(name: "GPU", value: Fmt.int(s.gpuBusyPct), unit: "%")
                Stat(name: "CPU P", value: Fmt.int(s.cpuPUtilPct), unit: "%")
            }
            GridRow {
                Stat(name: "Die", value: Fmt.int(s.tempMaxC), unit: "°C")
                Stat(name: "Fans", value: Fmt.int(s.fanRPM.max()), unit: "rpm")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct Stat: View {
    let name: String
    let value: String
    let unit: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(name).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
            Text(value).font(.body.weight(.semibold)).monospacedDigit()
            if let unit, value != "–" { Text(unit).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A plain, menu-like row.
private struct MenuRow: View {
    let title: String
    var value: String? = nil
    let shortcut: String?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                if let value { Text(value).fontWeight(.semibold) }
                Spacer()
                if let shortcut { Text(shortcut).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 5).fill(hover ? Color.primary.opacity(0.1) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .padding(.horizontal, -6)
    }
}
