import Foundation
import MPTCore

/// One run as the Runs list shows it. `id` is the bundle's folder name (`…​.mptrun`), stable across edits.
public struct RunEntry: Codable, Identifiable, Sendable, Equatable, Hashable {
    public var id: String
    /// The game title, else the recorded app (`app`), else "Unknown game".
    public var game: String
    /// The recorded app: the executable without ".exe" ("ARMSX2"), empty when none was detected. Never edited; it
    /// stays the run's ID for comparisons when the user names the game behind an emulator or launcher.
    public var app: String
    /// "Protium 0.3 · FEX · DXMT"; empty when the stack is unknown.
    public var stackLine: String
    /// The user's game settings ("High, 1440p").
    public var settings: String
    public var label: String
    public var start: Date
    /// Seconds: end − start, else the last sample's elapsed time.
    public var duration: Double
    public var medianFPS: Double?
    public var low1: Double?
    /// run.json has an end time.
    public var finished: Bool
    /// Being recorded right now (unfinished and still being written, or the app's current recording): listed as
    /// "Recording…", not editable, deletable or summarised. Worked out at each scan, never cached.
    public var inProgress: Bool

    public init(id: String, game: String, app: String? = nil, stackLine: String, settings: String, label: String,
                start: Date, duration: Double, medianFPS: Double?, low1: Double?, finished: Bool = true,
                inProgress: Bool = false) {
        self.id = id; self.game = game; self.app = app ?? game
        self.stackLine = stackLine; self.settings = settings; self.label = label
        self.start = start; self.duration = duration; self.medianFPS = medianFPS; self.low1 = low1
        self.finished = finished; self.inProgress = inProgress
    }

    public static let unknownGame = "Unknown game"
    /// Longest title kept (longer ones are cut).
    public static let maxTitleLength = 120

    /// The user's name for the game, when it is not just the recorded app's.
    public var title: String? {
        if app.isEmpty { return game == Self.unknownGame ? nil : game }
        return game == app ? nil : game
    }

    /// Case-insensitive match on game, recorded app, stack, settings and label; an empty filter matches everything.
    public func matches(_ filter: String) -> Bool {
        let f = filter.trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty else { return true }
        return [game, app, stackLine, settings, label].contains { $0.localizedCaseInsensitiveContains(f) }
    }

    static func displayGame(_ info: RunInfo) -> String {
        if let t = info.game.titleText { return t }
        let app = displayApp(info.game.exe)
        return app.isEmpty ? unknownGame : app
    }

    /// The executable without ".exe".
    static func displayApp(_ exe: String) -> String {
        var exe = exe
        if exe.lowercased().hasSuffix(".exe") { exe.removeLast(4) }
        return exe
    }

    /// The title to store for what the user typed: trimmed and cut to `maxTitleLength`; nil (no title) when empty
    /// or the recorded app's own name (with or without ".exe", any case).
    public static func normalizedTitle(_ text: String, exe: String) -> String? {
        let t = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxTitleLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let same = [exe, displayApp(exe)].contains { !$0.isEmpty && $0.caseInsensitiveCompare(t) == .orderedSame }
        return same ? nil : t
    }

    /// Titles given to other runs of the recorded app `app`, newest first, each once (ignoring case); none for an
    /// unknown app. Offered in the edit sheet, never applied by themselves. `entries`: newest first.
    public static func titleSuggestions(_ entries: [RunEntry], forApp app: String) -> [String] {
        guard !app.isEmpty else { return [] }
        var seen = Set<String>()
        return entries.compactMap { e -> String? in
            guard e.app == app, let t = e.title, seen.insert(t.lowercased()).inserted else { return nil }
            return t
        }
    }
}

public enum RunIndexError: LocalizedError, CustomStringConvertible {
    case newerFormat(Int)
    case inProgress

    public var description: String {
        switch self {
        case .newerFormat(let s): "this run was saved by a newer Metal-PT (format \(s)); edit it there"
        case .inProgress: "this run is still being recorded; try again once it has stopped"
        }
    }

    public var errorDescription: String? { description.prefix(1).uppercased() + description.dropFirst() + "." }
}

/// A cached index of the runs folder, so the Runs list opens without parsing every bundle (and never frames.csv
/// after a run's first indexing). The cache is `<root>/.index.json` (a dot-file: `mpt ls` lists only `*.mptrun`),
/// keyed by folder name + run.json's modification time and size; a corrupt cache or another cache version is
/// rebuilt silently. `low1` needs frames.csv: it is computed once, when a finished run is first indexed, and carried
/// over when only run.json changes (an edit).
///
/// A run without an end time whose samples.csv was written in the last `activeWindow` seconds (or whose folder is
/// `activeDirectory`, the app's own recording) is in progress: `update` and `delete` refuse it (the recorder still
/// owns the folder and rewrites run.json when it finishes). An unfinished run that has gone quiet (a crash) is
/// treated as an ordinary run.
///
/// Thread-safe (one lock; all calls are synchronous and may touch hundreds of bundles): call off the main actor.
public final class RunIndex: @unchecked Sendable {
    public typealias Loader = @Sendable (URL, Bool) throws -> RunBundle
    /// run.json only (`RunBundle.loadInfo`): for user fields, edits and the in-progress check.
    public typealias InfoLoader = @Sendable (URL) throws -> RunInfo
    public typealias Trash = @Sendable (URL) throws -> Void

