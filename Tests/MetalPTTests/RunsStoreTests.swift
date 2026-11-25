import Foundation
import Testing
@testable import MetalPT
@testable import MPTApp
import MPTCore

@MainActor
@Suite struct RunsStoreTests {
    @Test func updateAndDeleteThrowWithoutAnIndex() async {
        let store = RunsStore()
        await #expect(throws: (any Error).self) { try await store.update("x.mptrun", settings: "", notes: "", label: "") }
        await #expect(throws: (any Error).self) { try await store.delete("x.mptrun") }
    }

    @Test func recordingRunIsLockedUntilFinished() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mpt-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let dir = RunBundle.availableDirectory(in: root, start: start, game: "run")
        let info = RunInfo(appVersion: "0.2", machine: .init(modelID: "Mac15,6", chip: "Apple M3 Pro", memoryGB: 36,
                                                             osVersion: "15.1", osBuild: "24B83"),
                           game: .init(exe: "g.exe"), start: start)
        let w = try RunBundleWriter(directory: dir, info: info)
        // Old samples.csv: only the hub's recording directory marks it as in progress.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)],
                                              ofItemAtPath: dir.appendingPathComponent("samples.csv").path)
        let store = RunsStore()
        store.recordingDirectory = dir
        store.showFixture(root: root)
        let id = dir.lastPathComponent
        #expect(store.entry(id)?.inProgress == true)
        await #expect(throws: RunIndexError.self) { try await store.update(id, settings: "a", notes: "", label: "") }
        await #expect(throws: RunIndexError.self) { try await store.delete(id) }
        if case .success = await store.summaryURL(id) { Issue.record("summary generated for a recording run") }

        try w.finish { $0.end = start.addingTimeInterval(10) }
        store.recordingDirectory = nil
        store.showFixture(root: root)
        #expect(store.entry(id)?.inProgress == false)
        try await store.update(id, settings: "a", notes: "", label: "")
        #expect(store.entry(id)?.settings == "a")
    }
}

@Suite struct RunFormatStatTests {
    @Test func statSuffixOmitsMissingParts() {
        #expect(RunFormat.statSuffix(low1: 48, fpsPerWatt: 1.5) == " fps \u{00B7} 1% 48 \u{00B7} 1.50\u{00A0}FPS/W")
        #expect(RunFormat.statSuffix(low1: nil, fpsPerWatt: 1.5) == " fps \u{00B7} 1.50\u{00A0}FPS/W")
        #expect(RunFormat.statSuffix(low1: 48, fpsPerWatt: nil) == " fps \u{00B7} 1% 48")
        #expect(RunFormat.statSuffix(low1: nil, fpsPerWatt: nil) == " fps")
    }
}

@Suite struct ShortDateTests {
    private func cal() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_GB")
        return c
    }
    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 9, _ min: Int = 50) -> Date {
        cal().date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    @Test func todayThisYearAndEarlierYears() {
        let now = at(2026, 11, 25, 15, 0)
        #expect(RunFormat.shortDate(at(2026, 11, 25), now: now, calendar: cal()) == "Today 09:50")
        #expect(RunFormat.shortDate(at(2026, 8, 12), now: now, calendar: cal()) == "12 Aug")
        #expect(RunFormat.shortDate(at(2025, 8, 12), now: now, calendar: cal()) == "12 Aug 2025")
    }

    @Test func yearBoundary() {
        let now = at(2026, 1, 1, 8, 0)
        #expect(RunFormat.shortDate(at(2025, 12, 31, 23, 59), now: now, calendar: cal()) == "31 Dec 2025")
        #expect(RunFormat.shortDate(at(2026, 1, 1, 0, 5), now: now, calendar: cal()) == "Today 00:05")
        #expect(RunFormat.shortDate(at(2026, 1, 1, 9, 0), now: at(2026, 1, 2), calendar: cal()) == "1 Jan")
    }
}

@Suite struct AddRunsSelectionTests {
    private func entry(_ id: String, game: String, label: String = "") -> RunEntry {
        RunEntry(id: id, game: game, stackLine: "", settings: "", label: label,
                 start: Date(timeIntervalSince1970: 0), duration: 60, medianFPS: 60, low1: 50)
    }

    @Test func tickedRunsHiddenBySearchStayTickedAndAreAdded() {
        let a = entry("a", game: "hzd"), b = entry("b", game: "hzd", label: "new driver")
        let scope = [a, b]
        #expect(AddRunsSelection.visible(scope, filter: "driver").map(\.id) == ["b"])
        #expect(AddRunsSelection.visible(scope, filter: "  ").map(\.id) == ["a", "b"])
        // "a" is hidden by the search but still ticked: kept, and added.
        let kept = AddRunsSelection.keep(["a", "b"], in: scope)
        #expect(kept == ["a", "b"])
        #expect(AddRunsSelection.ids(scope, ticked: kept, extra: nil) == ["a", "b"])
    }

    @Test func rowBaselineAddsThatRunEvenFromAnotherGame() {
        let a = entry("a", game: "hzd"), c = entry("c", game: "re9")
        let ids = AddRunsSelection.ids([a, c], ticked: ["a"], extra: "c")
        #expect(ids == ["a", "c"])
    }

    @Test func idsAreOldestFirst() {
        var old = entry("old", game: "hzd"); old.start = Date(timeIntervalSince1970: 100)
        var new = entry("new", game: "hzd"); new.start = Date(timeIntervalSince1970: 200)
        #expect(AddRunsSelection.ids([new, old], ticked: ["new", "old"], extra: nil) == ["old", "new"])
    }

    @Test func checkboxOnlyWithExactlyOneTicked() {
        #expect(AddRunsSelection.canChooseBaseline(ticked: ["a"]))
        #expect(!AddRunsSelection.canChooseBaseline(ticked: []))
        #expect(!AddRunsSelection.canChooseBaseline(ticked: ["a", "b"]))
    }
}
