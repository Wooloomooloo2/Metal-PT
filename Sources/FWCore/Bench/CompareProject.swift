import Foundation

/// A named group of runs compared against one of them (the baseline). Stored as
/// `~/Documents/FW Benchmark/projects/<slug>.json`; the display name lives inside the file.
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

    /// Loads every run that still exists; the others come back in `missing` (entry indices).
    public func loadRuns(runsRoot: URL) -> (runs: [(RunBundle, RunSummary)], missing: [Int]) {
        var runs: [(RunBundle, RunSummary)] = []
        var missing: [Int] = []
        for (i, entry) in self.runs.enumerated() {
            if let b = try? RunBundle.load(Self.bundleURL(entry, runsRoot: runsRoot)) {
                runs.append((b, RunSummary(b)))
            } else {
                missing.append(i)
            }
        }
        return (runs, missing)
    }
}
