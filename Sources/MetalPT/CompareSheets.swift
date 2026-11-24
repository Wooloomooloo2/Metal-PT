import MPTApp
import MPTCore
import SwiftUI

/// "Add Runs…": the finished runs not yet in the comparison (from the Runs index), ticked to add, oldest first.
struct AddRunsSheet: View {
    let detail: ProjectDetail
    @ObservedObject var store: ProjectsStore
    @ObservedObject var runs: RunsStore
    let onAdd: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var ticked: Set<String>

    /// `ticked` given: snapshots.
    init(detail: ProjectDetail, store: ProjectsStore, runs: RunsStore, ticked: Set<String> = [],
         onAdd: @escaping ([String]) -> Void) {
        self.detail = detail
        self.store = store
        self.runs = runs
        self.onAdd = onAdd
        _ticked = State(initialValue: ticked)
    }

    private var candidates: [RunEntry] { store.candidates(detail.id, from: runs.entries) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Add runs").font(.title3.weight(.semibold))
                Text("To “\(detail.name)”. Finished runs not already in it, newest first.")
                    .foregroundStyle(.secondary)
            }
            Group {
                if candidates.isEmpty {
                    Text(runs.loaded ? "Every finished run is already in this comparison." : "Loading runs…")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    SnapshotSafeScroll {
                        LazyVStack(spacing: 0) {
                            ForEach(candidates) { entry in
                                CandidateRow(entry: entry, ticked: ticked.contains(entry.id))
                                    .contentShape(Rectangle())
                                    .onTapGesture { toggle(entry.id) }
                                Divider().padding(.leading, 34)
                            }
                        }
                    }
                    .frame(minHeight: 120, maxHeight: 320)
                }
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(addTitle) {
                    // Oldest first, as "Compare selected…" orders a new project.
                    let ids = candidates.filter { ticked.contains($0.id) }
                        .sorted { $0.start != $1.start ? $0.start < $1.start : $0.id < $1.id }
                        .map(\.id)
                    onAdd(ids)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(ticked.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onChange(of: runs.entries) {
            ticked.formIntersection(candidates.map(\.id))
        }
    }

    private var addTitle: String {
        switch ticked.count {
        case 0: "Add"
        case 1: "Add 1 Run"
        default: "Add \(ticked.count) Runs"
        }
    }

    private func toggle(_ id: String) {
        if ticked.contains(id) { ticked.remove(id) } else { ticked.insert(id) }
    }
}

private struct CandidateRow: View {
    let entry: RunEntry
    let ticked: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: ticked ? "checkmark.square.fill" : "square")
                .font(.system(size: 15))
                .foregroundStyle(ticked ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.game).font(.headline).lineLimit(1).truncationMode(.middle)
                let sub = [entry.stackLine, entry.settings, entry.label].filter { !$0.isEmpty }
                Text(sub.isEmpty ? "Stack unknown" : sub.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 0) {
                    Text("\(RunFormat.date(entry.start)) · \(RunFormat.duration(entry.duration)) · ")
                    Text(RunFormat.fps(entry.medianFPS)).fontWeight(.semibold)
                    Text(" fps · 1% \(RunFormat.low(entry.low1))")
                }
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(ticked ? Color.accentColor.opacity(0.1) : .clear)
    }
}

/// "Rename…": the comparison's name (its file follows: `<slug>.json`). A name whose file holds another comparison is
/// refused, as `mpt compare` refuses it.
struct RenameProjectSheet: View {
    let original: String
    let onSave: @MainActor (String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var saving = false
    @State private var problem: String?

    /// `problem` given: snapshots.
    init(name: String, edited: String? = nil, problem: String? = nil,
         onSave: @escaping @MainActor (String) async throws -> Void) {
        original = name
        self.onSave = onSave
        _name = State(initialValue: edited ?? name)
        _problem = State(initialValue: problem)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename comparison").font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 4) {
                SnapshotSafeTextField("Name", text: $name)
                    .onSubmit(save)
                Text("The project file and its report are renamed with it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty || trimmed == original || saving)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onChange(of: name) { problem = nil }
    }

    private func save() {
        guard !trimmed.isEmpty, trimmed != original, !saving else { return }
        saving = true
        Task {
            do {
                try await onSave(trimmed)
                dismiss()
            } catch {
                problem = error.localizedDescription
                saving = false
            }
        }
    }
}
