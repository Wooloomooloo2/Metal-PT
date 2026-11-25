import CoreGraphics
import MPTApp
import MPTCore
import SwiftUI

/// "Edit Settings/Notes…": the game's name and the run's user fields. Saving rewrites run.json (privacy-scrubbed)
/// and its summary. The game field names the game behind an emulator or launcher; the recorded app (`game.exe`) is
/// shown, never edited.
struct EditNotesSheet: View {
    let entry: RunEntry
    @ObservedObject var store: RunsStore
    @Environment(\.dismiss) private var dismiss
    /// The title, else the recorded app's name; saved empty or as the app's name, it clears the title.
    @State private var game: String
    /// Titles of other runs of the same app (worked out when the sheet opens).
    private let suggestions: [String]
    @State private var settings: String
    @State private var label: String
    @State private var notes: String
    @State private var preset: RunInfo.Graphics.Preset?
    /// "WxH" of a listed resolution, `customTag`, or nil (not set).
    @State private var resolution: String?
    @State private var customWidth: String
    @State private var customHeight: String
    @State private var upscaler: RunInfo.Graphics.Upscaler?
    @State private var upscalerMode: RunInfo.Graphics.UpscalerMode?
    @State private var frameGeneration: Bool?
    @State private var video: String
    /// Notes are read from run.json when the sheet opens (the index does not hold them).
    @State private var loaded: Bool
    @State private var saving = false
    @State private var problem: String?

