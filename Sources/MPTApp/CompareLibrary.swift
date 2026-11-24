import Foundation
import MPTCore

/// One compare project as the Compare list shows it. `id` is the project's file name (`<slug>.json`).
public struct ProjectSummary: Identifiable, Sendable, Equatable, Hashable {
    public var id: String
    public var name: String
    public var runCount: Int
    /// The game of the runs that load ("hzd"), "2 games", or empty when none load.
    public var game: String
    /// The project file's modification time.
    public var modified: Date
    /// Why the file could not be read (then `name` is the file name without `.json`).
    public var problem: String?

    public init(id: String, name: String, runCount: Int, game: String, modified: Date, problem: String? = nil) {
        self.id = id; self.name = name; self.runCount = runCount; self.game = game; self.modified = modified
        self.problem = problem
    }
}

/// A project's runs, numbered as `mpt compare NAME` numbers them (1-based, missing runs included).
public struct ProjectDetail: Identifiable, Sendable, Equatable {
    public struct Run: Identifiable, Sendable, Equatable, Hashable {
        /// 0-based entry index (what `remove` / `setBaseline` take).
        public var index: Int
        public var number: Int { index + 1 }
        public var id: Int { index }
        /// The report's label for the run (`CompareReport.label`), else the entry's name or folder name.
        public var label: String
        /// The entry's stored bundle (folder name, or absolute path).
        public var bundle: String
        /// Why the run did not load (trashed, unreadable); nil when it loaded.
        public var missing: String?
        public var isBaseline: Bool

        public init(index: Int, label: String, bundle: String, missing: String?, isBaseline: Bool) {
            self.index = index; self.label = label; self.bundle = bundle; self.missing = missing
            self.isBaseline = isBaseline
        }
    }

    public var id: String
    public var name: String
    public var baseline: Int
    public var runs: [Run]

    public init(id: String, name: String, baseline: Int, runs: [Run]) {
        self.id = id; self.name = name; self.baseline = baseline; self.runs = runs
    }
}

public enum CompareLibraryError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case emptyName

    public var description: String {
        switch self {
        case .emptyName: "a comparison needs a name"
        }
    }

    public var errorDescription: String? { description.prefix(1).uppercased() + description.dropFirst() + "." }
}

/// The compare projects folder, for the Compare page: list, open (the report is rewritten each time, so runs trashed
/// since show as missing), and edit. Every edit saves the project JSON and rewrites its report, with the same
/// semantics as `mpt compare` (the edits themselves live on `CompareProject`).
///
/// Thread-safe (one lock; calls are synchronous and load run bundles): call off the main actor.
public final class CompareLibrary: @unchecked Sendable {
    public typealias Trash = @Sendable (URL) throws -> Void

    public let projectsRoot: URL
    public let runsRoot: URL
    private let trash: Trash
    private let lock = NSLock()

    public init(projectsRoot: URL, runsRoot: URL,
                trash: @escaping Trash = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        self.projectsRoot = projectsRoot
        self.runsRoot = runsRoot
        self.trash = trash
    }

    public func url(of id: String) -> URL { projectsRoot.appendingPathComponent(id) }

    /// The report next to the project file (`<slug>.html`).
    public func reportURL(of id: String) -> URL { url(of: id).deletingPathExtension().appendingPathExtension("html") }

    /// Every `*.json` in the projects folder, most recently modified first.
    public func projects() -> [ProjectSummary] {
        lock.withLock {
            let fm = FileManager.default
            let files = ((try? fm.contentsOfDirectory(atPath: projectsRoot.path)) ?? []).filter { $0.hasSuffix(".json") }
            return files.map(summary).sorted {
                $0.modified != $1.modified ? $0.modified > $1.modified : $0.id < $1.id
            }
        }
    }

    public func detail(_ id: String) throws -> ProjectDetail {
        try lock.withLock { detail(id, try CompareProject.load(url(of: id))) }
    }

    /// Rewrites the report (the runs may have changed or gone since) and returns it.
    public func report(_ id: String) throws -> URL {
        try lock.withLock {
            try CompareReport.write(project: try CompareProject.load(url(of: id)), projectURL: url(of: id),
                                    runsRoot: runsRoot)
        }
    }

    /// Adds runs by folder name in the runs folder; refuses (adding none) if any is already in the project.
    public func add(_ id: String, bundles: [String]) throws {
        try edit(id) { p in
            for b in bundles {
                try p.add(bundle: CompareProject.entryBundle(for: runsRoot.appendingPathComponent(b, isDirectory: true),
                                                             runsRoot: runsRoot))
            }
        }
    }

