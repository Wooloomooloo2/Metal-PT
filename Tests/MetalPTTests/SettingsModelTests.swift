import Carbon.HIToolbox
import Foundation
import Testing
@testable import MetalPT
@testable import MPTApp
@testable import MPTCore

/// The Settings page's model operations (T14), without AppKit: hotkey changes, the data folder, FPS-logging retry.
@MainActor
@Suite struct SettingsModelTests {
    private final class Launchctl: LaunchctlRunning, @unchecked Sendable {
        var env: [String: String] = [:]
        var failSet = false
        func getenv(_ name: String) -> String? { env[name] }
        func setenv(_ name: String, _ value: String) throws {
            if failSet { throw FPSLoggingError.commandFailed(operation: "setenv", name: name, status: 1) }
            env[name] = value
        }
        func unsetenv(_ name: String) throws { env[name] = nil }
    }

    private final class Made {
        let model: AppModel
        let defaults: UserDefaults
        let launchctl: Launchctl
        init(model: AppModel, defaults: UserDefaults, launchctl: Launchctl) {
            self.model = model; self.defaults = defaults; self.launchctl = launchctl
        }
    }

    private func make(env: [String: String] = [:]) -> Made {
        let defaults = MemoryDefaults()   // in memory: no plist in ~/Library/Preferences
        let launchctl = Launchctl()
        let model = AppModel(hub: TelemetryHub(dependencies: .inert), fpsLogging: FPSLogging(launchctl: launchctl),
                             live: true, usesAppKit: false, defaults: defaults, env: env)
        return Made(model: model, defaults: defaults, launchctl: launchctl)
    }

    @Test func hotkeyChangePersistsAndResets() {
        let m = make()
        let f8 = HotkeyCombo(keyCode: UInt32(kVK_F8), modifiers: UInt32(controlKey | optionKey))
        #expect(m.model.setHotkey(f8, for: .record) == nil)
        #expect(m.defaults.string(forKey: SettingsKey.hotkeyRecord) == "⌃⌥F8")
        #expect(m.model.recordCombo == f8)
        #expect(m.model.setHotkey(nil, for: .record) == nil)
        #expect(m.defaults.string(forKey: SettingsKey.hotkeyRecord) == nil)
        #expect(m.model.recordCombo == .record)
    }

    /// Refused: a bare letter, and the other action's combo. Nothing is saved.
    @Test func hotkeyRefusals() {
        let m = make()
        #expect(m.model.setHotkey(HotkeyCombo(keyCode: UInt32(kVK_ANSI_R), modifiers: 0), for: .record) != nil)
        #expect(m.model.setHotkey(.overlay, for: .record) == "⌃⇧F7 is already the Overlay hotkey")
        #expect(m.model.setHotkey(.record, for: .overlay) == "⌃⇧F6 is already the Record hotkey")
        #expect(m.defaults.string(forKey: SettingsKey.hotkeyRecord) == nil)
        #expect(m.defaults.string(forKey: SettingsKey.hotkeyOverlay) == nil)
        // Swapping works once the other has moved; then resetting into the other's default is refused.
        let f9 = HotkeyCombo(keyCode: UInt32(kVK_F9), modifiers: 0)
        #expect(m.model.setHotkey(f9, for: .overlay) == nil)
        #expect(m.model.setHotkey(.overlay, for: .record) == nil)
        #expect(m.model.setHotkey(nil, for: .overlay) == "⌃⇧F7 is already the Record hotkey")
        #expect(m.model.overlayCombo == f9)
    }

    @Test func dataFolderChangeAndReset() {
        let m = make()
        #expect(m.model.dataFolderEnvRoot == nil)
        #expect(m.model.dataFolderIsDefault)
        #expect(m.model.dataRoot.path.hasSuffix("/Documents/Metal-PT"))
        let custom = FileManager.default.temporaryDirectory.appendingPathComponent("mpt-settings-\(UUID().uuidString)")
        m.model.setDataFolder(custom)
        #expect(!m.model.dataFolderIsDefault)
        #expect(m.model.dataRoot.standardizedFileURL.path == custom.standardizedFileURL.path)
        #expect(m.model.folder("runs").standardizedFileURL.path
                == custom.appendingPathComponent("runs").standardizedFileURL.path)
        // The stores follow at once.
        #expect(m.model.runs.root?.standardizedFileURL.path == m.model.folder("runs").standardizedFileURL.path)
        #expect(m.model.projects.projectsRoot?.standardizedFileURL.path
                == m.model.folder("projects").standardizedFileURL.path)
        m.model.setDataFolder(nil)
        #expect(m.model.dataFolderIsDefault)
        #expect(m.model.dataRoot.path.hasSuffix("/Documents/Metal-PT"))
    }

    /// `$MPT_DATA_ROOT` wins over the Settings value, and Settings cannot change it.
    @Test func dataFolderLockedByEnv() {
        let m = make(env: ["MPT_DATA_ROOT": "/tmp/mpt-env-root"])
        #expect(m.model.dataFolderEnvRoot == "/tmp/mpt-env-root")
        #expect(m.model.dataRoot.path == "/tmp/mpt-env-root")
        m.model.setDataFolder(URL(fileURLWithPath: "/tmp/elsewhere"))
        #expect(m.defaults.string(forKey: SettingsKey.dataFolder) == nil)
        #expect(m.model.dataRoot.path == "/tmp/mpt-env-root")
    }

    /// "Try again" retries the saved choice, and clears the error once it works.
    @Test func retryFPSLogging() {
        let m = make()
        m.model.launch()
        m.launchctl.failSet = true
        m.model.setFPSLogging(true)
        #expect(m.model.fpsLoggingOn == false)
        #expect(m.model.fpsLoggingError != nil)
        m.launchctl.failSet = false
        m.model.retryFPSLogging()
        #expect(m.model.fpsLoggingOn)
        #expect(m.model.fpsLoggingError == nil)
        m.model.quit()
        #expect(m.launchctl.env.isEmpty)
    }
}
