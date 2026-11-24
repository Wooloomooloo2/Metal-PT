import MPTApp
import MPTCore
import SwiftUI

/// "Edit Settings/Notes…": the run's user fields. Saving rewrites run.json (privacy-scrubbed) and its summary.
struct EditNotesSheet: View {
    let entry: RunEntry
    @ObservedObject var store: RunsStore
    @Environment(\.dismiss) private var dismiss
    @State private var settings: String
    @State private var label: String
    @State private var notes: String
    /// Notes are read from run.json when the sheet opens (the index does not hold them).
    @State private var loaded: Bool
    @State private var saving = false
    @State private var problem: String?

    /// `fields` given (snapshots): shown as is, nothing read.
    init(entry: RunEntry, store: RunsStore, fields: RunInfo.UserFields? = nil) {
        self.entry = entry
        self.store = store
        _settings = State(initialValue: fields?.gameSettings ?? entry.settings)
        _label = State(initialValue: fields?.label ?? entry.label)
        _notes = State(initialValue: fields?.notes ?? "")
        _loaded = State(initialValue: fields != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Edit settings and notes").font(.title3.weight(.semibold))
                Text("\(entry.game) · \(RunFormat.date(entry.start))")
                    .foregroundStyle(.secondary)
            }
            field("Game settings", hint: "Quality preset, resolution, upscaler — what you set in the game") {
                SnapshotSafeTextField("High, 1440p, FSR off", text: $settings)
            }
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
            Label {
                Text("Settings and label are part of the run: they go with submissions and comparisons. "
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
                    .disabled(!loaded || saving)
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
                loaded = true
            } catch {
                problem = "Could not read this run: \(error.localizedDescription)"
            }
        }
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
        Task {
            do {
                try await store.update(entry.id, settings: s, notes: n, label: l)
                dismiss()
            } catch {
                problem = "Could not save: \(error)"
                saving = false
            }
        }
    }
}
