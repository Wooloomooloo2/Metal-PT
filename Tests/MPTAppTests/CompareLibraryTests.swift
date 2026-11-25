import Testing
import Foundation
import MPTCore
@testable import MPTApp

/// The Compare page's project store: every edit saves the JSON and rewrites the report.
@Suite struct CompareLibraryTests {
    private struct Setup {
        let root: URL
        var runs: URL { root.appendingPathComponent("runs") }
        var projects: URL { root.appendingPathComponent("projects") }
    }

    private func setup() -> Setup {
        Setup(root: FileManager.default.temporaryDirectory.appendingPathComponent("mpt-library-\(UUID().uuidString)"))
    }

    @discardableResult
    private func makeRun(in root: URL, game: String, start: Double, runtime: String, finished: Bool = true) throws -> URL {
        let startDate = Date(timeIntervalSince1970: start)
        let dir = RunBundle.availableDirectory(in: root, start: startDate, game: game)
        let info = RunInfo(appVersion: "0.2", machine: .init(modelID: "Mac15,6", chip: "Apple M3 Pro", gpuCores: 14,
                                                             memoryGB: 36, osVersion: "15.1", osBuild: "24B83"),
                           game: .init(exe: game), stack: Stack(runtime: runtime, graphics: ["DXMT"]),
                           start: startDate, fpsSource: "log")
        let w = try RunBundleWriter(directory: dir, info: info)
        for i in 1...30 { try w.append(sample: ["elapsed_s": "\(i)", "fps": "60", "fps_app": game]) }
        if finished { try w.finish { $0.end = startDate.addingTimeInterval(30) } }
        return dir
    }

