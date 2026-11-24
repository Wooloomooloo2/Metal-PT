import Foundation
import MPTApp
import MPTCore

/// The Compare page's data: the projects folder through `CompareLibrary`, worked off the main actor (opening or
/// editing a project loads its run bundles and rewrites its report), with results published here. Refreshed when
/// the Compare page appears and after every edit.
@MainActor
final class ProjectsStore: ObservableObject {
    @Published private(set) var projects: [ProjectSummary] = []
    /// The first refresh has completed (before that, the page shows nothing rather than "No comparisons yet").
    @Published private(set) var loaded = false
    /// The last loaded detail of each project (its numbered runs), for the toolbar menus.
    @Published private(set) var details: [String: ProjectDetail] = [:]
    /// Bumped per project each time its report is rewritten by an edit, so the web view reloads.
    @Published private(set) var reportVersions: [String: Int] = [:]

    private(set) var library: CompareLibrary?
    /// Old id → new id after a rename, so a selection made before the rename keeps pointing at the project while
    /// the page catches up (no flash of another project).
    private var renamed: [String: String] = [:]
    private var refreshing = false
    private var refreshAgain = false

    var projectsRoot: URL? { library?.projectsRoot }

    /// Rescans the projects folder (a new library when the data folders changed). Coalesces like `RunsStore`.
    func refresh(projectsRoot: URL, runsRoot: URL) {
        let library = library(projectsRoot: projectsRoot, runsRoot: runsRoot)
        guard !refreshing else { refreshAgain = true; return }
        refreshing = true
        Task {
            let list = await Task.detached { library.projects() }.value
            self.refreshing = false
            if library === self.library {
                self.setProjects(list)
                self.loaded = true
            }
            if self.refreshAgain, let current = self.library {
                self.refreshAgain = false
                self.refresh(projectsRoot: current.projectsRoot, runsRoot: current.runsRoot)
            }
        }
    }

    func project(_ id: String) -> ProjectSummary? {
        let id = currentID(id)
        return projects.first { $0.id == id }
    }

    /// `id` when a listed project has it (an exact match always wins), else what it was renamed to.
    func currentID(_ id: String) -> String {
        if projects.contains(where: { $0.id == id }) { return id }
        var id = id
        var seen: Set<String> = []
        while let next = renamed[id], seen.insert(id).inserted { id = next }
        return id
    }

    func url(of id: String) -> URL? { library?.url(of: id) }

    /// Reloads the project's numbered runs (missing ones included).
    func loadDetail(_ id: String) async throws {
        let library = try current()
        let d = try await Task.detached { try library.detail(id) }.value
        details[id] = d
    }

    /// Rewrites the project's report (runs may have gone since) and returns it.
    func report(_ id: String) async -> Result<URL, Error> {
        guard let library else { return .failure(CocoaError(.fileNoSuchFile)) }
        return await Task.detached { Result { try library.report(id) } }.value
    }

    /// The runs that can be added to the project, from the Runs index.
    func candidates(_ id: String, from entries: [RunEntry]) -> [RunEntry] {
        guard let library, let detail = details[id] else { return [] }
        return library.candidates(detail, from: entries)
    }

    func add(_ id: String, bundles: [String]) async throws {
        try await edit(id) { try $0.add(id, bundles: bundles) }
    }

    /// True when the removed run was the baseline (run 1 is now).
    @discardableResult
    func remove(_ id: String, index: Int) async throws -> Bool {
        let library = try current()
        let was = try await Task.detached { try library.remove(id, index: index) }.value
        await finishEdit(id)
        return was
    }

    func setBaseline(_ id: String, index: Int) async throws {
        try await edit(id) { try $0.setBaseline(id, index: index) }
    }

    /// Returns the project's new id (its file name follows the name).
    func rename(_ id: String, to name: String) async throws -> String {
        let library = try current()
        let newID = try await Task.detached { try library.rename(id, to: name) }.value
        if newID != id {
            renamed[id] = newID
            renamed[newID] = nil
            details[id] = nil
            reportVersions[newID] = (reportVersions[id] ?? 0) + 1
            reportVersions[id] = nil
        }
        await finishEdit(newID)
        return newID
    }

    /// Moves the project and its report to the Trash.
    func delete(_ id: String) async throws {
        let library = try current()
        let list = try await Task.detached {
            try library.delete(id)
            return library.projects()
        }.value
        renamed = renamed.filter { $0.key != id && $0.value != id }
        setProjects(list)
        details[id] = nil
        reportVersions[id] = nil
    }

    /// Snapshots: list and open every project synchronously.
    func showFixture(projectsRoot: URL, runsRoot: URL) {
        let library = library(projectsRoot: projectsRoot, runsRoot: runsRoot)
        setProjects(library.projects())
        for p in projects where p.problem == nil {
            details[p.id] = try? library.detail(p.id)
        }
        loaded = true
    }

    // MARK: - Private

    private func current() throws -> CompareLibrary {
        guard let library else { throw CocoaError(.fileNoSuchFile) }
        return library
    }

    private func edit(_ id: String, _ change: @escaping @Sendable (CompareLibrary) throws -> Void) async throws {
        let library = try current()
        try await Task.detached { try change(library) }.value
        await finishEdit(id)
    }

    /// After an edit (saved, report rewritten): reload the list and the project's runs, and the web view.
    private func finishEdit(_ id: String) async {
        guard let library else { return }
        let (list, detail) = await Task.detached { (library.projects(), try? library.detail(id)) }.value
        setProjects(list)
        details[id] = detail
        reportVersions[id, default: 0] += 1
    }

    /// A new list; aliases are dropped once their old id is a real project again (a new project took the name) or
    /// their target is gone.
    private func setProjects(_ list: [ProjectSummary]) {
        projects = list
        let ids = Set(list.map(\.id))
        renamed = renamed.filter { !ids.contains($0.key) && ids.contains($0.value) }
    }

    private func library(projectsRoot: URL, runsRoot: URL) -> CompareLibrary {
        if let library, library.projectsRoot == projectsRoot, library.runsRoot == runsRoot { return library }
        let library = CompareLibrary(projectsRoot: projectsRoot, runsRoot: runsRoot)
        self.library = library
        renamed = [:]
        projects = []
        details = [:]
        loaded = false
        return library
    }
}
