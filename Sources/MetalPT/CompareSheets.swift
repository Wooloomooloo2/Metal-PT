import MPTApp
import MPTCore
import SwiftUI

/// What Add Runs shows and adds (pure, so the rules are tested): the search narrows what is listed, never what is ticked.
enum AddRunsSelection {
    /// `scope` narrowed by the search (`RunEntry.matches`, as the Runs page); a blank search keeps everything.
    static func visible(_ scope: [RunEntry], filter: String) -> [RunEntry] { scope.filter { $0.matches(filter) } }

    /// The ticked runs that are still in `scope` (a search never unticks a run).
    static func keep(_ ticked: Set<String>, in scope: [RunEntry]) -> Set<String> {
        ticked.intersection(scope.map(\.id))
    }

    /// The runs to add: ticked ones (listed or hidden by the search) plus `extra`, oldest first.
    static func ids(_ scope: [RunEntry], ticked: Set<String>, extra: String?) -> [String] {
        scope.filter { ticked.contains($0.id) || $0.id == extra }
            .sorted { $0.start != $1.start ? $0.start < $1.start : $0.id < $1.id }
            .map(\.id)
    }

    /// "Make it the baseline" is offered when exactly one run is ticked.
    static func canChooseBaseline(ticked: Set<String>) -> Bool { ticked.count == 1 }
}

/// "Add Runs…": the finished runs not yet in the comparison (from the Runs index), ticked to add, oldest first.
/// Runs of the comparison's own game(s) only, unless "Show other games" is on.
struct AddRunsSheet: View {
    let detail: ProjectDetail
    @ObservedObject var store: ProjectsStore
    @ObservedObject var runs: RunsStore
    /// The folder names to add (oldest first), and the one among them to make the baseline (nil: unchanged).
    let onAdd: ([String], String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var ticked: Set<String>
    /// Worked out when the sheet opens and when the runs index or the project changes, not on every redraw.
    @State private var candidates: [RunEntry]
    /// The comparison's games (empty: unknown, everything is shown).
    @State private var games: Set<String> = []
    @State private var allGames = false
    @State private var filter: String
    @State private var makeBaseline: Bool

    /// `ticked`, `filter` and `makeBaseline` given: snapshots.
    init(detail: ProjectDetail, store: ProjectsStore, runs: RunsStore, ticked: Set<String> = [],
         candidates: [RunEntry] = [], filter: String = "", makeBaseline: Bool = false,
         onAdd: @escaping ([String], String?) -> Void) {
        self.detail = detail
        self.store = store
        self.runs = runs
        self.onAdd = onAdd
        _ticked = State(initialValue: ticked)
        _candidates = State(initialValue: candidates)
        _filter = State(initialValue: filter)
        _makeBaseline = State(initialValue: makeBaseline)
    }

    private func updateCandidates() {
        candidates = store.candidates(detail.id, from: runs.entries)
        games = store.games(detail.id, from: runs.entries)
        ticked = AddRunsSelection.keep(ticked, in: shown)
    }

    /// The runs in scope (same game unless "Show other games"); `visible` is what the search leaves of them.
    private var shown: [RunEntry] { allGames ? candidates : CompareLibrary.sameGame(candidates, games: games) }
    private var hiddenCount: Int { candidates.count - CompareLibrary.sameGame(candidates, games: games).count }
    private var visible: [RunEntry] { AddRunsSelection.visible(shown, filter: filter) }
    private var gameName: String { games.count == 1 ? games.first! : "these games" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Add runs").font(.title3.weight(.semibold))
                Text("To “\(detail.name)”. Finished runs not already in it. Right-click a run to add it as the baseline.")
                    .foregroundStyle(.secondary)
            }
            SnapshotSafeTextField("Search: game, app, stack, settings, label", text: $filter)
            Group {
                if visible.isEmpty && !shown.isEmpty {
                    Text("No runs match “\(filter.trimmingCharacters(in: .whitespaces))”.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                        .padding(.horizontal, 20)
                } else if shown.isEmpty {
                    Text(!runs.loaded ? "Loading runs…"
                         : candidates.isEmpty ? "Every finished run is already in this comparison."
                         : "No other runs of \(gameName). Turn on Show other games to add a run of another game.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                        .padding(.horizontal, 20)
                } else {
                    SnapshotSafeScroll {
                        LazyVStack(spacing: 0) {
                            ForEach(visible) { entry in
                                CandidateRow(entry: entry, ticked: ticked.contains(entry.id))
                                    .contentShape(Rectangle())
                                    .onTapGesture { toggle(entry.id) }
                                    .contextMenu {
                                        Button("Add as baseline") { add(extra: entry.id, baseline: entry.id) }
                                    }
                                Divider().padding(.leading, 34)
                            }
                        }
                    }
                    .frame(minHeight: 120, maxHeight: 320)
                }
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
            if AddRunsSelection.canChooseBaseline(ticked: ticked) {
                Toggle("Make it the baseline", isOn: $makeBaseline)
                    .help("Compare the other runs against this one instead of the oldest")
            }
            HStack {
                if hiddenCount > 0 || allGames {
                    Toggle("Show other games\(hiddenCount > 0 ? " (\(hiddenCount))" : "")", isOn: $allGames)
                        .onChange(of: allGames) { ticked = AddRunsSelection.keep(ticked, in: shown) }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(addTitle) {
                    add(extra: nil, baseline: makeBaseline && AddRunsSelection.canChooseBaseline(ticked: ticked)
                        ? ticked.first : nil)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(ticked.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear(perform: updateCandidates)
        .onChange(of: runs.entries) { updateCandidates() }
        .onChange(of: store.details[detail.id]) { updateCandidates() }
    }

    private var addTitle: String {
        switch ticked.count {
        case 0: "Add"
        case 1: "Add 1 Run"
        default: "Add \(ticked.count) Runs"
        }
    }

    /// Oldest first, as "Compare selected…" orders a new project. `extra`: a run added although not ticked (the row's
    /// "Add as baseline").
    private func add(extra: String?, baseline: String?) {
        onAdd(AddRunsSelection.ids(shown, ticked: ticked, extra: extra), baseline)
        dismiss()
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
                let sub = [entry.appUnderTitle ?? "", entry.stackLine, entry.settings, entry.label].filter { !$0.isEmpty }
                Text(sub.isEmpty ? "Stack unknown" : sub.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 0) {
                    Text("\(RunFormat.shortDate(entry.start)) · \(RunFormat.duration(entry.duration)) · ")
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