    /// `fields` given (snapshots): shown as is, nothing read.
    init(entry: RunEntry, store: RunsStore, fields: RunInfo.UserFields? = nil) {
        self.entry = entry
        self.store = store
        _game = State(initialValue: entry.title ?? entry.app)
        suggestions = store.titleSuggestions(forApp: entry.app).filter { $0 != entry.title }
        _settings = State(initialValue: fields?.gameSettings ?? entry.settings)
        _label = State(initialValue: fields?.label ?? entry.label)
        _notes = State(initialValue: fields?.notes ?? "")
        let g = entry.graphics
        _preset = State(initialValue: g?.preset)
        _upscaler = State(initialValue: g?.upscaler)
        _upscalerMode = State(initialValue: g?.upscalerMode)
        _frameGeneration = State(initialValue: g?.frameGeneration)
        let size = Self.resolutionChoices.first { $0.0 == g?.width && $0.1 == g?.height }
        if let w = g?.width, let h = g?.height {
            _resolution = State(initialValue: size != nil ? Self.tag(w, h) : Self.customTag)
            _customWidth = State(initialValue: size != nil ? "" : "\(w)")
            _customHeight = State(initialValue: size != nil ? "" : "\(h)")
        } else {
            _resolution = State(initialValue: nil)
            _customWidth = State(initialValue: "")
            _customHeight = State(initialValue: "")
        }
        _video = State(initialValue: fields?.videoURL ?? "")
        _loaded = State(initialValue: fields != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Edit game, settings and notes").font(.title3.weight(.semibold))
                Text("\(entry.game) · \(RunFormat.date(entry.start))")
                    .foregroundStyle(.secondary)
            }
            field("Game", hint: entry.app.isEmpty ? "No app was detected for this run"
                                                  : "Recorded app: \(entry.app) — kept for comparisons") {
                HStack(spacing: 8) {
                    SnapshotSafeTextField(entry.app.isEmpty ? "The game's name" : entry.app, text: $game)
                    if !suggestions.isEmpty {
                        SuggestionsMenu(suggestions: suggestions, app: entry.app) { game = $0 }
                    }
                }
            }
            field("Game settings", hint: "Quality preset, resolution, upscaler — what you set in the game") {
                SnapshotSafeTextField("High, 1440p, FSR off", text: $settings)
            }
            graphicsSection
            field("Label", hint: "A short name for this run in lists and comparisons") {
                SnapshotSafeTextField("After driver update", text: $label)
            }
            field("Notes", hint: nil) {
                notesEditor
                    .frame(minHeight: 90)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
            }
            field("YouTube video about this run", hint: videoProblem == nil ? "Optional. A video that shows this run"
                                                                        : nil) {
                SnapshotSafeTextField("https://www.youtube.com/watch?v=…", text: $video)
                if let videoProblem {
                    Label(videoProblem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Label {
                Text("Game, settings, graphics, label and video link are part of the run: they go with submissions and "
                     + "comparisons. "
                     + "Notes stay on this Mac unless you choose to include them when you submit.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "info.circle")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!loaded || saving || videoProblem != nil || customProblem)
            }
        }
        .padding(20)
        .frame(width: 480)
        .task {
            guard !loaded else { return }
            do {
                let f = try await store.userFields(entry.id)
                settings = f.gameSettings
                label = f.label
                notes = f.notes
                video = f.videoURL ?? ""
                loaded = true
            } catch {
                problem = "Could not read this run: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Graphics

    private static let customTag = "custom"
    private static func tag(_ w: Int, _ h: Int) -> String { "\(w)x\(h)" }

    /// The main display's size first (the usual native resolution), then the common ones, without repeats.
    private static let resolutionChoices: [(Int, Int)] = {
        var list: [(Int, Int)] = []
        let id = CGMainDisplayID()
        let w = CGDisplayPixelsWide(id), h = CGDisplayPixelsHigh(id)
        if w > 0, h > 0 { list.append((w, h)) }
        for r in RunInfo.Graphics.commonResolutions where !list.contains(where: { $0 == r }) { list.append(r) }
        return list
    }()

    private var videoProblem: String? {
        let t = video.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || YouTubeLink.videoID(from: t) != nil ? nil : "Only YouTube links (youtube.com, youtu.be)"
    }

    private var customProblem: Bool {
        resolution == Self.customTag && parsedCustom == nil
    }

    private var parsedCustom: (Int, Int)? {
        guard let w = Int(customWidth.trimmingCharacters(in: .whitespaces)),
              let h = Int(customHeight.trimmingCharacters(in: .whitespaces)),
              (1...16384).contains(w), (1...16384).contains(h) else { return nil }
        return (w, h)
    }

    /// The graphics to save: nil (clear) when nothing is set.
    private var graphicsToSave: RunInfo.Graphics? {
        var g = RunInfo.Graphics(preset: preset, upscaler: upscaler,
                                 upscalerMode: upscaler == .off ? nil : upscalerMode, frameGeneration: frameGeneration)
        if resolution == Self.customTag {
            if let c = parsedCustom { g.width = c.0; g.height = c.1 }
        } else if let r = Self.resolutionChoices.first(where: { Self.tag($0.0, $0.1) == resolution }) {
            g.width = r.0; g.height = r.1
        }
        return g == RunInfo.Graphics() ? nil : g
    }

    private var graphicsSection: some View {
        let sizes = Self.resolutionChoices.map { (Optional(Self.tag($0.0, $0.1)), "\($0.0)×\($0.1)") }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Graphics").font(.subheadline.weight(.semibold))
            HStack(alignment: .top, spacing: 12) {
                labelled("Preset") {
                    ChoiceMenu(selection: $preset,
                               options: RunInfo.Graphics.Preset.allCases.map { (Optional($0), $0.displayName) })
                }
                labelled("Resolution") {
                    ChoiceMenu(selection: $resolution, options: sizes + [(Self.customTag, "Custom…")])
                }
            }
            if resolution == Self.customTag {
                HStack(spacing: 6) {
                    SnapshotSafeTextField("Width", text: $customWidth).frame(width: 90)
                    Text("×")
                    SnapshotSafeTextField("Height", text: $customHeight).frame(width: 90)
                    if customProblem {
                        Text("Whole pixels, e.g. 2560 × 1440").font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            HStack(alignment: .top, spacing: 12) {
                labelled("Upscaler") {
                    ChoiceMenu(selection: $upscaler,
                               options: RunInfo.Graphics.Upscaler.allCases.map { (Optional($0), $0.displayName) })
                }
                if upscaler != .off {
                    labelled("Mode") {
                        ChoiceMenu(selection: $upscalerMode,
                                   options: RunInfo.Graphics.UpscalerMode.allCases.map { (Optional($0), $0.displayName) })
                    }
                }
                labelled("Frame generation") {
                    ChoiceMenu(selection: $frameGeneration, options: [(true, "On"), (false, "Off")])
                }
            }
            Text("What you set in the game. Resolution is the game's render size.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func labelled<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @Environment(\.rendersSnapshot) private var snapshot

    @ViewBuilder
    private var notesEditor: some View {
        if snapshot {
            Text(notes).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(4)
        } else {
            TextEditor(text: $notes).font(.body)
        }
    }

    private func field<C: View>(_ title: String, hint: String?, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            content()
            if let hint {
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func save() {
        saving = true
        problem = nil
        let s = settings.trimmingCharacters(in: .whitespacesAndNewlines)
        let l = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let gr = graphicsToSave
        let v = video.trimmingCharacters(in: .whitespacesAndNewlines)
        let g = game   // trimmed, capped and cleared (empty or the app's name) by the index
        Task {
            do {
                try await store.update(entry.id, settings: s, notes: n, label: l, title: g,
                                       graphics: .some(gr), videoURL: .some(v.isEmpty ? nil : v))
                dismiss()
            } catch {
                problem = "Could not save: \(error.localizedDescription)"
                saving = false
            }
        }
    }
}

/// "Earlier titles": the titles given to other runs of the same app. Picking one fills the field; nothing is applied
/// by itself.
private struct SuggestionsMenu: View {
    let suggestions: [String]
    let app: String
    let pick: (String) -> Void
    @Environment(\.rendersSnapshot) private var snapshot

    var body: some View {
        if snapshot {
            label   // `Menu` does not render in `ImageRenderer`
        } else {
            Menu {
                ForEach(suggestions, id: \.self) { t in Button(t) { pick(t) } }
            } label: {
                label
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Titles used on other \(app) runs")
        }
    }

    private var label: some View {
        HStack(spacing: 3) {
            Text("Earlier titles")
            Image(systemName: "chevron.down").font(.caption.weight(.semibold))
        }
        .foregroundStyle(Color.accentColor)
        .fixedSize()
    }
}

/// A pick-one menu with a "Not set" entry; in snapshots (a `Menu` does not render in `ImageRenderer`) the choice
/// drawn in a field-like box.
private struct ChoiceMenu<T: Hashable>: View {
    @Binding var selection: T?
    let options: [(T?, String)]
    @Environment(\.rendersSnapshot) private var snapshot

    private var current: String { options.first { $0.0 == selection }?.1 ?? "Not set" }

    var body: some View {
        if snapshot {
            HStack {
                Text(current).foregroundStyle(selection == nil ? .tertiary : .primary).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor))
                RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.2))
            }
        } else {
            Picker("", selection: $selection) {
                Text("Not set").tag(T?.none)
                ForEach(options.indices, id: \.self) { i in
                    if let v = options[i].0 { Text(options[i].1).tag(Optional(v)) }
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }
}
