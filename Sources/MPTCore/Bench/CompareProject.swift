import Foundation

/// A named group of runs compared against one of them (the baseline). Stored as
/// `~/Documents/Metal-PT/projects/<slug>.json`; the display name lives inside the file.
public struct CompareProject: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        /// The bundle's directory name when it sits in the runs folder, else its absolute path.
        public var bundle: String
        /// The name shown in the report (`--as`); empty means "derive one from the run".
        public var name: String
        public init(bundle: String, name: String = "") { self.bundle = bundle; self.name = name }
    }

    public var name: String
    /// Index into `runs` of the baseline.
    public var baseline: Int
    public var runs: [Entry]

    public init(name: String, baseline: Int = 0, runs: [Entry] = []) {
        self.name = name; self.baseline = baseline; self.runs = runs
    }

    /// `<slug>.json`, with the same slug rule as run bundles.
    public static func fileName(for name: String) -> String { RunBundle.slug(name) + ".json" }

    public static func load(_ url: URL) throws -> CompareProject {
        try JSONDecoder().decode(CompareProject.self, from: Data(contentsOf: url))
    }

    public func save(to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try enc.encode(self).write(to: url, options: .atomic)
    }

    // MARK: - Edits (shared by `mpt compare` and the app's Compare page)

    /// Appends a run; refuses a bundle already in the project.
    public mutating func add(bundle: String, name: String = "") throws {
        guard !runs.contains(where: { $0.bundle == bundle }) else {
            throw CompareProjectError.alreadyAdded(bundle: bundle, project: self.name)
        }
        runs.append(.init(bundle: bundle, name: name))
    }

    /// Takes entry `index` out (the run itself is kept). The baseline stays on the same run; when the baseline itself
    /// goes, run 1 takes over and this returns true.
    @discardableResult
    public mutating func remove(at index: Int) throws -> Bool {
        guard runs.indices.contains(index) else { throw CompareProjectError.runNumber(index + 1, count: runs.count) }
        runs.remove(at: index)
        if baseline == index {
            baseline = 0
            return !runs.isEmpty
        }
        if baseline > index { baseline -= 1 }
        return false
    }

    /// Compares against entry `index`.
    public mutating func setBaseline(_ index: Int) throws {
        guard runs.indices.contains(index) else { throw CompareProjectError.runNumber(index + 1, count: runs.count) }
        baseline = index
    }

    /// Refuses `url` (a project file) when it holds a project other than `name` (two names can share a slug), or
    /// cannot be read. A missing file is free.
    public static func checkFile(_ url: URL, isFreeFor name: String) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let existing = try load(url)
        guard existing.name == name else {
            throw CompareProjectError.fileHoldsOther(file: url.lastPathComponent, project: existing.name)
        }
    }

    /// The entry's bundle folder: an absolute path as stored, a bare name under `runsRoot`.
    public static func bundleURL(_ entry: Entry, runsRoot: URL) -> URL {
        entry.bundle.hasPrefix("/") ? URL(fileURLWithPath: entry.bundle, isDirectory: true)
                                    : runsRoot.appendingPathComponent(entry.bundle, isDirectory: true)
    }

    /// What to store for a bundle: its folder name when it sits directly in `runsRoot`, else its absolute path.
    public static func entryBundle(for directory: URL, runsRoot: URL) -> String {
        let dir = directory.standardizedFileURL.resolvingSymlinksInPath()
        let root = runsRoot.standardizedFileURL.resolvingSymlinksInPath()
        return dir.deletingLastPathComponent().path == root.path ? dir.lastPathComponent : dir.path
    }

    /// Loads every run it can; the others come back in `missing` with why ("the run folder is gone", or
    /// "run.json unreadable or incompatible: <reason>").
    public func loadRuns(runsRoot: URL) -> (runs: [(RunBundle, RunSummary)], missing: [(index: Int, reason: String)]) {
        var runs: [(RunBundle, RunSummary)] = []
        var missing: [(index: Int, reason: String)] = []
        for (i, entry) in self.runs.enumerated() {
            let url = Self.bundleURL(entry, runsRoot: runsRoot)
            do {
                let b = try RunBundle.load(url)
                runs.append((b, RunSummary(b)))
            } catch {
                missing.append((i, Self.loadProblem(url, error)))
            }
        }
        return (runs, missing)
    }

    /// Why the bundle at `url` did not load.
    public static func loadProblem(_ url: URL, _ error: Error) -> String {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return "the run folder is gone"
        }
        return "run.json unreadable or incompatible: " + reason(error)
    }

    private static func reason(_ error: Error) -> String {
        func path(_ keys: [CodingKey]) -> String {
            keys.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
        }
        switch error {
        case DecodingError.keyNotFound(let key, let ctx):
            return "missing \"\(path(ctx.codingPath + [key]))\""
        case DecodingError.valueNotFound(_, let ctx), DecodingError.typeMismatch(_, let ctx):
            return "wrong value for \"\(path(ctx.codingPath))\""
        case DecodingError.dataCorrupted(let ctx):
            return ctx.codingPath.isEmpty ? "not valid JSON" : "bad value for \"\(path(ctx.codingPath))\""
        case let e as CocoaError where e.code == .fileReadNoSuchFile:
            return "no run.json"
        default:
            return error.localizedDescription
        }
    }
}

public enum CompareProjectError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case alreadyAdded(bundle: String, project: String)
    case fileHoldsOther(file: String, project: String)
    /// A 1-based run number outside 1…count.
    case runNumber(Int, count: Int)

    public var description: String {
        switch self {
        case .alreadyAdded(let bundle, let project): "'\(bundle)' is already in '\(project)'"
        case .fileHoldsOther(let file, let project): "project file \(file) already holds project '\(project)'"
        case .runNumber(let n, let count):
            count == 0 ? "no run \(n) (the project has no runs)" : "no run \(n) (the project has runs 1 to \(count))"
        }
    }

    public var errorDescription: String? { description.prefix(1).uppercased() + description.dropFirst() + "." }
}
