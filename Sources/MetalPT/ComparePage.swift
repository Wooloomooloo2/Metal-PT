import AppKit
import MPTApp
import MPTCore
import SwiftUI

/// Compare (spec §5): saved compare projects on the left, the selected one's report on the right with its baseline,
/// add / remove runs, rename and delete. Every edit saves the project, rewrites its report and reloads it; the report
/// is also rewritten each time a project is opened (runs trashed since show as missing). Same files and numbering as
/// `mpt compare`.
struct ComparePage: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var store: ProjectsStore
    /// The project shown on the right (nil: the first in the list).
    @State private var selection: String?
    @State private var adding: ProjectDetail?
    @State private var renaming: ProjectSummary?
    @State private var deleting: ProjectSummary?
    @State private var problem: String?

    init(model: AppModel, selection: String? = nil) {
        self.model = model
        self.store = model.projects
        _selection = State(initialValue: selection)
    }

    private var shown: ProjectSummary? {
        if let selection, let p = store.project(selection) { return p }   // follows a rename
        return store.projects.first
    }

    var body: some View {
        Group {
            if store.loaded && store.projects.isEmpty {
                CompareEmptyState(folder: store.projectsRoot ?? model.folder("projects"))
            } else {
                HStack(spacing: 0) {
                    listColumn.frame(width: 300)
                    Divider()
                    detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            refresh()
            selectRequestedProject()
        }
        .onChange(of: store.projects) { selectRequestedProject() }
        .onChange(of: model.selectedProject) {
            refresh()
            selectRequestedProject()
        }
        .sheet(item: $adding) { detail in
            AddRunsSheet(detail: detail, store: store, runs: model.runs) { ids, baseline in
                edit("Could not add the runs") { try await store.add(detail.id, bundles: ids, baseline: baseline) }
            }
            .onAppear {
                if model.live { model.runs.refresh(root: model.folder("runs")) }
            }
        }
        .sheet(item: $renaming) { project in
            RenameProjectSheet(name: project.name) { name in
                let newID = try await store.rename(project.id, to: name)
                selection = newID
            }
        }
        .confirmationDialog("Move this comparison to the Trash?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { project in
            Button("Move to Trash", role: .destructive) { delete(project) }
            Button("Cancel", role: .cancel) {}
        } message: { project in
            Text("“\(project.name)” and its report go to the Trash; the runs in it are kept.")
        }
        .alert("Compare", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK") {}
        } message: {
            Text(problem ?? "")
        }
    }

    // MARK: - List

    private var listColumn: some View {
        VStack(spacing: 0) {
            HStack {
                Text(store.projects.count == 1 ? "1 comparison" : "\(store.projects.count) comparisons")
                    .foregroundStyle(.secondary)
                Spacer()
                Button { refresh() } label: {
                    Image(systemName: "arrow.clockwise").foregroundStyle(.secondary).padding(4)
                }
                    .buttonStyle(.plain)
                    .help("Rescan the projects folder")
            }
            .padding(10)
            Divider()
            SnapshotSafeScroll {
                LazyVStack(spacing: 0) {
                    ForEach(store.projects) { project in
                        ProjectRow(project: project, selected: shown?.id == project.id)
                            .contentShape(Rectangle())
                            .onTapGesture { selection = project.id }
                            .contextMenu { contextMenu(project) }
                        Divider().padding(.leading, 10)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func contextMenu(_ project: ProjectSummary) -> some View {
        Button("Rename…") { renaming = project }
            .disabled(project.problem != nil)
        Button("Show in Finder") {
            if let url = store.url(of: project.id) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        Divider()
        Button("Move to Trash…", role: .destructive) { deleting = project }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let project = shown {
            CompareDetailView(project: project, store: store, debug: model.debugLogging,
                              onBaseline: { index in
                                  edit("Could not change the baseline") {
                                      try await store.setBaseline(project.id, index: index)
                                  }
                              },
                              onAdd: { adding = store.details[project.id] },
                              onRemove: { index in
                                  edit("Could not remove the run") { try await store.remove(project.id, index: index) }
                              },
                              onRename: { renaming = project },
                              onDelete: { deleting = project })
            // Per-project state (load error, report) starts fresh when another project is shown.
            .id(project.id)
        } else if !store.loaded {
            ProgressView().controlSize(.small)
        } else {
            Text("Select a comparison to see its report.").foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func refresh() {
        guard model.live else { return }   // snapshots show a fixed folder
        store.refresh(projectsRoot: model.folder("projects"), runsRoot: model.folder("runs"))
    }

    /// Runs → "Compare selected…" made this project: select it once the list has it.
    private func selectRequestedProject() {
        guard let url = model.selectedProject else { return }
        let id = url.lastPathComponent
        guard store.project(id) != nil else { return }
        selection = id
        model.selectedProject = nil
    }

    private func edit(_ what: String, _ change: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await change() } catch { problem = "\(what): \(error.localizedDescription)" }
        }
    }

    private func delete(_ project: ProjectSummary) {
        edit("Could not move the comparison to the Trash") {
            try await store.delete(project.id)
            if selection == project.id { selection = nil }
        }
    }
}

// MARK: - Row

private struct ProjectRow: View {
    let project: ProjectSummary
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(project.name)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            if let problem = project.problem {
                Label(problem.prefix(1).uppercased() + problem.dropFirst(), systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            } else {
                let runs = project.runCount == 1 ? "1 run" : "\(project.runCount) runs"
                Text([runs, project.game].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text("Modified \(RunFormat.date(project.modified))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(selected ? Color.accentColor.opacity(0.15) : .clear)
    }
}

// MARK: - Detail view

/// The selected project: its name and runs, the edit controls, and its report.
private struct CompareDetailView: View {
    let project: ProjectSummary
    @ObservedObject var store: ProjectsStore
    let debug: Bool
    let onBaseline: (Int) -> Void
    let onAdd: () -> Void
    let onRemove: (Int) -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    @Environment(\.rendersSnapshot) private var snapshot
    /// Why the project's runs could not be loaded (then its edit controls are off).
    @State private var detailError: String?

    private var detail: ProjectDetail? { store.details[project.id] }
    private var version: Int { store.reportVersions[project.id] ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .layoutPriority(1)
                Spacer(minLength: 8)
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .help("Move this comparison to the Trash (the runs are kept)")
            }
            if project.problem == nil {
                controls
                if let detailError {
                    Label("Could not read this comparison's runs: \(detailError)",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(3)
                }
                if let missing = missingText {
                    Label(missing, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
                ReportArea(id: project.id, store: store, debug: debug)
                    // A fresh area per project: never the previous project's report while the new one loads.
                    .id(project.id)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
            } else {
                Text("This project file cannot be read. Fix it by hand (it is JSON) or move it to the Trash.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(16)
        .task(id: "\(project.id)#\(version)") {
            guard !snapshot, project.problem == nil else { return }
            do {
                try await store.loadDetail(project.id)
                detailError = nil
            } catch is CancellationError {
            } catch {
                detailError = error.localizedDescription
            }
        }
    }

    private var subtitle: String {
        guard let detail else { return project.game }
        let missing = detail.runs.filter { $0.missing != nil }.count
        var parts = [detail.runs.count == 1 ? "1 run" : "\(detail.runs.count) runs"]
        if missing > 0 { parts.append("\(missing) missing") }
        if !project.game.isEmpty { parts.append(project.game) }
        return parts.joined(separator: " · ")
    }

    /// "Run 2 (Whisky 2.3) is missing: the run folder is gone. …"
    private var missingText: String? {
        let missing = (detail?.runs ?? []).filter { $0.missing != nil }
        guard !missing.isEmpty else { return nil }
        let parts = missing.map { "run \($0.number) (\($0.label)): \($0.missing ?? "")" }
        let head = missing.count == 1 ? "Missing " : "Missing runs — "
        let tail = missing.count == 1 ? "Remove it, or put the run back from the Trash."
                                      : "Remove them, or put the runs back from the Trash."
        return head + parts.joined(separator: "; ") + ". " + tail
    }

    private var controls: some View {
        HStack(spacing: 8) {
            let runs = detail?.runs ?? []
            let base = runs.first { $0.isBaseline }
            SnapshotSafeMenu(title: base.map { "Baseline: \(Self.title($0))" } ?? "Baseline",
                             help: "The run the others are compared against") {
                ForEach(runs) { run in
                    Button { onBaseline(run.index) } label: {
                        if run.isBaseline { Label(Self.dated(run), systemImage: "checkmark") } else { Text(Self.dated(run)) }
                    }
                    .disabled(run.isBaseline)
                }
            }
            .disabled(runs.isEmpty)
            Button("Add Runs…", action: onAdd)
                .disabled(detail == nil)
                .help(detail == nil ? (detailError == nil ? "Loading the comparison's runs…"
                                                          : "The comparison's runs could not be read (see below)")
                                    : "Add finished runs to this comparison")
            SnapshotSafeMenu(title: "Remove", help: "Take a run out of this comparison (the run itself is kept)") {
                ForEach(runs) { run in
                    Button(Self.title(run)) { onRemove(run.index) }
                }
            }
            .disabled(runs.isEmpty)
            Button("Rename…", action: onRename)
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// `title` and the run's date: "2 · CrossOver D3DMetal · 12 Aug 2025".
    static func dated(_ run: ProjectDetail.Run, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let start = run.start else { return title(run) }
        return title(run) + " · " + RunFormat.shortDate(start, now: now, calendar: calendar)
    }

    /// "2 · CrossOver D3DMetal", "3 · old (missing)": the CLI's numbering.
    static func title(_ run: ProjectDetail.Run) -> String {
        "\(run.number) · \(run.label)" + (run.missing == nil ? "" : " (missing)")
    }
}

/// Rewrites (on open and after each edit) and shows the project's report.
private struct ReportArea: View {
    let id: String
    @ObservedObject var store: ProjectsStore
    let debug: Bool
    @Environment(\.rendersSnapshot) private var snapshot
    @State private var result: Result<URL, Error>?

    private var version: Int { store.reportVersions[id] ?? 0 }

    var body: some View {
        Group {
            if snapshot {
                // Ruling R2: the report itself is reviewed via its own renders.
                ZStack {
                    Color.primary.opacity(0.04)
                    VStack(spacing: 6) {
                        Image(systemName: "chart.bar.doc.horizontal").font(.system(size: 30, weight: .light))
                        Text("The comparison report (tiles, bar charts, differences), shown in a web view")
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.secondary)
                    .padding()
                }
            } else {
                switch result {
                case .success(let url):
                    // The report is self-contained (inline SVG, no links to run folders): read access is the
                    // projects folder only.
                    SummaryWebView(file: url, folder: url.deletingLastPathComponent(), version: version, debug: debug,
                                   kind: "report")
                case .failure(let error):
                    Text("Could not show this comparison's report: \(error.localizedDescription)")
                        .foregroundStyle(.secondary)
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case nil:
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task(id: "\(id)#\(version)") {
            guard !snapshot else { return }
            result = await store.report(id)
        }
    }
}

/// A pull-down `Menu`; in snapshots, a button-like stand-in with its title (`ImageRenderer` does not draw menus).
private struct SnapshotSafeMenu<Content: View>: View {
    let title: String
    let help: String
    @ViewBuilder let content: Content
    @Environment(\.rendersSnapshot) private var snapshot

    var body: some View {
        if snapshot {
            HStack(spacing: 4) {
                Text(title).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .font(.callout)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
        } else {
            Menu(title) { content }
                .menuStyle(.button)
                .fixedSize()
                .help(help)
        }
    }
}

// MARK: - Empty state

private struct CompareEmptyState: View {
    let folder: URL

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No comparisons yet — tick runs in Runs and choose Compare")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("A comparison puts runs side by side against a baseline: FPS, 1 % lows, power, and what differed "
                 + "between them. It is saved here, with its report, and can be changed later.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Text(Privacy.scrubPaths(folder.path))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
