import AppKit
import MPTApp
import MPTCore
import ServiceManagement
import SwiftUI

/// Settings (spec §5): FPS logging, hotkeys, overlay, data folder, launch at login, about. A grouped `Form` in the
/// app; in snapshots the same rows in a drawn grouped layout (`ImageRenderer` does not draw AppKit-backed forms,
/// switches, pop-ups or sliders).
struct SettingsPage: View {
    @ObservedObject var model: AppModel
    /// Snapshots: a hotkey field shown recording, and inline hotkey messages.
    var recordingField: GlobalHotkeys.Action?
    var hotkeyMessages: [GlobalHotkeys.Action: String] = [:]

    var body: some View {
        SettingsContent(model: model, recordingField: recordingField, hotkeyMessages: hotkeyMessages)
            .defaultAppStorage(model.defaults)
    }
}

private struct SettingsContent: View {
    @ObservedObject var model: AppModel
    @StateObject private var recorder: HotkeyRecorder
    @StateObject private var loginItem = LoginItem()
    @State private var hotkeyMessages: [GlobalHotkeys.Action: String]
    @State private var dataFolderProblem: String?
    @AppStorage(SettingsKey.overlayStyle) private var styleSetting = OverlayStyle.defaultValue.rawValue
    @AppStorage(SettingsKey.overlayCorner) private var cornerSetting = OverlayCorner.defaultValue.rawValue
    @AppStorage(SettingsKey.overlayOpacity) private var opacity = OverlayDefaults.opacity
    @Environment(\.rendersSnapshot) private var snapshot

    init(model: AppModel, recordingField: GlobalHotkeys.Action?, hotkeyMessages: [GlobalHotkeys.Action: String]) {
        self.model = model
        _recorder = StateObject(wrappedValue: HotkeyRecorder(recording: recordingField))
        _hotkeyMessages = State(initialValue: hotkeyMessages)
    }

    var body: some View {
        SettingsForm {
            fpsSection
            hotkeySection
            overlaySection
            dataSection
            loginSection
            aboutSection
        }
        .onAppear { loginItem.refresh() }
        .onDisappear { stopRecording() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Approval in System Settings → Login Items happens outside the app.
            loginItem.refresh()
        }
    }

    // MARK: - FPS logging

    private var fpsSection: some View {
        SettingsSection("FPS logging") {
            SettingsToggle("FPS logging", isOn: Binding(get: { model.fpsLoggingOn },
                                                        set: { model.setFPSLogging($0) }))
            SettingsNote("Sets MTL_HUD_ENABLED and MTL_HUD_LOG_ENABLED for apps started from now on, so Metal-PT can "
                         + "read their frame times. Apple's Metal HUD then shows on screen in those games. Start the "
                         + "game — or quit and restart it and its launcher — after turning this on. Turned off again "
                         + "when Metal-PT quits.")
            if let error = model.fpsLoggingError {
                HStack(alignment: .firstTextBaseline) {
                    Warning(text: error)
                    Spacer(minLength: 8)
                    Button("Try Again") { model.retryFPSLogging() }
                }
            }
        }
    }

    // MARK: - Hotkeys

    private var hotkeySection: some View {
        SettingsSection("Hotkeys") {
            ForEach(GlobalHotkeys.Action.allCases, id: \.self) { action in
                hotkeyRow(action)
            }
            SettingsNote("Click a shortcut, then press the new keys. Esc cancels; Delete restores the default. "
                         + "F1–F20 work alone; other keys need ⌃, ⌥, ⇧ or ⌘. They work over full-screen games.")
        }
    }

