import Testing
import Foundation
import Carbon.HIToolbox
@testable import MPTApp

private final class FakeLaunchctl: LaunchctlRunning, @unchecked Sendable {
    var env: [String: String] = [:]
    var calls: [String] = []
    /// When true, unsetenv "succeeds" but the value stays (to test read-back).
    var stickyUnset = false
    /// Variable names whose setenv throws.
    var failSet: Set<String> = []
    func getenv(_ name: String) -> String? { env[name] }
    func setenv(_ name: String, _ value: String) throws {
        calls.append("set \(name)")
        if failSet.contains(name) { throw FPSLoggingError.commandFailed(operation: "setenv", name: name, status: 1) }
        env[name] = value
    }
    func unsetenv(_ name: String) throws { calls.append("unset \(name)"); if !stickyUnset { env[name] = nil } }
}

private let both = ["MTL_HUD_ENABLED", "MTL_HUD_LOG_ENABLED"]
private let opacity = "MTL_HUD_OPACITY"
private let all = both + [opacity]

@Suite struct FPSLoggingTests {
    @Test func adoptsWhenEnabled() {
        let fake = FakeLaunchctl()
        for n in both { fake.env[n] = "1" }
        fake.env[opacity] = "0"
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

    @Test func enabledWithNothingSetSetsBoth() {
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
        #expect(throws: FPSLoggingError.stillSet(all)) { try fps.setEnabled(false) }
        #expect(fps.isOn)   // reflects reality: the variables are still set
    }

    @Test func releaseAtQuitFailureSetsLastError() {
        let fake = FakeLaunchctl()
        let fps = FPSLogging(launchctl: fake)
        try? fps.setEnabled(true)
        fake.stickyUnset = true
        fps.releaseAtQuit()
        #expect(fps.lastError == .stillSet(all))
        #expect(fps.isOn)
        fake.stickyUnset = false
        fps.releaseAtQuit()
        #expect(fps.lastError == nil)
    }

    @Test func reconcileFailureSetsLastError() {
        let fake = FakeLaunchctl()
        for n in both { fake.env[n] = "1" }
        fake.stickyUnset = true
        let fps = FPSLogging(launchctl: fake)
        fps.reconcileAtLaunch(enabled: false)
        #expect(fps.lastError != nil)
        #expect(fps.isOn)
    }

    @Test func enableIsAtomic() {
        let fake = FakeLaunchctl()
        fake.failSet = ["MTL_HUD_LOG_ENABLED"]
        let fps = FPSLogging(launchctl: fake)
        #expect(throws: FPSLoggingError.self) { try fps.setEnabled(true) }
        #expect(!fps.isOn)
        for n in both { #expect(fake.env[n] == nil) }
        #expect(fps.lastError != nil)
    }

    @Test func releaseAtQuitUnsets() {
        let fake = FakeLaunchctl()
        let fps = FPSLogging(launchctl: fake)
        try? fps.setEnabled(true)
        fps.releaseAtQuit()
        #expect(!fps.isOn)
        for n in both { #expect(fake.env[n] == nil) }
    }

    // MARK: Apple's HUD hidden (MTL_HUD_OPACITY=0) unless shown

    @Test func enableHidesHUDByDefault() throws {
        let fake = FakeLaunchctl()
        let fps = FPSLogging(launchctl: fake)
        try fps.setEnabled(true)
        for n in both { #expect(fake.env[n] == "1") }
        #expect(fake.env[opacity] == "0")
        #expect(!fps.showsHUD)
        try fps.setEnabled(false)
        for n in all { #expect(fake.env[n] == nil) }
    }

    @Test func enableWithShowHUDLeavesOpacityUnsetAndClearsAStaleOne() throws {
        let fake = FakeLaunchctl()
        fake.env[opacity] = "0"
        let fps = FPSLogging(launchctl: fake)
        try fps.setEnabled(true, showHUD: true)
        for n in both { #expect(fake.env[n] == "1") }
        #expect(fake.env[opacity] == nil)
        #expect(fps.showsHUD)
    }

    @Test func setShowHUDWhileOnChangesOpacityAtOnce() throws {
        let fake = FakeLaunchctl()
        let fps = FPSLogging(launchctl: fake)
        try fps.setEnabled(true)
        try fps.setShowHUD(true)
        #expect(fake.env[opacity] == nil)
        #expect(fps.isOn)
        try fps.setShowHUD(false)
        #expect(fake.env[opacity] == "0")
        for n in both { #expect(fake.env[n] == "1") }
    }

    @Test func setShowHUDWhileOffOnlyRemembers() throws {
        let fake = FakeLaunchctl()
        let fps = FPSLogging(launchctl: fake)
        try fps.setShowHUD(true)
        #expect(fake.calls.isEmpty)
        #expect(fps.showsHUD)
        #expect(!fps.isOn)
    }

    @Test func reconcileFixesOpacityToTheSetting() {
        let fake = FakeLaunchctl()
        for n in both { fake.env[n] = "1" }
        let fps = FPSLogging(launchctl: fake)
        fps.reconcileAtLaunch(enabled: true)            // hidden wanted, opacity missing
        #expect(fake.env[opacity] == "0")
        #expect(fps.isOn)
        let fps2 = FPSLogging(launchctl: fake)
        fps2.reconcileAtLaunch(enabled: true, showHUD: true)   // shown wanted, opacity 0 left over
        #expect(fake.env[opacity] == nil)
        #expect(fps2.isOn)
    }

    @Test func reconcileDisabledUnsetsALeftoverOpacity() {
        let fake = FakeLaunchctl()
        fake.env[opacity] = "0"
        let fps = FPSLogging(launchctl: fake)
        fps.reconcileAtLaunch(enabled: false)
        #expect(fake.env[opacity] == nil)
        #expect(!fps.isOn)
    }

    @Test func opacityFailureRollsBackEverything() {
        let fake = FakeLaunchctl()
        fake.failSet = [opacity]
        let fps = FPSLogging(launchctl: fake)
        #expect(throws: FPSLoggingError.self) { try fps.setEnabled(true) }
        #expect(!fps.isOn)
        for n in all { #expect(fake.env[n] == nil) }
    }

    @Test func releaseAtQuitUnsetsEvenIfWeNeverTookIt() {
        let fake = FakeLaunchctl()
        for n in both { fake.env[n] = "1" }
        fake.env[opacity] = "0"
        FPSLogging(launchctl: fake).releaseAtQuit()
        for n in all { #expect(fake.env[n] == nil) }
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

    @Test func modifiersAreMasked() {
        let capsLock = UInt32(alphaLock)
        let c = HotkeyCombo(keyCode: UInt32(kVK_F6), modifiers: UInt32(controlKey) | capsLock)
        #expect(c.modifiers == UInt32(controlKey))
    }

    @Test func codableRoundTrip() throws {
        let data = try JSONEncoder().encode(HotkeyCombo.record)
        #expect(try JSONDecoder().decode(HotkeyCombo.self, from: data) == .record)
    }
}
