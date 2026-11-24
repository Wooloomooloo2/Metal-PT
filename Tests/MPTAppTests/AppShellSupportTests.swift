import Testing
import Foundation
import Carbon.HIToolbox
import MPTCore
@testable import MPTApp

@Suite struct AppShellSupportTests {
    @Test func bareLetterRefusedFunctionKeyAllowed() {
        #expect(HotkeyCombo(keyCode: UInt32(kVK_ANSI_R), modifiers: 0).registrationProblem != nil)
        #expect(HotkeyCombo(keyCode: UInt32(kVK_F6), modifiers: 0).registrationProblem == nil)
        #expect(HotkeyCombo(keyCode: UInt32(kVK_F20), modifiers: 0).registrationProblem == nil)
        #expect(HotkeyCombo.record.registrationProblem == nil)
        #expect(HotkeyCombo(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(cmdKey)).registrationProblem == nil)
    }

    @Test func decodedExtraModifierBitsDoNotCount() throws {
        // A stored combo with only caps lock set is still "no modifier".
        let json = #"{"keyCode":\#(kVK_ANSI_R),"modifiers":\#(alphaLock)}"#
        let c = try JSONDecoder().decode(HotkeyCombo.self, from: Data(json.utf8))
        #expect(c.registrationProblem != nil)
    }

    @Test func dataRootOrder() {
        let env = ["MPT_DATA_ROOT": "/tmp/envroot"]
        #expect(AppFolders.url("runs", setting: "/s/root", env: env).path == "/tmp/envroot/runs")
        #expect(AppFolders.url("runs", setting: "/s/root", env: [:]).path == "/s/root/runs")
        #expect(AppFolders.url("runs", setting: "  ", env: [:]).path.hasSuffix("/Documents/Metal-PT/runs"))
        #expect(AppFolders.url("exports", setting: nil, env: ["MPT_DATA_ROOT": " "]).path
            .hasSuffix("/Documents/Metal-PT/exports"))
    }

    /// The Settings value is trimmed and tilde-expanded.
    @Test func dataFolderSettingExpandsTilde() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(AppFolders.url("runs", setting: "~/MPT", env: [:]).path == "\(home)/MPT/runs")
        #expect(AppFolders.url("runs", setting: " ~/MPT \n", env: [:]).path == "\(home)/MPT/runs")
    }

    @MainActor @Test func fixtureFeedsHub() {
        let hub = TelemetryHub(dependencies: .inert)
        let snaps = (0..<400).map {
            HubSnapshot(time: Double($0), sample: TelemetrySample(), fps: 60, followedPID: 7, followedApp: "Game",
                        stack: nil)
        }
        hub.showFixture(history: snaps)
        #expect(hub.history.count == TelemetryHub.historyLimit)
        #expect(hub.latest?.time == 399)
        #expect(hub.recording == nil)
    }
}