    private func hotkeyRow(_ action: GlobalHotkeys.Action) -> some View {
        let message = hotkeyMessages[action] ?? model.hotkeyRegistration[action]
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(action == .record ? "Start / stop recording" : "Show / hide overlay")
                Spacer(minLength: 8)
                HotkeyField(display: model.combo(for: action).display, recording: recorder.recording == action) {
                    // A click on a recording field has already stopped it (the recorder's mouse-down monitor).
                    if recorder.recording == action || recorder.consumeClickStop(action) {
                        recorder.stop()
                    } else {
                        startRecording(action)
                    }
                }
            }
            if let message { Warning(text: message) }
        }
    }

    private func startRecording(_ action: GlobalHotkeys.Action) {
        hotkeyMessages[action] = nil
        // The recorder hands the hotkeys back before the outcome is applied; `setHotkey` then re-registers.
        recorder.start(action, hotkeys: model) { outcome in
            switch outcome {
            case .cancel: break
            case .reset: hotkeyMessages[action] = model.setHotkey(nil, for: action)
            case .combo(let combo): hotkeyMessages[action] = model.setHotkey(combo, for: action)
            }
        }
    }

    private func stopRecording() {
        guard !snapshot else { return }
        recorder.stop()
    }

    // MARK: - Overlay

    private var overlaySection: some View {
        SettingsSection("Overlay") {
            SettingsPicker("Style", selection: $styleSetting, options: [
                (OverlayStyle.auto.rawValue, "Automatic — compact, detailed while recording"),
                (OverlayStyle.compact.rawValue, "Always compact"),
                (OverlayStyle.detailed.rawValue, "Always detailed"),
            ])
            SettingsPicker("Corner", selection: $cornerSetting, options: [
                (OverlayCorner.topLeft.rawValue, "Top left"),
                (OverlayCorner.topRight.rawValue, "Top right"),
                (OverlayCorner.bottomLeft.rawValue, "Bottom left"),
                (OverlayCorner.bottomRight.rawValue, "Bottom right"),
            ])
            SettingsSlider("Background opacity", value: $opacity, text: OverlayView.opacityPercent(opacity))
            SettingsNote("The overlay sits above full-screen games and ignores the mouse. Top left keeps it clear "
                         + "of Apple's Metal HUD (top right). Text stays fully opaque.")
        }
    }

    // MARK: - Data folder

    private var dataSection: some View {
        let envRoot = model.dataFolderEnvRoot
        let busy = model.recordState != .idle
        return SettingsSection("Data folder") {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Location")
                    Spacer(minLength: 8)
                    Text((model.dataRoot.path as NSString).abbreviatingWithTildeInPath)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                if envRoot != nil {
                    Label("Set by MPT_DATA_ROOT (a development setting); unset it to choose a folder here.",
                          systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Change…") { chooseFolder() }
                    .disabled(envRoot != nil || busy)
                Button("Reveal in Finder") { reveal() }
                Spacer(minLength: 8)
                Button("Reset to Default") { dataFolderProblem = model.setDataFolder(nil) }
                    .disabled(envRoot != nil || busy || model.dataFolderIsDefault)
            }
            if let dataFolderProblem { Warning(text: dataFolderProblem) }
            SettingsNote(busy && envRoot == nil
                         ? "The folder can be changed once the recording has been saved."
                         : "Runs, comparisons and exports are kept in runs, projects and exports inside it. Changing "
                           + "it does not move what is already there.")
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder for runs, comparisons and exports."
        panel.directoryURL = model.dataRoot.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        dataFolderProblem = model.setDataFolder(url)
    }

    private func reveal() {
        let root = model.dataRoot
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }

    // MARK: - Launch at login

    private var loginSection: some View {
        SettingsSection("Launch at login") {
            SettingsToggle("Open Metal-PT at login", isOn: Binding(get: { loginItem.isOn },
                                                                   set: { loginItem.set($0) }))
                .disabled(!loginItem.available)
            if let note = loginItem.note {
                HStack(alignment: .firstTextBaseline) {
                    SettingsNote(note)
                    if loginItem.needsApproval {
                        Spacer(minLength: 8)
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
            }
            if let error = loginItem.error { Warning(text: error) }
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        SettingsSection("About") {
            SettingsValue("Version", MetalPTVersion.current)
            SettingsValue("License", "GPL-3.0")
            HStack {
                Text("Source")
                Spacer(minLength: 8)
                if snapshot {
                    Text("github.com/Wooloomooloo2/Metal-PT").foregroundStyle(Color.accentColor)
                } else {
                    Link("github.com/Wooloomooloo2/Metal-PT",
                         destination: URL(string: "https://github.com/Wooloomooloo2/Metal-PT")!)
                }
            }
        }
    }
}

// MARK: - Hotkey recording

/// A shortcut "key cap": the combo, or "Type shortcut…" with an accent ring while recording.
private struct HotkeyField: View {
    let display: String
    let recording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(recording ? "Type shortcut…" : display)
                .font(.system(.body, design: .rounded).weight(.medium))
                .monospacedDigit()
                .foregroundStyle(recording ? Color.secondary : Color.primary)
                .frame(minWidth: 110)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(recording ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(recording ? Color.accentColor : Color.primary.opacity(0.15),
                                  lineWidth: recording ? 2 : 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(recording ? "Press the new shortcut (Esc cancels, Delete restores the default)"
                        : "Click to record a new shortcut")
    }
}

// MARK: - Launch at login

/// `SMAppService.mainApp`: registered or not, and whether it waits for approval. Unavailable when Metal-PT runs
/// unbundled (`swift run`): there is no app for launchd to open.
@MainActor
final class LoginItem: ObservableObject {
    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var error: String?
    let available = Bundle.main.bundleIdentifier != nil

    var isOn: Bool { status == .enabled || status == .requiresApproval }
    var needsApproval: Bool { status == .requiresApproval }

    var note: String? {
        guard available else { return "Available in the installed app (Metal-PT.app)." }
        switch status {
        case .requiresApproval: return "Waiting for approval in System Settings → General → Login Items."
        case .notFound: return "macOS cannot find this copy of Metal-PT; move it to Applications and try again."
        default: return nil
        }
    }

    func refresh() {
        guard available else { return }
        status = SMAppService.mainApp.status
    }

    func set(_ on: Bool) {
        guard available else { return }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            self.error = "Could not \(on ? "add" : "remove") the login item: \(error.localizedDescription)"
        }
        refresh()
    }
}

// MARK: - Form pieces (snapshot-safe)

/// `Form` with `.formStyle(.grouped)`; in snapshots a padded stack of drawn groups.
private struct SettingsForm<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.rendersSnapshot) private var snapshot

    var body: some View {
        if snapshot {
            VStack(alignment: .leading, spacing: 16) { content }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            Form { content }.formStyle(.grouped)
        }
    }
}

/// A `Section` with a header; in snapshots, the header over a rounded group with dividers between rows.
private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @Environment(\.rendersSnapshot) private var snapshot

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        if snapshot {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline).padding(.leading, 4)
                VStack(alignment: .leading, spacing: 0) {
                    Group(subviews: content) { rows in
                        ForEach(rows) { row in
                            if row.id != rows.first?.id { Divider().padding(.horizontal, 10) }
                            row.padding(.horizontal, 10).padding(.vertical, 7)
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.035)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
            }
        } else {
            Section(title) { content }
        }
    }
}

