import Foundation
import MPTApp
import MPTCore

/// The Runs page's data: the cached `RunIndex` of the runs folder, worked off the main actor (it may touch hundreds of
/// bundles), with results published here. Refreshed when the Runs page appears, when a recording is saved, and from
/// the page's refresh button. (No file-system watching: those triggers cover every way a run appears or changes from
/// inside Metal-PT; runs copied in by hand show up on the next appear/refresh.)
@MainActor
final class RunsStore: ObservableObject {
    @Published private(set) var entries: [RunEntry] = []
    /// The first refresh has completed (before that, the page shows nothing rather than "No runs yet").
    @Published private(set) var loaded = false
    /// Bumped per run each time its summary.html is rewritten, so the detail view reloads.
    @Published private(set) var summaryVersions: [String: Int] = [:]

    private(set) var root: URL?
    private var index: RunIndex?
    private var refreshing = false
    private var refreshAgain = false

    /// Rescans `root` (a new index when the data folder changed). Coalesces: a refresh asked for while one runs
    /// starts once more after it.
    func refresh(root: URL) {
        let index = index(for: root)
        guard !refreshing else { refreshAgain = true; return }
        refreshing = true
        Task {
            let list = await Task.detached { index.entries() }.value
            self.refreshing = false
            if index === self.index {   // not a folder that was switched away from meanwhile
                self.entries = list
                self.loaded = true
            }
            if self.refreshAgain, let current = self.root {
                self.refreshAgain = false
                self.refresh(root: current)
            }
        }
    }

    func entry(_ id: String) -> RunEntry? { entries.first { $0.id == id } }

    func url(of id: String) -> URL? { root?.appendingPathComponent(id, isDirectory: true) }

    /// The run's stored user fields (notes are not in the index).
    func userFields(_ id: String) async throws -> RunInfo.UserFields {
        guard let index else { throw CocoaError(.fileNoSuchFile) }
        return try await Task.detached { try index.userFields(dir: id) }.value
    }

    /// Saves the user fields, regenerates the summary and refreshes the list.
    func update(_ id: String, settings: String, notes: String, label: String) async throws {
        guard let index else { return }
        let list = try await Task.detached {
            try index.update(dir: id, settings: settings, notes: notes, label: label)
            return index.entries()
        }.value
        entries = list
        summaryVersions[id, default: 0] += 1
    }

    /// Moves the run to the Trash.
    func delete(_ id: String) async throws {
        guard let index else { return }
        let list = try await Task.detached {
            try index.delete(dir: id)
            return index.entries()
        }.value
        entries = list
    }

    /// The run's summary.html, written first if it is missing (e.g. a run copied from the CLI without one).
    func summaryURL(_ id: String) async -> Result<URL, Error> {
        guard let dir = url(of: id) else { return .failure(CocoaError(.fileNoSuchFile)) }
        return await Task.detached {
            let file = dir.appendingPathComponent(SummaryReport.fileName)
            if FileManager.default.fileExists(atPath: file.path) { return .success(file) }
            return Result { try SummaryReport.write(bundleAt: dir) }
        }.value
    }

    /// Snapshots: index `root` synchronously.
    func showFixture(root: URL) {
        let index = index(for: root)
        entries = index.entries()
        loaded = true
    }

    private func index(for root: URL) -> RunIndex {
        if let index, self.root == root { return index }
        let index = RunIndex(root: root)
        self.index = index
        self.root = root
        entries = []
        loaded = false
        return index
    }
}
