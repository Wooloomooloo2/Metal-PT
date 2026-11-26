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
    @State private var graphics: GraphicsDraft
    @State private var video: String
    /// The video link metal-pt.com has (the stored one when the sheet opened): a published run's link goes to the
    /// site only when it differs. A refused change leaves it as it was, so saving again retries.
    @State private var syncedVideo: String
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
        _graphics = State(initialValue: GraphicsDraft(entry.graphics))
        _video = State(initialValue: fields?.videoURL ?? "")
        _syncedVideo = State(initialValue: fields?.videoURL ?? "")
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
            GraphicsFields(draft: $graphics)
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
                Text(footnote)
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
                    .disabled(!loaded || saving || videoProblem != nil || graphics.customProblem)
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
                syncedVideo = video
                loaded = true
            } catch {
                problem = "Could not read this run: \(error.localizedDescription)"
            }
        }
    }

    private var footnote: String {
        let base = "Game, settings, graphics, label and video link are part of the run: they go with submissions and "
            + "comparisons. Notes stay on this Mac unless you choose to include them when you submit."
        guard entry.isPublished else { return base }
        return base + " This run is on metal-pt.com: a changed video link is sent there too; the other fields stay "
            + "as published."
    }

    private var videoProblem: String? {
        let t = video.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || YouTubeLink.videoID(from: t) != nil ? nil : "Only YouTube links (youtube.com, youtu.be)"
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
        let gr = graphics.graphics
        let v = video.trimmingCharacters(in: .whitespacesAndNewlines)
        let g = game   // trimmed, capped and cleared (empty or the app's name) by the index
        Task {
            do {
                try await store.update(entry.id, settings: s, notes: n, label: l, title: g,
                                       graphics: .some(gr), videoURL: .some(v.isEmpty ? nil : v))
            } catch {
                problem = "Could not save: \(error.localizedDescription)"
                saving = false
                return
            }
            // Saved here; a published run's changed link also goes to the site (the site checks it again).
            if VideoLinkSync.needsSend(published: entry.isPublished, link: v, synced: syncedVideo) {
                do {
                    try await store.setSiteVideo(entry.id, url: v.isEmpty ? nil : v)
                    syncedVideo = v
                } catch {
                    problem = VideoLinkSync.refusedMessage(error)
                    saving = false
                    return
                }
            }
            dismiss()
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

/// A published run's video link edits: when to send one to metal-pt.com, and what to say when it is refused.
enum VideoLinkSync {
    /// The run is published and the link differs from the one the site has (links compared by video, so another
    /// spelling of the same video is not sent again).
    static func needsSend(published: Bool, link: String, synced: String) -> Bool {
        guard published else { return false }
        return normalized(link) != normalized(synced)
    }

    static func refusedMessage(_ error: Error) -> String {
        var message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        while message.hasSuffix(".") { message.removeLast() }
        return "The link was saved on this Mac but not on metal-pt.com: \(message). Save again to retry."
    }

    private static func normalized(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return YouTubeLink.videoID(from: t).map { YouTubeLink.canonicalURL(id: $0) } ?? t
    }
}
