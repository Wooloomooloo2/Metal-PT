import Carbon.HIToolbox
import Foundation
import Testing
@testable import MPTApp

/// Settings (T14): hotkey capture, conflict checks, the data folder shown in Settings.
@Suite struct SettingsSupportTests {
    // NSEvent.ModifierFlags raw bits (AppKit is not imported here).
    let shift: UInt = 1 << 17, control: UInt = 1 << 18, option: UInt = 1 << 19, command: UInt = 1 << 20
    let capsLock: UInt = 1 << 16, function: UInt = 1 << 23

    @Test func captureMapsCocoaModifiersToCarbon() {
        let c = HotkeyCapture.outcome(keyCode: UInt16(kVK_F8), cocoaFlags: control | shift | function)
        #expect(c == .combo(HotkeyCombo(keyCode: UInt32(kVK_F8), modifiers: UInt32(controlKey | shiftKey))))
        #expect(HotkeyCapture.outcome(keyCode: UInt16(kVK_ANSI_R), cocoaFlags: option | command | capsLock)
                == .combo(HotkeyCombo(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(optionKey | cmdKey))))
        if case .combo(let c) = HotkeyCapture.outcome(keyCode: UInt16(kVK_F8), cocoaFlags: control | shift) {
            #expect(c.display == "⌃⇧F8")
        } else {
            Issue.record("expected a combo")
        }
    }

    /// Esc cancels and Delete resets, but only bare; with a modifier they are ordinary combos.
    @Test func escapeCancelsDeleteResets() {
        #expect(HotkeyCapture.outcome(keyCode: UInt16(kVK_Escape), cocoaFlags: 0) == .cancel)
        #expect(HotkeyCapture.outcome(keyCode: UInt16(kVK_Escape), cocoaFlags: capsLock) == .cancel)
        #expect(HotkeyCapture.outcome(keyCode: UInt16(kVK_Delete), cocoaFlags: 0) == .reset)
        #expect(HotkeyCapture.outcome(keyCode: UInt16(kVK_ForwardDelete), cocoaFlags: function) == .reset)
        #expect(HotkeyCapture.outcome(keyCode: UInt16(kVK_Delete), cocoaFlags: control)
                == .combo(HotkeyCombo(keyCode: UInt32(kVK_Delete), modifiers: UInt32(controlKey))))
    }

    @Test func problemsRefuseBareKeysAndDuplicates() {
        let bareR = HotkeyCombo(keyCode: UInt32(kVK_ANSI_R), modifiers: 0)
        #expect(HotkeyCapture.problem(bareR, other: .overlay, otherName: "Overlay") != nil)
        #expect(HotkeyCapture.problem(.overlay, other: .overlay, otherName: "Overlay")
                == "⌃⇧F7 is already the Overlay hotkey")
        #expect(HotkeyCapture.problem(.record, other: .overlay, otherName: "Overlay") == nil)
        #expect(HotkeyCapture.problem(HotkeyCombo(keyCode: UInt32(kVK_F9), modifiers: 0), other: .overlay,
                                      otherName: "Overlay") == nil)
    }

    @Test func dataRootShownInSettings() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(AppFolders.root(setting: nil, env: [:]).path.hasSuffix("/Documents/Metal-PT"))
        #expect(AppFolders.root(setting: "  ", env: [:]).path.hasSuffix("/Documents/Metal-PT"))
        #expect(AppFolders.root(setting: "~/MPT ", env: [:]).path == "\(home)/MPT")
        #expect(AppFolders.root(setting: "/s/root", env: ["MPT_DATA_ROOT": "/tmp/envroot"]).path == "/tmp/envroot")
        #expect(AppFolders.root(setting: "/s/root", env: ["MPT_DATA_ROOT": " "]).path == "/s/root")
        #expect(AppFolders.envRoot(["MPT_DATA_ROOT": "/tmp/envroot"]) == "/tmp/envroot")
        #expect(AppFolders.envRoot(["MPT_DATA_ROOT": "  "]) == nil)
        #expect(AppFolders.envRoot([:]) == nil)
        // The root and the per-name folders agree.
        for env in [[:], ["MPT_DATA_ROOT": "/tmp/envroot"]] {
            for setting in [nil, "/s/root"] {
                #expect(AppFolders.url("runs", setting: setting, env: env).path
                        == AppFolders.root(setting: setting, env: env).appendingPathComponent("runs").path)
            }
        }
    }
}