    /// Takes entry `index` out; true when it was the baseline (run 1 is now).
    @discardableResult
    public func remove(_ id: String, index: Int) throws -> Bool {
        var wasBaseline = false
        try edit(id) { wasBaseline = try $0.remove(at: index) }
        return wasBaseline
    }

    public func setBaseline(_ id: String, index: Int) throws {
        try edit(id) { try $0.setBaseline(index) }
    }

    /// Renames the project and moves its files to the new name's slug; returns the new id. Refuses an empty name and
    /// a slug whose file already exists (another project, or one that cannot be read).
    public func rename(_ id: String, to newName: String) throws -> String {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw CompareLibraryError.emptyName }
        return try lock.withLock {
            let oldURL = url(of: id)
            var project = try CompareProject.load(oldURL)
            let newID = CompareProject.fileName(for: name)
            let newURL = url(of: newID)
            if newID != id, FileManager.default.fileExists(atPath: newURL.path) {
                let other = try CompareProject.load(newURL)
                throw CompareProjectError.fileHoldsOther(file: newID, project: other.name)
            }
            project.name = name
            try save(project, to: newURL)
            if newID != id {
                let fm = FileManager.default
                try fm.removeItem(at: oldURL)
                let oldReport = reportURL(of: id)
                if fm.fileExists(atPath: oldReport.path) { try fm.removeItem(at: oldReport) }
            }
            return newID
        }
    }

    /// Moves the project file and its report to the Trash (the runs are kept).
    public func delete(_ id: String) throws {
        try lock.withLock {
            try trash(url(of: id))
            let report = reportURL(of: id)
            if FileManager.default.fileExists(atPath: report.path) { try trash(report) }
        }
    }

    /// The runs that can be added: finished, not being recorded, not already in the project (by folder name or by
    /// absolute path to the same folder).
    public func candidates(_ detail: ProjectDetail, from entries: [RunEntry]) -> [RunEntry] {
        func key(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
        let inProject = Set(detail.runs.map { key(CompareProject.bundleURL(.init(bundle: $0.bundle), runsRoot: runsRoot)) })
        return entries.filter { e in
            e.finished && !e.inProgress && !inProject.contains(key(runsRoot.appendingPathComponent(e.id, isDirectory: true)))
        }
    }

    // MARK: - Private

    private func edit(_ id: String, _ change: (inout CompareProject) throws -> Void) throws {
        try lock.withLock {
            let url = url(of: id)
            var project = try CompareProject.load(url)
            try change(&project)
            try save(project, to: url)
        }
    }

    /// Saves the JSON, then rewrites the report.
    private func save(_ project: CompareProject, to url: URL) throws {
        try project.save(to: url)
        try CompareReport.write(project: project, projectURL: url, runsRoot: runsRoot)
    }

    private func summary(_ file: String) -> ProjectSummary {
        let url = url(of: file)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = attrs?[.modificationDate] as? Date ?? .distantPast
        let project: CompareProject
        do {
            project = try CompareProject.load(url)
        } catch {
            return ProjectSummary(id: file, name: (file as NSString).deletingPathExtension, runCount: 0, game: "",
                                  modified: modified, problem: "unreadable project file")
        }
        var games: [String] = []
        for entry in project.runs {
            guard let b = try? RunBundle.load(CompareProject.bundleURL(entry, runsRoot: runsRoot), frames: false) else {
                continue
            }
            let g = RunEntry.displayGame(b.info)
            if !games.contains(g) { games.append(g) }
        }
        let game = games.count > 1 ? "\(games.count) games" : games.first ?? ""
        return ProjectSummary(id: file, name: project.name, runCount: project.runs.count, game: game, modified: modified)
    }

    private func detail(_ id: String, _ project: CompareProject) -> ProjectDetail {
        let runs = project.runs.enumerated().map { i, entry -> ProjectDetail.Run in
            let url = CompareProject.bundleURL(entry, runsRoot: runsRoot)
            do {
                let b = try RunBundle.load(url, frames: false)
                return .init(index: i, label: CompareReport.label(entry, b.info), bundle: entry.bundle, missing: nil,
                             isBaseline: i == project.baseline)
            } catch {
                return .init(index: i, label: entry.name.isEmpty ? (entry.bundle as NSString).lastPathComponent : entry.name,
                             bundle: entry.bundle, missing: CompareProject.loadProblem(url, error),
                             isBaseline: i == project.baseline)
            }
        }
        return ProjectDetail(id: id, name: project.name, baseline: project.baseline, runs: runs)
    }
}