    public static let cacheFileName = ".index.json"
    static let cacheVersion = 3
    /// Seconds since samples.csv was last written for an unfinished run to still count as being recorded (the
    /// recorder appends once a second).
    public static let activeWindow: TimeInterval = 10

    struct Record: Codable, Equatable {
        /// run.json's modification time (seconds since 1970) and size: the record is current while both match.
        var mtime: Double
        var size: Int
        /// nil: run.json could not be read (kept so a broken bundle is not re-parsed on every refresh).
        var entry: RunEntry?
        /// The run had ended when indexed, so `low1` is final.
        var finished: Bool
    }

    struct Cache: Codable {
        var version: Int
        var runs: [String: Record]
    }

    public let root: URL
    private let loader: Loader
    private let infoLoader: InfoLoader
    private let trash: Trash
    private let lock = NSLock()
    private var records: [String: Record]?
    private var active: String?

    /// The folder name of the run the app is recording now, if any (in progress whatever its file times).
    public var activeDirectory: String? {
        get { lock.withLock { active } }
        set { lock.withLock { active = newValue } }
    }

    public init(root: URL,
                loader: @escaping Loader = { try RunBundle.load($0, frames: $1) },
                infoLoader: @escaping InfoLoader = { try RunBundle.loadInfo($0) },
                trash: @escaping Trash = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        self.root = root
        self.loader = loader
        self.infoLoader = infoLoader
        self.trash = trash
    }

    public var cacheURL: URL { root.appendingPathComponent(Self.cacheFileName) }

    /// Rescans the folder (a listing plus one stat per run; bundles are parsed only when new or changed) and
    /// returns the runs, newest first.
    public func entries() -> [RunEntry] {
        lock.withLock {
            refreshLocked()
            return sortedLocked()
        }
    }

    /// Rescans the folder and saves the cache if anything changed.
    public func refresh() {
        lock.withLock { refreshLocked() }
    }

    /// The run's user fields as stored (for the edit sheet; notes are not in `RunEntry`).
    public func userFields(dir: String) throws -> RunInfo.UserFields {
        try infoLoader(root.appendingPathComponent(dir)).user
    }

    /// Whether the run is being recorded now (see the type's notes).
    public func isInProgress(dir: String) -> Bool {
        lock.withLock { inProgressLocked(dir, finished: nil) }
    }

    /// Returns `<dir>/summary.html`, writing it first if missing or older than `SummaryReport.version` (so a run
    /// recorded before a report change shows the new report; an older one that cannot be rewritten is returned as it
    /// is), under the index lock (so it never races an edit).
    /// Refuses a run in progress (a summary of half a run would stay behind).
    public func summary(dir: String) throws -> URL {
        try lock.withLock {
            guard !inProgressLocked(dir, finished: nil) else { throw RunIndexError.inProgress }
            let url = root.appendingPathComponent(dir)
            let file = url.appendingPathComponent(SummaryReport.fileName)
            let existing = SummaryReport.fileVersion(at: file)
            if let v = existing, v >= SummaryReport.version { return file }
            do {
                return try SummaryReport.write(bundleAt: url)
            } catch where existing != nil {
                // An older report beats none: the bundle may be unreadable now (newer schema, read-only or synced
                // folder, damaged samples), and the run opened before this version.
                try? FileHandle.standardError.write(contentsOf: Data(
                    "Metal-PT: kept the older summary of \(dir): \(error)\n".utf8))
                return file
            }
        }
    }

    /// Rewrites the run's user fields (privacy-scrubbed, by the bundle writer), regenerates summary.html and
    /// refreshes the run's entry. The folder name does not change. Refuses a run in progress.
    /// `title`: the game's name (`normalizedTitle`: empty or the recorded app's name clears it); nil leaves it.
    /// `game.exe` is never changed.
    public func update(dir: String, settings: String, notes: String, label: String, title: String? = nil) throws {
        try lock.withLock {
            let url = root.appendingPathComponent(dir)
            var info = try infoLoader(url)
            guard !inProgressLocked(dir, finished: info.end != nil) else { throw RunIndexError.inProgress }
            guard info.schema <= RunInfo.currentSchema else { throw RunIndexError.newerFormat(info.schema) }
            info.user.gameSettings = settings
            info.user.notes = notes
            info.user.label = label
            if let title { info.game.title = RunEntry.normalizedTitle(title, exe: info.game.exe) }
            try RunBundleWriter.writeInfo(info, to: url)
            try SummaryReport.write(bundleAt: url)
            refreshLocked()
        }
    }

    /// Moves the run folder to the Trash and drops it from the index. Refuses a run in progress.
    public func delete(dir: String) throws {
        try lock.withLock {
            guard !inProgressLocked(dir, finished: nil) else { throw RunIndexError.inProgress }
            try trash(root.appendingPathComponent(dir))
            refreshLocked()
        }
    }

    // MARK: - Private (lock held)