/// A switch row; in snapshots a drawn switch.
private struct SettingsToggle: View {
    let title: String
    @Binding var isOn: Bool
    @Environment(\.rendersSnapshot) private var snapshot
    @Environment(\.isEnabled) private var enabled

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        _isOn = isOn
    }

    var body: some View {
        if snapshot {
            HStack {
                Text(title)
                Spacer(minLength: 8)
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule().fill(isOn ? Color.accentColor : Color.primary.opacity(0.15))
                    Circle().fill(.white).shadow(color: .black.opacity(0.2), radius: 1, y: 0.5).padding(2)
                }
                .frame(width: 32, height: 18)
            }
            .opacity(enabled ? 1 : 0.45)
        } else {
            Toggle(title, isOn: $isOn).toggleStyle(.switch)
        }
    }
}

/// A pop-up picker row; in snapshots the selected title with the pop-up chevrons.
private struct SettingsPicker: View {
    let title: String
    @Binding var selection: String
    let options: [(String, String)]
    @Environment(\.rendersSnapshot) private var snapshot

    init(_ title: String, selection: Binding<String>, options: [(String, String)]) {
        self.title = title
        _selection = selection
        self.options = options
    }

    var body: some View {
        if snapshot {
            HStack {
                Text(title)
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    Text(options.first { $0.0 == selection }?.1 ?? options.first?.1 ?? "")
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
            }
        } else {
            Picker(title, selection: $selection) {
                ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
            }
            .pickerStyle(.menu)
        }
    }
}

/// A 0…1 slider row with its value as text; in snapshots a drawn track.
private struct SettingsSlider: View {
    let title: String
    @Binding var value: Double
    let text: String
    @Environment(\.rendersSnapshot) private var snapshot

    init(_ title: String, value: Binding<Double>, text: String) {
        self.title = title
        _value = value
        self.text = text
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer(minLength: 8)
            if snapshot {
                GeometryReader { geo in
                    let x = geo.size.width * min(1, max(0, value))
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.15)).frame(height: 4)
                        Capsule().fill(Color.accentColor).frame(width: x, height: 4)
                        Circle().fill(.white)
                            .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                            .frame(width: 16, height: 16)
                            .offset(x: x - 8)
                    }
                    .frame(maxHeight: .infinity)
                }
                .frame(width: 200, height: 18)
            } else {
                Slider(value: $value, in: 0...1).frame(width: 200)
            }
            Text(text).monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
        }
    }
}

/// A label and a value.
private struct SettingsValue: View {
    let title: String
    let value: String

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer(minLength: 8)
            Text(value).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}

/// Secondary explanatory text.
private struct SettingsNote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct Warning: View {
    let text: String

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
        .font(.callout)
    }
}
