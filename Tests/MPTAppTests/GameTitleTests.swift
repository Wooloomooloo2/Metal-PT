import Testing
import Foundation
import MPTCore
@testable import MPTApp

/// The editable game title: `game.title` names the game behind an emulator or launcher; `game.exe` (the recorded
/// app) is never edited and stays the comparison ID.
@Suite struct GameTitleTests {
    private func tempRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mpt-title-\(UUID().uuidString)")
    }

    @discardableResult
    private func makeRun(in root: URL, exe: String, title: String? = nil, start: Double) throws -> URL {
        let startDate = Date(timeIntervalSince1970: start)
        let dir = RunBundle.availableDirectory(in: root, start: startDate, game: exe.isEmpty ? "unknown" : exe)
        let info = RunInfo(appVersion: "0.2", machine: .init(modelID: "Mac15,6", chip: "Apple M3 Pro", gpuCores: 14,
                                                             memoryGB: 36, osVersion: "15.1", osBuild: "24B83"),
                           game: .init(exe: exe, title: title), stack: Stack(runtime: "Native"),
                           user: .init(label: "lbl", gameSettings: "High", notes: "n"),
                           start: startDate, fpsSource: "log")
        let w = try RunBundleWriter(directory: dir, info: info)
        for i in 1...30 { try w.append(sample: ["elapsed_s": "\(i)", "fps": "60", "fps_app": exe]) }
        try w.finish { $0.end = startDate.addingTimeInterval(30) }
        return dir
    }

    private func entry(_ id: String, game: String, app: String, start: Double) -> RunEntry {
        RunEntry(id: id, game: game, app: app, stackLine: "", settings: "", label: "",
                 start: Date(timeIntervalSince1970: start), duration: 30, medianFPS: 60, low1: nil)
    }

    @Test func updateSetsAndClearsTheTitleAndNeverTouchesTheExe() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try makeRun(in: root, exe: "ARMSX2", start: 1_800_000_000)
        let name = dir.lastPathComponent
        let index = RunIndex(root: root)
        let before = try #require(index.entries().first)
        #expect(before.game == "ARMSX2")
        #expect(before.app == "ARMSX2")
        #expect(before.title == nil)

        try index.update(dir: name, settings: "High", notes: "n", label: "lbl", title: "  Shadow of the Colossus  ")
        var info = try RunBundle.loadInfo(dir)
        #expect(info.game.title == "Shadow of the Colossus")   // trimmed
        #expect(info.game.exe == "ARMSX2")
        var e = try #require(index.entries().first)
        #expect(e.id == before.id)
        #expect(e.game == "Shadow of the Colossus")
        #expect(e.app == "ARMSX2")
        #expect(e.title == "Shadow of the Colossus")
        let html = try String(contentsOf: dir.appendingPathComponent(SummaryReport.fileName), encoding: .utf8)
        #expect(html.contains("<h1>Shadow of the Colossus</h1>"))
        #expect(html.contains("<dt>Recorded app</dt><dd>ARMSX2</dd>"))

        // nil leaves the title as it is.
        try index.update(dir: name, settings: "Low", notes: "n", label: "lbl", title: nil)
        #expect(try RunBundle.loadInfo(dir).game.title == "Shadow of the Colossus")
        // The old four-argument form leaves it too.
        try index.update(dir: name, settings: "Low", notes: "n", label: "lbl")
        #expect(try RunBundle.loadInfo(dir).game.title == "Shadow of the Colossus")

        // Review Focus 1: empty clears it, and so does the app's own name; the run shows the app name again.
        try index.update(dir: name, settings: "Low", notes: "n", label: "lbl", title: "   ")
        info = try RunBundle.loadInfo(dir)
        #expect(info.game.title == nil)
        #expect(info.game.exe == "ARMSX2")
        e = try #require(index.entries().first)
        #expect(e.game == "ARMSX2")
        #expect(e.title == nil)

        try index.update(dir: name, settings: "Low", notes: "n", label: "lbl", title: "Ico")
        #expect(try RunBundle.loadInfo(dir).game.title == "Ico")
        try index.update(dir: name, settings: "Low", notes: "n", label: "lbl", title: "armsx2")
        #expect(try RunBundle.loadInfo(dir).game.title == nil)
        #expect(try #require(index.entries().first).game == "ARMSX2")
    }

    @Test func titleIsPrivacyScrubbedAndCapped() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try makeRun(in: root, exe: "launcher.exe", start: 1_800_000_000)
        let index = RunIndex(root: root)
        _ = index.entries()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        try index.update(dir: dir.lastPathComponent, settings: "", notes: "", label: "", title: "\(home)/Games/x")
        #expect(try RunBundle.loadInfo(dir).game.title == "~/Games/x")

        try index.update(dir: dir.lastPathComponent, settings: "", notes: "", label: "",
                         title: String(repeating: "a", count: 300))
        #expect(try RunBundle.loadInfo(dir).game.title?.count == RunEntry.maxTitleLength)
        #expect(RunEntry.maxTitleLength == 120)

        // Equal to the exe's display name (without ".exe") clears, as does the exe itself.
        try index.update(dir: dir.lastPathComponent, settings: "", notes: "", label: "", title: "Launcher")
        #expect(try RunBundle.loadInfo(dir).game.title == nil)
        try index.update(dir: dir.lastPathComponent, settings: "", notes: "", label: "", title: "Elden Ring")
        try index.update(dir: dir.lastPathComponent, settings: "", notes: "", label: "", title: "launcher.exe")
        #expect(try RunBundle.loadInfo(dir).game.title == nil)
    }

    @Test func unknownGameCanBeTitled() throws {
        // Review Focus 2.
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try makeRun(in: root, exe: "", start: 1_800_000_000)
        let index = RunIndex(root: root)
        let before = try #require(index.entries().first)
        #expect(before.game == "Unknown game")
        #expect(before.app == "")
        #expect(before.title == nil)
        try index.update(dir: dir.lastPathComponent, settings: "", notes: "", label: "", title: "Okami")
        let e = try #require(index.entries().first)
        #expect(e.game == "Okami")
        #expect(e.title == "Okami")
        #expect(e.app == "")
        #expect(try RunBundle.loadInfo(dir).game.exe == "")
        #expect(RunEntry.titleSuggestions(index.entries(), forApp: "").isEmpty)
    }

    @Test func suggestionsAreTitlesOfTheSameAppNewestFirst() {
        let entries = [   // newest first, as the index lists them
            entry("5", game: "Shadow of the Colossus", app: "ARMSX2", start: 5),
            entry("4", game: "Okami", app: "PCSX2", start: 4),
            entry("3", game: "Ico", app: "ARMSX2", start: 3),
            entry("2", game: "ARMSX2", app: "ARMSX2", start: 2),          // untitled
            entry("1", game: "shadow of the colossus", app: "ARMSX2", start: 1),
        ]
        #expect(RunEntry.titleSuggestions(entries, forApp: "ARMSX2") == ["Shadow of the Colossus", "Ico"])
        #expect(RunEntry.titleSuggestions(entries, forApp: "PCSX2") == ["Okami"])
        #expect(RunEntry.titleSuggestions(entries, forApp: "Other").isEmpty)
    }

    @Test func filterMatchesTheRecordedAppToo() {
        let e = entry("1", game: "Shadow of the Colossus", app: "ARMSX2", start: 1)
        #expect(e.matches("armsx2"))
        #expect(e.matches("colossus"))
        #expect(!e.matches("pcsx2"))
    }

    @Test func differentTitlesOfOneAppAreDifferentGamesInAddRuns() {
        // Review Focus 3.
        let sotc = entry("a", game: "Shadow of the Colossus", app: "ARMSX2", start: 2)
        let ico = entry("b", game: "Ico", app: "ARMSX2", start: 1)
        #expect(CompareLibrary.sameGame([sotc, ico], games: ["Shadow of the Colossus"]).map(\.id) == ["a"])
    }

    @Test func sameGameMatchingIgnoresCaseAndWhitespace() {
        let upper = entry("a", game: "Ico", app: "ARMSX2", start: 2)
        let lower = entry("b", game: " ico ", app: "ARMSX2", start: 1)
        #expect(CompareLibrary.sameGame([upper, lower], games: ["ico"]).map(\.id) == ["a", "b"])
    }

    @Test func olderCacheVersionIsRebuilt() throws {
        #expect(RunIndex.cacheVersion == 4)
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeRun(in: root, exe: "ARMSX2", title: "Ico", start: 1_800_000_000)
        _ = RunIndex(root: root).entries()
        let cache = root.appendingPathComponent(RunIndex.cacheFileName)
        let text = try String(contentsOf: cache, encoding: .utf8)
        #expect(text.contains("\"version\":4"))
        // The same cache marked version 3 (entries had no FPS per watt) is ignored: the run is parsed again.
        final class Count: @unchecked Sendable { var n = 0 }
        let count = Count()
        let counting: RunIndex.Loader = { url, frames in count.n += 1; return try RunBundle.load(url, frames: frames) }
        _ = RunIndex(root: root, loader: counting).entries()
        #expect(count.n == 0)   // current cache reused
        try Data(text.replacingOccurrences(of: "\"version\":4", with: "\"version\":3").utf8).write(to: cache)
        let e = try #require(RunIndex(root: root, loader: counting).entries().first)
        #expect(count.n == 1)
        #expect(e.game == "Ico")
        #expect(e.app == "ARMSX2")
        #expect(try String(contentsOf: cache, encoding: .utf8).contains("\"version\":4"))
    }
}

@Suite struct AppUnderTitleTests {
    private func entry(game: String, app: String) -> RunEntry {
        RunEntry(id: "x", game: game, app: app, stackLine: "", settings: "", label: "",
                 start: Date(timeIntervalSince1970: 1), duration: 30, medianFPS: 60, low1: nil)
    }

    @Test func showsTheRecordedAppOnlyUnderADifferingTitle() {
        #expect(entry(game: "Ico", app: "ARMSX2").appUnderTitle == "ARMSX2")
        #expect(entry(game: "ARMSX2", app: "ARMSX2").appUnderTitle == nil)
        #expect(entry(game: "Unknown game", app: "").appUnderTitle == nil)
    }
}
