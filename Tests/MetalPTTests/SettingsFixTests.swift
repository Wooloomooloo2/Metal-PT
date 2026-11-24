import AppKit
import Foundation
import Testing
@testable import MetalPT
@testable import MPTApp
import MPTCore

/// Review fix round 1 (T14): the hotkey recorder always hands the keyboard and the global hotkeys back; rename aliases
/// never hide a real project; the data folder cannot change during a recording.
@MainActor
@Suite struct HotkeyRecorderTests {
    private final class FakeMonitors: KeyEventMonitoring {
        var keyHandler: ((UInt16, UInt) -> Void)?
        var mouseHandler: (() -> Void)?
        var installed = 0
        var removed = 0
        func addMonitors(onKey: @escaping (UInt16, UInt) -> Void, onMouseDown: @escaping () -> Void) -> AnyObject {
            keyHandler = onKey
            mouseHandler = onMouseDown
            installed += 1
            return NSObject()
        }
        func removeMonitors(_ token: AnyObject) {
            removed += 1
            keyHandler = nil
            mouseHandler = nil
        }
        var active: Bool { installed > removed }
    }

    private final class FakeHotkeys: HotkeySuspending {
        var suspended = 0
        var resumed = 0
        func suspendHotkeys() { suspended += 1 }
        func resumeHotkeys() { resumed += 1 }
    }

    private func make() -> (HotkeyRecorder, FakeMonitors, FakeHotkeys, NotificationCenter) {
        let monitors = FakeMonitors()
        let center = NotificationCenter()
        return (HotkeyRecorder(monitors: monitors, center: center), monitors, FakeHotkeys(), center)
    }

    @Test func resignActiveStopsAndResumes() {
        let (rec, monitors, keys, center) = make()
        var outcomes: [HotkeyCapture.Outcome] = []
        rec.start(.record, hotkeys: keys) { outcomes.append($0) }
        #expect(rec.recording == .record)
        #expect(monitors.active)
        #expect(keys.suspended == 1 && keys.resumed == 0)
        center.post(name: NSApplication.didResignActiveNotification, object: nil)
        #expect(rec.recording == nil)
        #expect(!monitors.active)
        #expect(keys.resumed == 1)
        #expect(outcomes.isEmpty)
        rec.stop()   // idempotent
        #expect(keys.resumed == 1)
        #expect(monitors.removed == 1)
    }

    @Test func windowResignKeyAndClickAwayStop() {
        let (rec, monitors, keys, center) = make()
        rec.start(.overlay, hotkeys: keys) { _ in }
        center.post(name: NSWindow.didResignKeyNotification, object: nil)
        #expect(rec.recording == nil && !monitors.active && keys.resumed == 1)
        rec.start(.overlay, hotkeys: keys) { _ in }
        monitors.mouseHandler?()
        #expect(rec.recording == nil && !monitors.active && keys.resumed == 2)
        // The click that stopped it was on the field itself: the field's action must not restart recording.
        #expect(rec.consumeClickStop(.overlay))
        #expect(!rec.consumeClickStop(.overlay))
    }

    /// A key ends recording: monitor removed and hotkeys back before the outcome is applied.
    @Test func keyEndsRecordingThenReportsOutcome() {
        let (rec, monitors, keys, _) = make()
        var seen: [(HotkeyCapture.Outcome, Int)] = []
        rec.start(.record, hotkeys: keys) { seen.append(($0, keys.resumed)) }
        monitors.keyHandler?(53, 0)   // Esc
        #expect(seen.count == 1)
        #expect(seen.first?.0 == .cancel)
        #expect(seen.first?.1 == 1)
        #expect(!monitors.active && rec.recording == nil)
    }

