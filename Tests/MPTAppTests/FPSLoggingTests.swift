import Testing
import Foundation
import Carbon.HIToolbox
@testable import MPTApp

private final class FakeLaunchctl: LaunchctlRunning, @unchecked Sendable {
    var env: [String: String] = [:]
    var calls: [String] = []
    /// When true, unsetenv "succeeds" but the value stays (to test read-back).
    var stickyUnset = false
    func getenv(_ name: String) -> String? { env[name] }
    func setenv(_ name: String, _ value: String) throws { calls.append("set \(name)"); env[name] = value }
    func unsetenv(_ name: String) throws { calls.append("unset \(name)"); if !stickyUnset { env[name] = nil } }
}

private let both = ["MTL_HUD_ENABLED", "MTL_HUD_LOG_ENABLED"]

@Suite struct FPSLoggingTests {
    @Test func adoptsWhenEnabled() {
        let fake = FakeLaunchctl()
        for n in both { fake.env[n] = "1" }
        let fps = FPSLogging(launchctl: fake)
        fps.reconcileAtLaunch(enabled: true)
        #expect(fps.isOn)
        #expect(fake.calls.isEmpty)
    }

    @Test func partialWhenEnabledSetsBoth() {
        let fake = FakeLaunchctl()
        fake.env["MTL_HUD_ENABLED"] = "1"
        let fps = FPSLogging(launchctl: fake)
        fps.reconcileAtLaunch(enabled: true)
        #expect(fps.isOn)
        for n in both { #expect(fake.env[n] == "1") }
    }

    @Test func unsetEnabledSetsBoth() {
        let fake = FakeLaunchctl()
        let fps = FPSLogging(launchctl: fake)
        fps.reconcileAtLaunch(enabled: true)
        #expect(fps.isOn)
        for n in both { #expect(fake.env[n] == "1") }
    }

    @Test func unsetsStaleWhenDisabled() {
        let fake = FakeLaunchctl()
        for n in both { fake.env[n] = "1" }
        let fps = FPSLogging(launchctl: fake)
        fps.reconcileAtLaunch(enabled: false)
        #expect(!fps.isOn)
        for n in both { #expect(fake.env[n] == nil) }
    }

    @Test func partialWhenDisabledUnsetsBoth() {
        let fake = FakeLaunchctl()
        fake.env["MTL_HUD_LOG_ENABLED"] = "1"
        let fps = FPSLogging(launchctl: fake)
        fps.reconcileAtLaunch(enabled: false)
        #expect(!fps.isOn)
        for n in both { #expect(fake.env[n] == nil) }
    }

    @Test func disabledAndCleanTouchesNothing() {
        let fake = FakeLaunchctl()
        let fps = FPSLogging(launchctl: fake)
        fps.reconcileAtLaunch(enabled: false)
        #expect(!fps.isOn)
        #expect(fake.calls.isEmpty)
    }

    @Test func setEnabledSetsBoth() throws {
        let fake = FakeLaunchctl()
        let fps = FPSLogging(launchctl: fake)
        try fps.setEnabled(true)
        #expect(fps.isOn)
        for n in both { #expect(fake.env[n] == "1") }
        try fps.setEnabled(false)
        #expect(!fps.isOn)
        for n in both { #expect(fake.env[n] == nil) }
    }

    @Test func turnOffReadsBack() {
        let fake = FakeLaunchctl()
        let fps = FPSLogging(launchctl: fake)
        try? fps.setEnabled(true)
        fake.stickyUnset = true
        #expect(throws: FPSLoggingError.self) { try fps.setEnabled(false) }
    }

    @Test func releaseAtQuitUnsets() {
        let fake = FakeLaunchctl()
        let fps = FPSLogging(launchctl: fake)
        try? fps.setEnabled(true)
        fps.releaseAtQuit()
        #expect(!fps.isOn)
        for n in both { #expect(fake.env[n] == nil) }
    }

    @Test func releaseAtQuitUnsetsEvenIfWeNeverTookIt() {
        let fake = FakeLaunchctl()
        for n in both { fake.env[n] = "1" }
        FPSLogging(launchctl: fake).releaseAtQuit()
        for n in both { #expect(fake.env[n] == nil) }
    }
}

@Suite struct HotkeyTests {
    @Test func defaults() {
        #expect(HotkeyCombo.record.keyCode == UInt32(kVK_F6))
        #expect(HotkeyCombo.record.modifiers == UInt32(controlKey | shiftKey))
        #expect(HotkeyCombo.overlay.display == "⌃⇧F7")
        #expect(HotkeyCombo.record.display == "⌃⇧F6")
    }

    @Test func hotkeyDisplayRoundTrip() {
        let p = HotkeyCombo(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(optionKey | cmdKey))
        #expect(p.display == "⌥⌘P")
        for c in [HotkeyCombo.record, .overlay, p,
                  HotkeyCombo(keyCode: UInt32(kVK_ANSI_7), modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey)),
                  HotkeyCombo(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey)),
                  HotkeyCombo(keyCode: UInt32(kVK_F20), modifiers: 0)] {
            #expect(HotkeyCombo(display: c.display) == c)
        }
        #expect(HotkeyCombo(display: "⌃⇧F6") == .record)
        #expect(HotkeyCombo(display: "nonsense") == nil)
        #expect(HotkeyCombo(display: "⌘") == nil)
    }

    @Test func codableRoundTrip() throws {
        let data = try JSONEncoder().encode(HotkeyCombo.record)
        #expect(try JSONDecoder().decode(HotkeyCombo.self, from: data) == .record)
    }
}