    private func html(_ s: Setup, _ id: String) throws -> String {
        let url = s.projects.appendingPathComponent(id).deletingPathExtension().appendingPathExtension("html")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The list and the detail read each run's run.json only (through the info loader), never its samples.
    @Test func listAndDetailReadOnlyRunJSON() throws {
        final class Count: @unchecked Sendable {
            let lock = NSLock(); var n = 0
            func load(_ url: URL) throws -> RunInfo { lock.withLock { n += 1 }; return try RunBundle.loadInfo(url) }
        }
        let s = setup()
        defer { try? FileManager.default.removeItem(at: s.root) }
        let a = try makeRun(in: s.runs, game: "hzd.exe", start: 1_800_000_000, runtime: "Protium")
        let b = try makeRun(in: s.runs, game: "hzd.exe", start: 1_800_000_100, runtime: "CrossOver")
        try CompareProject(name: "HZD", runs: [.init(bundle: a.lastPathComponent), .init(bundle: b.lastPathComponent)])
            .save(to: s.projects.appendingPathComponent("hzd.json"))
        let count = Count()
        let lib = CompareLibrary(projectsRoot: s.projects, runsRoot: s.runs, infoLoader: count.load)
        #expect(lib.projects().first?.game == "hzd")
        #expect(count.n == 2)
        #expect(try lib.detail("hzd.json").runs.allSatisfy { $0.missing == nil })
        #expect(count.n == 4)
    }

    @Test func listsProjectsWithRunCountGameAndDate() throws {
        let s = setup()
        defer { try? FileManager.default.removeItem(at: s.root) }
        let a = try makeRun(in: s.runs, game: "hzd.exe", start: 1_800_000_000, runtime: "Protium")
        let b = try makeRun(in: s.runs, game: "hzd.exe", start: 1_800_000_100, runtime: "CrossOver")
        let c = try makeRun(in: s.runs, game: "cp.exe", start: 1_800_000_200, runtime: "CrossOver")
        try CompareProject(name: "HZD", runs: [.init(bundle: a.lastPathComponent), .init(bundle: b.lastPathComponent)])
            .save(to: s.projects.appendingPathComponent("hzd.json"))
        try CompareProject(name: "Mixed", runs: [.init(bundle: a.lastPathComponent), .init(bundle: c.lastPathComponent),
                                                 .init(bundle: "gone.mptrun")])
            .save(to: s.projects.appendingPathComponent("mixed.json"))
        try Data("{".utf8).write(to: s.projects.appendingPathComponent("broken.json"))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
                                              ofItemAtPath: s.projects.appendingPathComponent("hzd.json").path)

        let list = CompareLibrary(projectsRoot: s.projects, runsRoot: s.runs).projects()
        #expect(list.map(\.id) == ["broken.json", "mixed.json", "hzd.json"] ||
                list.map(\.id) == ["mixed.json", "broken.json", "hzd.json"])   // newest first
        let hzd = try #require(list.first { $0.id == "hzd.json" })
        #expect(hzd.name == "HZD" && hzd.runCount == 2 && hzd.game == "hzd" && hzd.problem == nil)
        #expect(hzd.modified == Date(timeIntervalSince1970: 1_700_000_000))
        let mixed = try #require(list.first { $0.id == "mixed.json" })
        #expect(mixed.runCount == 3 && mixed.game == "2 games")
        let broken = try #require(list.first { $0.id == "broken.json" })
        #expect(broken.problem != nil && broken.name == "broken")
    }

    @Test func detailNumbersRunsLikeTheCLIAndMarksMissing() throws {
        let s = setup()
        defer { try? FileManager.default.removeItem(at: s.root) }
        let a = try makeRun(in: s.runs, game: "hzd.exe", start: 1_800_000_000, runtime: "Protium")
        try CompareProject(name: "P", baseline: 1,
                           runs: [.init(bundle: "gone.mptrun", name: "old"), .init(bundle: a.lastPathComponent)])
            .save(to: s.projects.appendingPathComponent("p.json"))
        let d = try CompareLibrary(projectsRoot: s.projects, runsRoot: s.runs).detail("p.json")
        #expect(d.name == "P" && d.baseline == 1)
        #expect(d.runs.map(\.number) == [1, 2])
        #expect(d.runs[0].label == "old" && d.runs[0].missing == "the run folder is gone" && !d.runs[0].isBaseline)
        #expect(d.runs[1].label == "Protium DXMT" && d.runs[1].missing == nil && d.runs[1].isBaseline)
    }

    @Test func editsSaveTheProjectAndRewriteTheReport() throws {
        let s = setup()
        defer { try? FileManager.default.removeItem(at: s.root) }
        let a = try makeRun(in: s.runs, game: "hzd.exe", start: 1_800_000_000, runtime: "Protium")
        let b = try makeRun(in: s.runs, game: "hzd.exe", start: 1_800_000_100, runtime: "CrossOver")
        let c = try makeRun(in: s.runs, game: "hzd.exe", start: 1_800_000_200, runtime: "Whisky")
        try CompareProject(name: "P", runs: [.init(bundle: a.lastPathComponent)])
            .save(to: s.projects.appendingPathComponent("p.json"))
        let lib = CompareLibrary(projectsRoot: s.projects, runsRoot: s.runs)
        let file = s.projects.appendingPathComponent("p.json")

        try lib.add("p.json", bundles: [b.lastPathComponent, c.lastPathComponent])
        #expect(try CompareProject.load(file).runs.map(\.bundle) == [a, b, c].map(\.lastPathComponent))
        #expect(try html(s, "p.json").contains("Whisky"))
        #expect(throws: CompareProjectError.self) { try lib.add("p.json", bundles: [a.lastPathComponent]) }

        try lib.setBaseline("p.json", index: 2)
        #expect(try CompareProject.load(file).baseline == 2)

        #expect(try lib.remove("p.json", index: 2) == true)   // the baseline: run 1 takes over
        var p = try CompareProject.load(file)
        #expect(p.baseline == 0 && p.runs.count == 2)
        #expect(try !html(s, "p.json").contains("Whisky"))

        try lib.setBaseline("p.json", index: 1)
        #expect(try lib.remove("p.json", index: 0) == false)   // before the baseline: it stays on the same run
        p = try CompareProject.load(file)
        #expect(p.baseline == 0)
        #expect(p.runs.map(\.bundle) == [b.lastPathComponent])
        #expect(try !html(s, "p.json").contains("Protium"))
    }

    @Test func reportIsRegeneratedOnOpen() throws {
        let s = setup()
        defer { try? FileManager.default.removeItem(at: s.root) }
        let a = try makeRun(in: s.runs, game: "hzd.exe", start: 1_800_000_000, runtime: "Protium")
        let b = try makeRun(in: s.runs, game: "hzd.exe", start: 1_800_000_100, runtime: "CrossOver")
        try CompareProject(name: "P", runs: [.init(bundle: a.lastPathComponent), .init(bundle: b.lastPathComponent)])
            .save(to: s.projects.appendingPathComponent("p.json"))
        let lib = CompareLibrary(projectsRoot: s.projects, runsRoot: s.runs)
        let url = try lib.report("p.json")
        #expect(url.lastPathComponent == "p.html")
        let before = try String(contentsOf: url, encoding: .utf8)
        try FileManager.default.removeItem(at: b)   // trashed since
        let after = try String(contentsOf: try lib.report("p.json"), encoding: .utf8)
        #expect(before != after)
        #expect(after.contains("the run folder is gone"))
    }

    @Test func renameMovesTheFilesAndRefusesATakenSlug() throws {
        let s = setup()
        defer { try? FileManager.default.removeItem(at: s.root) }
        let a = try makeRun(in: s.runs, game: "hzd.exe", start: 1_800_000_000, runtime: "Protium")
        try CompareProject(name: "P", runs: [.init(bundle: a.lastPathComponent)])
            .save(to: s.projects.appendingPathComponent("p.json"))
        try CompareProject(name: "Other").save(to: s.projects.appendingPathComponent("other.json"))
        let lib = CompareLibrary(projectsRoot: s.projects, runsRoot: s.runs)
        _ = try lib.report("p.json")

        #expect(throws: CompareProjectError.fileHoldsOther(file: "other.json", project: "Other")) {
            try lib.rename("p.json", to: "OTHER")
        }
        #expect(throws: CompareLibraryError.emptyName) { try lib.rename("p.json", to: "  ") }

        // Same slug: renamed in place.
        #expect(try lib.rename("p.json", to: " p ") == "p.json")
        #expect(try CompareProject.load(s.projects.appendingPathComponent("p.json")).name == "p")

        let id = try lib.rename("p.json", to: "HZD stacks")
        #expect(id == "hzd-stacks.json")
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: s.projects.appendingPathComponent("p.json").path))
        #expect(!fm.fileExists(atPath: s.projects.appendingPathComponent("p.html").path))
        #expect(try CompareProject.load(s.projects.appendingPathComponent(id)).name == "HZD stacks")
        #expect(try html(s, id).contains("HZD stacks"))
    }

    @Test func deleteTrashesProjectAndReport() throws {
        let s = setup()
        defer { try? FileManager.default.removeItem(at: s.root) }
        try CompareProject(name: "P").save(to: s.projects.appendingPathComponent("p.json"))
        final class Box: @unchecked Sendable { var names: [String] = [] }
        let trashed = Box()
        let lib = CompareLibrary(projectsRoot: s.projects, runsRoot: s.runs, trash: { url in
            trashed.names.append(url.lastPathComponent)
            try FileManager.default.removeItem(at: url)
        })
        _ = try lib.report("p.json")
        try lib.delete("p.json")
        #expect(trashed.names.sorted() == ["p.html", "p.json"])
        #expect(lib.projects().isEmpty)
    }

    @Test func candidatesAreFinishedRunsNotInTheProject() throws {
        let s = setup()
        defer { try? FileManager.default.removeItem(at: s.root) }
        let a = try makeRun(in: s.runs, game: "hzd.exe", start: 1_800_000_000, runtime: "Protium")
        let b = try makeRun(in: s.runs, game: "hzd.exe", start: 1_800_000_100, runtime: "CrossOver")
        let c = try makeRun(in: s.runs, game: "hzd.exe", start: 1_800_000_200, runtime: "Whisky")
        _ = try makeRun(in: s.runs, game: "live.exe", start: 1_800_000_300, runtime: "Whisky", finished: false)
        // b stored by absolute path (added from outside the runs folder view): still counts as in the project.
        try CompareProject(name: "P", runs: [.init(bundle: a.lastPathComponent), .init(bundle: b.path)])
            .save(to: s.projects.appendingPathComponent("p.json"))
        let lib = CompareLibrary(projectsRoot: s.projects, runsRoot: s.runs)
        let entries = RunIndex(root: s.runs).entries()
        #expect(entries.count == 4)
        let candidates = lib.candidates(try lib.detail("p.json"), from: entries)
        #expect(candidates.map(\.id) == [c.lastPathComponent])
    }

    @Test func addRunsOffersTheComparisonsGameFirst() throws {
        let s = setup()
        defer { try? FileManager.default.removeItem(at: s.root) }
        let a = try makeRun(in: s.runs, game: "hzd.exe", start: 1_800_000_000, runtime: "CrossOver")
        let b = try makeRun(in: s.runs, game: "hzd.exe", start: 1_800_000_100, runtime: "CrossOver")
        let c = try makeRun(in: s.runs, game: "re9.exe", start: 1_800_000_200, runtime: "CrossOver")
        try CompareProject(name: "P", runs: [.init(bundle: a.lastPathComponent), .init(bundle: "gone.mptrun")])
            .save(to: s.projects.appendingPathComponent("p.json"))
        let lib = CompareLibrary(projectsRoot: s.projects, runsRoot: s.runs)
        let entries = RunIndex(root: s.runs).entries()
        let detail = try lib.detail("p.json")
        let games = lib.games(detail, in: entries)
        #expect(games == ["hzd"])
        let candidates = lib.candidates(detail, from: entries)
        #expect(Set(candidates.map(\.id)) == [b.lastPathComponent, c.lastPathComponent])
        #expect(CompareLibrary.sameGame(candidates, games: games).map(\.id) == [b.lastPathComponent])
        // Nothing known about the comparison's runs: everything is offered.
        #expect(CompareLibrary.sameGame(candidates, games: []).count == 2)
    }

    @Test func addWithBaselineSetsThatRunInTheSameEdit() throws {
        let s = setup()
        defer { try? FileManager.default.removeItem(at: s.root) }
        let a = try makeRun(in: s.runs, game: "hzd.exe", start: 1_800_000_000, runtime: "CrossOver")
        let b = try makeRun(in: s.runs, game: "hzd.exe", start: 1_800_000_100, runtime: "Protium")
        let c = try makeRun(in: s.runs, game: "re9.exe", start: 1_800_000_200, runtime: "Whisky")
        let file = s.projects.appendingPathComponent("p.json")
        try CompareProject(name: "P", runs: [.init(bundle: a.lastPathComponent)]).save(to: file)
        let lib = CompareLibrary(projectsRoot: s.projects, runsRoot: s.runs)

        // A run of another game as the baseline: added, baseline is its index, the report still warns.
        try lib.add("p.json", bundles: [b.lastPathComponent, c.lastPathComponent], baseline: c.lastPathComponent)
        let p = try CompareProject.load(file)
        #expect(p.runs.map(\.bundle) == [a, b, c].map(\.lastPathComponent))
        #expect(p.baseline == 2)
        let page = try html(s, "p.json")
        #expect(page.contains("Whisky"))
        #expect(page.contains("different games"))

        // Without a baseline it stays where it was.
        let d = try makeRun(in: s.runs, game: "hzd.exe", start: 1_800_000_300, runtime: "DXMT")
        try lib.add("p.json", bundles: [d.lastPathComponent])
        #expect(try CompareProject.load(file).baseline == 2)
    }

    @Test func addWithBaselineOutsideTheAddedRunsRefusesAll() throws {
        let s = setup()
        defer { try? FileManager.default.removeItem(at: s.root) }
        let a = try makeRun(in: s.runs, game: "hzd.exe", start: 1_800_000_000, runtime: "CrossOver")
        let b = try makeRun(in: s.runs, game: "hzd.exe", start: 1_800_000_100, runtime: "Protium")
        let file = s.projects.appendingPathComponent("p.json")
        try CompareProject(name: "P", runs: [.init(bundle: a.lastPathComponent)]).save(to: file)
        let lib = CompareLibrary(projectsRoot: s.projects, runsRoot: s.runs)
        #expect(throws: CompareLibraryError.baselineNotAdded("nope.mptrun")) {
            try lib.add("p.json", bundles: [b.lastPathComponent], baseline: "nope.mptrun")
        }
        #expect(try CompareProject.load(file).runs.count == 1)
    }

    @Test func addWithBaselineThatCannotSaveChangesNothing() throws {
        let s = setup()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: s.projects.path)
            try? FileManager.default.removeItem(at: s.root)
        }
        let a = try makeRun(in: s.runs, game: "hzd.exe", start: 1_800_000_000, runtime: "CrossOver")
        let b = try makeRun(in: s.runs, game: "hzd.exe", start: 1_800_000_100, runtime: "Protium")
        let file = s.projects.appendingPathComponent("p.json")
        try CompareProject(name: "P", runs: [.init(bundle: a.lastPathComponent)]).save(to: file)
        let lib = CompareLibrary(projectsRoot: s.projects, runsRoot: s.runs)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: s.projects.path)
        #expect(throws: (any Error).self) {
            try lib.add("p.json", bundles: [b.lastPathComponent], baseline: b.lastPathComponent)
        }
        let p = try CompareProject.load(file)
        #expect(p.runs.count == 1 && p.baseline == 0)
    }

    @Test func detailRunsCarryTheirStartDate() throws {
        let s = setup()
        defer { try? FileManager.default.removeItem(at: s.root) }
        let a = try makeRun(in: s.runs, game: "hzd.exe", start: 1_800_000_000, runtime: "CrossOver")
        try CompareProject(name: "P", runs: [.init(bundle: a.lastPathComponent), .init(bundle: "gone.mptrun")])
            .save(to: s.projects.appendingPathComponent("p.json"))
        let d = try CompareLibrary(projectsRoot: s.projects, runsRoot: s.runs).detail("p.json")
        #expect(d.runs[0].start == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(d.runs[1].start == nil)
    }
}