    /// Switching fields keeps one monitor and one suspension.
    @Test func switchingFieldsAndDeinit() {
        let monitors = FakeMonitors()
        let keys = FakeHotkeys()
        var rec: HotkeyRecorder? = HotkeyRecorder(monitors: monitors, center: NotificationCenter())
        rec?.start(.record, hotkeys: keys) { _ in }
        rec?.start(.overlay, hotkeys: keys) { _ in }
        #expect(keys.suspended == 1)
        #expect(monitors.installed - monitors.removed == 1)
        #expect(rec?.recording == .overlay)
        rec = nil
        #expect(!monitors.active)
        #expect(keys.resumed == 1)
    }
}

@MainActor
@Suite struct ProjectsAliasTests {
    @Test func exactIDWinsOverRenameAlias() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mpt-alias-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = root.appendingPathComponent("projects")
        let runs = root.appendingPathComponent("runs")
        try FileManager.default.createDirectory(at: runs, withIntermediateDirectories: true)
        let old = CompareProject(name: "Runs comparison", baseline: 0, runs: [.init(bundle: "gone.mptrun")])
        try old.save(to: projects.appendingPathComponent(CompareProject.fileName(for: old.name)))
        let store = ProjectsStore()
        store.showFixture(projectsRoot: projects, runsRoot: runs)
        let newID = try await store.rename("runs-comparison.json", to: "HZD stacks")
        #expect(newID == "hzd-stacks.json")
        #expect(store.project("runs-comparison.json")?.id == "hzd-stacks.json")   // alias while catching up
        // A new project takes the old name.
        let fresh = CompareProject(name: "Runs comparison", baseline: 0, runs: [.init(bundle: "other.mptrun")])
        try fresh.save(to: projects.appendingPathComponent("runs-comparison.json"))
        #expect(store.project("runs-comparison.json")?.id == "hzd-stacks.json")   // not listed yet
        store.showFixture(projectsRoot: projects, runsRoot: runs)
        #expect(store.project("runs-comparison.json")?.id == "runs-comparison.json")
        #expect(store.currentID("runs-comparison.json") == "runs-comparison.json")
        #expect(store.project("hzd-stacks.json")?.name == "HZD stacks")
    }

    @Test func deletePrunesAliases() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mpt-alias-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = root.appendingPathComponent("projects")
        let runs = root.appendingPathComponent("runs")
        try FileManager.default.createDirectory(at: runs, withIntermediateDirectories: true)
        let p = CompareProject(name: "A", baseline: 0, runs: [.init(bundle: "gone.mptrun")])
        try p.save(to: projects.appendingPathComponent(CompareProject.fileName(for: p.name)))
        let store = ProjectsStore()
        store.showFixture(projectsRoot: projects, runsRoot: runs)
        let id = try #require(store.projects.first?.id)
        let newID = try await store.rename(id, to: "B")
        try await store.delete(newID)
        #expect(store.currentID(id) == id)
        #expect(store.project(id) == nil)
    }
}

@MainActor
@Suite struct DataFolderDuringRecordingTests {
    private struct NoLaunchctl: LaunchctlRunning {
        func getenv(_ name: String) -> String? { nil }
        func setenv(_ name: String, _ value: String) throws {}
        func unsetenv(_ name: String) throws {}
    }

    @Test func refusedWhileRecording() {
        let defaults = MemoryDefaults()
        let model = AppModel(hub: TelemetryHub(dependencies: .inert), fpsLogging: FPSLogging(launchctl: NoLaunchctl()),
                             live: true, usesAppKit: false, defaults: defaults, env: [:])
        model.showFixture(recordState: .recording, fpsLoggingOn: false, recentRuns: [])
        #expect(model.setDataFolder(URL(fileURLWithPath: "/tmp/x")) != nil)
        #expect(model.dataFolderIsDefault)
        model.showFixture(recordState: .saving, fpsLoggingOn: false, recentRuns: [])
        #expect(model.setDataFolder(URL(fileURLWithPath: "/tmp/x")) != nil)
        model.showFixture(recordState: .idle, fpsLoggingOn: false, recentRuns: [])
        #expect(model.setDataFolder(URL(fileURLWithPath: "/tmp/x")) == nil)
        #expect(!model.dataFolderIsDefault)
    }
}
