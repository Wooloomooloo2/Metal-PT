import Testing
import Foundation
import MPTCore
@testable import MPTApp

@Suite struct RunIndexTests {
    /// Counts loads by kind (frames or not) around the real loader.
    private final class CountingLoader: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var withFrames = 0
        private(set) var withoutFrames = 0
        var total: Int { lock.withLock { withFrames + withoutFrames } }
        func load(_ url: URL, frames: Bool) throws -> RunBundle {
            lock.withLock { if frames { withFrames += 1 } else { withoutFrames += 1 } }
            return try RunBundle.load(url, frames: frames)
        }
    }

    private func tempRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mpt-index-\(UUID().uuidString)")
    }

    /// A finished bundle: 30 s of rows (the first 10 s are trimmed as warm-up), frames at 16.7 ms with a few 50 ms spikes.
    @discardableResult
    private func makeRun(in root: URL, game: String, start: Double, fps: Double = 60,
                         settings: String = "High", notes: String = "") throws -> URL {
        let startDate = Date(timeIntervalSince1970: start)
        let dir = RunBundle.availableDirectory(in: root, start: startDate, game: game)
        let info = RunInfo(appVersion: "0.2", machine: .init(modelID: "Mac15,6", chip: "Apple M3 Pro", gpuCores: 14,
                                                             memoryGB: 36, osVersion: "15.1", osBuild: "24B83"),
                           game: .init(exe: game), stack: Stack(runtime: "Protium", translator: "FEX", graphics: ["DXMT"]),
                           user: .init(label: "lbl", gameSettings: settings, notes: notes),
                           start: startDate, fpsSource: "log")
        let w = try RunBundleWriter(directory: dir, info: info)
        for i in 1...30 {
            try w.append(sample: ["elapsed_s": "\(i)", "fps": "\(fps)", "fps_app": game])
        }
        var frames = (0..<1800).map { _ in FrameTime(intervalMs: 16.7, presentDelayMs: 1) }
        for i in stride(from: 0, to: 1800, by: 100) { frames[i] = FrameTime(intervalMs: 50, presentDelayMs: 1) }
        try w.append(frames: frames, endingAtMs: 30_000)
        try w.finish { $0.end = startDate.addingTimeInterval(30) }
        return dir
    }

    /// An unfinished bundle (no `end`): 30 s of rows, frames with one 100 ms spike per second for the first 15 s.
    private func makeUnfinished(in root: URL, game: String = "live.exe") throws -> (URL, RunBundleWriter) {
        let startDate = Date(timeIntervalSince1970: 1_800_000_500)
        let dir = RunBundle.availableDirectory(in: root, start: startDate, game: game)
        let info = RunInfo(appVersion: "0.2", machine: .init(modelID: "Mac15,6", chip: "Apple M3 Pro", gpuCores: 14,
                                                             memoryGB: 36, osVersion: "15.1", osBuild: "24B83"),
                           game: .init(exe: game), start: startDate, fpsSource: "log")
        let w = try RunBundleWriter(directory: dir, info: info)
        for i in 1...30 { try w.append(sample: ["elapsed_s": "\(i)", "fps": "60", "fps_app": game]) }
        var frames = (0..<900).map { _ in FrameTime(intervalMs: 16.7, presentDelayMs: 1) }
        for i in stride(from: 0, to: 900, by: 60) { frames[i] = FrameTime(intervalMs: 100, presentDelayMs: 1) }
        try w.append(frames: frames, endingAtMs: 15_000)
        return (dir, w)
    }

    @Test func unfinishedRunIsInProgressAndLocked() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (dir, w) = try makeUnfinished(in: root)
        let index = RunIndex(root: root)
        let e = try #require(index.entries().first)
        #expect(!e.finished)
        #expect(e.inProgress)   // samples.csv written just now
        #expect(throws: RunIndexError.self) {
            try index.update(dir: dir.lastPathComponent, settings: "x", notes: "", label: "")
        }
        #expect(throws: RunIndexError.self) { try index.delete(dir: dir.lastPathComponent) }
        #expect(FileManager.default.fileExists(atPath: dir.path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(SummaryReport.fileName).path))

        try w.finish { $0.end = $0.start.addingTimeInterval(30) }
        let done = try #require(index.entries().first)
        #expect(done.finished)
        #expect(!done.inProgress)
        try index.update(dir: dir.lastPathComponent, settings: "x", notes: "", label: "")
        #expect(index.entries().first?.settings == "x")
    }

    @Test func staleUnfinishedRunIsNotInProgress() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (dir, _) = try makeUnfinished(in: root)
        // A crashed recording: samples.csv untouched for a minute.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)],
                                              ofItemAtPath: dir.appendingPathComponent("samples.csv").path)
        let index = RunIndex(root: root)
        let e = try #require(index.entries().first)
        #expect(!e.finished)
        #expect(!e.inProgress)
        try index.update(dir: dir.lastPathComponent, settings: "y", notes: "", label: "")   // allowed
    }

    @Test func activeDirectoryIsInProgressWhateverTheTimes() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (dir, _) = try makeUnfinished(in: root)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)],
                                              ofItemAtPath: dir.appendingPathComponent("samples.csv").path)
        let index = RunIndex(root: root)
        index.activeDirectory = dir.lastPathComponent
        #expect(index.entries().first?.inProgress == true)
        #expect(throws: RunIndexError.self) { try index.delete(dir: dir.lastPathComponent) }
    }

    @Test func lowIsRecomputedWhenAnUnfinishedRunFinishes() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (dir, w) = try makeUnfinished(in: root)
        let counter = CountingLoader()
        let index = RunIndex(root: root, loader: counter.load)
        let partial = try #require(index.entries().first)
        #expect(counter.withFrames == 1)
        // The rest of the run: smooth frames for 15 s, then finish.
        try w.append(frames: (0..<900).map { _ in FrameTime(intervalMs: 16.7, presentDelayMs: 1) },
                     endingAtMs: 30_000)
        try w.finish { $0.end = $0.start.addingTimeInterval(30) }
        let final = try #require(index.entries().first)
        #expect(counter.withFrames == 2)
        let expected = RunSummary(try RunBundle.load(dir)).low1
        #expect(final.low1 == expected)
        #expect(final.low1 != partial.low1)
        // Finished now: an edit reuses it.
        try index.update(dir: dir.lastPathComponent, settings: "s", notes: "", label: "")
        #expect(index.entries().first?.low1 == expected)
        #expect(counter.withFrames == 2)
    }

    @Test func brokenRecordDoesNotReuseLow() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try makeRun(in: root, game: "a.exe", start: 1_800_000_000)
        let runJSON = dir.appendingPathComponent("run.json")
        let good = try Data(contentsOf: runJSON)
        try Data("{broken".utf8).write(to: runJSON)
        let counter = CountingLoader()
        let index = RunIndex(root: root, loader: counter.load)
        #expect(index.entries().isEmpty)
        try good.write(to: runJSON)
        let e = try #require(index.entries().first)
        #expect(e.low1 != nil)
        #expect(counter.withFrames == 2)   // the broken attempt, then a full parse
    }

    @Test func indexSkipsFramesAndCaches() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeRun(in: root, game: "hzd.exe", start: 1_800_000_000)
        try makeRun(in: root, game: "Cyberpunk2077.exe", start: 1_800_000_100, fps: 45)
        let counter = CountingLoader()
        let index = RunIndex(root: root, loader: counter.load)

        let first = index.entries()
        #expect(first.count == 2)
        #expect(first.map(\.game) == ["Cyberpunk2077", "hzd"])   // newest first, ".exe" dropped
        #expect(first[0].stackLine == "Protium · FEX · DXMT")
        #expect(first[0].settings == "High")
        #expect(first[0].label == "lbl")
        #expect(first[0].duration == 30)
        #expect(first[0].medianFPS == 45)
        #expect(first[0].low1 != nil)   // computed once, from frames
        #expect(counter.withFrames == 2)
        let loadsAfterFirst = counter.total

        // Same instance: nothing re-parsed.
        let second = index.entries()
        #expect(second == first)
        #expect(counter.total == loadsAfterFirst)

        // A new instance on the same root reads the cache file, not the bundles.
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".index.json").path))
        let counter2 = CountingLoader()
        let fresh = RunIndex(root: root, loader: counter2.load)
        #expect(fresh.entries() == first)
        #expect(counter2.total == 0)
    }

    @Test func updateRewritesUserFieldsAndSummary() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try makeRun(in: root, game: "hzd.exe", start: 1_800_000_000, notes: "old")
        let counter = CountingLoader()
        let index = RunIndex(root: root, loader: counter.load)
        let before = try #require(index.entries().first)
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        try index.update(dir: dir.lastPathComponent, settings: "Ultra, 1440p", notes: "saved in \(home)/x",
                         label: "after patch")

        let info = try RunBundle.load(dir, frames: false).info
        #expect(info.user.gameSettings == "Ultra, 1440p")
        #expect(info.user.label == "after patch")
        #expect(info.user.notes == "saved in ~/x")   // through Privacy.scrub
        #expect(info.end != nil)                      // the rest of run.json kept
        let html = try String(contentsOf: dir.appendingPathComponent(SummaryReport.fileName), encoding: .utf8)
        #expect(html.contains("Ultra, 1440p"))
        #expect(html.contains("after patch"))

        let after = try #require(index.entries().first)
        #expect(after.id == before.id)              // folder name unchanged
        #expect(after.settings == "Ultra, 1440p")
        #expect(after.label == "after patch")
        #expect(after.low1 == before.low1)          // kept from the cache
        #expect(counter.withFrames == 1)            // frames parsed only at first index
        #expect(try index.userFields(dir: dir.lastPathComponent).notes == "saved in ~/x")
    }

    @Test func removedRunDropsFromIndex() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try makeRun(in: root, game: "a.exe", start: 1_800_000_000)
        try makeRun(in: root, game: "b.exe", start: 1_800_000_100)
        let index = RunIndex(root: root)
        #expect(index.entries().count == 2)
        try FileManager.default.removeItem(at: a)
        #expect(index.entries().map(\.game) == ["b"])
        // And the cache file no longer lists it.
        let counter = CountingLoader()
        #expect(RunIndex(root: root, loader: counter.load).entries().map(\.game) == ["b"])
        #expect(counter.total == 0)
    }

    @Test func corruptCacheRebuildsSilently() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeRun(in: root, game: "a.exe", start: 1_800_000_000)
        try Data("{not json".utf8).write(to: root.appendingPathComponent(".index.json"))
        let counter = CountingLoader()
        #expect(RunIndex(root: root, loader: counter.load).entries().count == 1)
        #expect(counter.withFrames == 1)

        // A cache from another format version is rebuilt too.
        try Data(#"{"version": 999, "runs": {}}"#.utf8).write(to: root.appendingPathComponent(".index.json"))
        let counter2 = CountingLoader()
        #expect(RunIndex(root: root, loader: counter2.load).entries().count == 1)
        #expect(counter2.withFrames == 1)
    }

    @Test func ignoresNonRunsAndMissingRoot() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(RunIndex(root: root).entries().isEmpty)   // no folder yet
        try makeRun(in: root, game: "a.exe", start: 1_800_000_000)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("junk.mptrun"),
                                                withIntermediateDirectories: true)   // no run.json
        try FileManager.default.createDirectory(at: root.appendingPathComponent("other"),
                                                withIntermediateDirectories: true)
        #expect(RunIndex(root: root).entries().count == 1)
    }

    @Test func deleteMovesRunToTrash() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try makeRun(in: root, game: "a.exe", start: 1_800_000_000)
        let index = RunIndex(root: root)
        #expect(index.entries().count == 1)
        final class Box: @unchecked Sendable { var url: URL? }
        let trashed = Box()
        let deleting = RunIndex(root: root, trash: { url in
            trashed.url = url
            try FileManager.default.removeItem(at: url)
        })
        try deleting.delete(dir: a.lastPathComponent)
        #expect(trashed.url?.lastPathComponent == a.lastPathComponent)
        #expect(deleting.entries().isEmpty)
    }

    @Test func compareProjectFromRunsIsUnique() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runs = root.appendingPathComponent("runs")
        let projects = root.appendingPathComponent("projects")
        try makeRun(in: runs, game: "hzd.exe", start: 1_800_000_000)
        try makeRun(in: runs, game: "hzd.exe", start: 1_800_000_100)
        let entries = RunIndex(root: runs).entries()
        let date = Date(timeIntervalSince1970: 1_800_000_200)
        let url1 = try CompareProjects.create(from: entries, projectsRoot: projects, date: date)
        let url2 = try CompareProjects.create(from: entries, projectsRoot: projects, date: date)
        #expect(url1 != url2)
        let p1 = try CompareProject.load(url1)
        let p2 = try CompareProject.load(url2)
        #expect(p1.name.hasPrefix("hzd comparison "))
        #expect(p2.name == p1.name + " 2")
        // Oldest first, as the baseline; bare folder names (they sit in the runs folder).
        #expect(p1.runs.map(\.bundle) == entries.reversed().map(\.id))
        #expect(p1.baseline == 0)
    }
}
