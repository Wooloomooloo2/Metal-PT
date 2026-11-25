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