    private func sortedLocked() -> [RunEntry] {
        (records ?? [:]).values.compactMap { r -> RunEntry? in
            guard var e = r.entry else { return nil }
            e.inProgress = inProgressLocked(e.id, finished: r.finished)
            return e
        }.sorted {
            $0.start != $1.start ? $0.start > $1.start : $0.id > $1.id
        }
    }

    /// `finished` nil: read from the record, else from run.json itself (a run not indexed yet).
    private func inProgressLocked(_ dir: String, finished: Bool?) -> Bool {
        if dir == active { return true }
        let url = root.appendingPathComponent(dir)
        let done: Bool
        if let finished {
            done = finished
        } else if let r = records?[dir], r.entry != nil {
            // The record may be stale: re-read run.json when it changed since.
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.appendingPathComponent("run.json").path)
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970
            done = mtime == r.mtime ? r.finished : ((try? infoLoader(url))?.end != nil)
        } else {
            done = (try? infoLoader(url))?.end != nil
        }
        guard !done else { return false }
        let samples = url.appendingPathComponent("samples.csv")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: samples.path),
              let written = attrs[.modificationDate] as? Date else { return false }
        return Date().timeIntervalSince(written) < Self.activeWindow
    }

    private func refreshLocked() {
        let loaded = records == nil
        var old = records ?? loadCache()
        let before = old
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0.hasSuffix(".mptrun") }
        var current: [String: Record] = [:]
        for name in names {
            let runJSON = root.appendingPathComponent(name).appendingPathComponent("run.json")
            guard let attrs = try? fm.attributesOfItem(atPath: runJSON.path),
                  let date = attrs[.modificationDate] as? Date else { continue }
            let mtime = date.timeIntervalSince1970
            let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
            if let r = old[name], r.mtime == mtime, r.size == size {
                current[name] = r
            } else {
                current[name] = index(name, mtime: mtime, size: size, previous: old[name])
            }
            old[name] = nil
        }
        records = current
        if loaded || current != before { saveCache(current) }
    }

    /// Parses the bundle: with frames (for `low1`) unless a previous record of the finished run already has it.
    private func index(_ name: String, mtime: Double, size: Int, previous: Record?) -> Record {
        let url = root.appendingPathComponent(name)
        let reuseLow = previous.map { $0.finished && $0.entry != nil } ?? false
        guard let bundle = try? loader(url, !reuseLow) else {
            return Record(mtime: mtime, size: size, entry: nil, finished: false)
        }
        let info = bundle.info
        let summary = RunSummary(bundle)
        let lastElapsed = bundle.rows.last?["elapsed_s"].flatMap(Double.init)
        let duration = info.end.map { $0.timeIntervalSince(info.start) } ?? lastElapsed ?? 0
        let entry = RunEntry(id: name, game: RunEntry.displayGame(info), app: RunEntry.displayApp(info.game.exe),
                             stackLine: SummaryReport.stackLine(info.stack) ?? "",
                             settings: info.user.gameSettings, label: info.user.label, start: info.start,
                             duration: max(0, duration), medianFPS: summary.medianFPS,
                             low1: reuseLow ? previous?.entry?.low1 : summary.low1, finished: info.end != nil)
        return Record(mtime: mtime, size: size, entry: entry, finished: info.end != nil)
    }

    private func loadCache() -> [String: Record] {
        guard let data = try? Data(contentsOf: cacheURL) else { return [:] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        guard let cache = try? dec.decode(Cache.self, from: data), cache.version == Self.cacheVersion else { return [:] }
        return cache.runs
    }

    private func saveCache(_ runs: [String: Record]) {
        // Nothing to cache in a folder that does not exist yet: do not create it.
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        enc.outputFormatting = [.sortedKeys]
        // Best effort: an unwritable cache only costs a re-parse next launch.
        try? enc.encode(Cache(version: Self.cacheVersion, runs: runs)).write(to: cacheURL, options: .atomic)
    }
}

/// Compare projects made from the Runs page.
public enum CompareProjects {
    /// Saves a new project of `runs` (oldest first, the oldest as baseline) named "<game> comparison <yyyy-MM-dd>"
    /// ("Runs comparison …" when the games differ), with " 2", " 3"… appended while that file name is taken.
    /// Returns the project file.
    public static func create(from runs: [RunEntry], projectsRoot: URL, date: Date = Date()) throws -> URL {
        let ordered = runs.sorted { $0.start != $1.start ? $0.start < $1.start : $0.id < $1.id }
        let games = Set(ordered.map(\.game))
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let base = "\(games.count == 1 ? games.first! : "Runs") comparison \(f.string(from: date))"
        // Bounded: an unbounded search spun the main thread forever when every variant mapped to one taken file.
        for n in 1...CompareProject.maxNameTries {
            let name = n == 1 ? base : "\(base) \(n)"
            let url = projectsRoot.appendingPathComponent(CompareProject.fileName(for: name))
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            let project = CompareProject(name: name, baseline: 0, runs: ordered.map { .init(bundle: $0.id) })
            try project.save(to: url)
            return url
        }
        throw CompareProjectError.noFreeName(base)
    }
}
