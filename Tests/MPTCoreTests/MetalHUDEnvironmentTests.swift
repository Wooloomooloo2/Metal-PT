import Testing
@testable import MPTCore

@Suite struct MetalHUDEnvironmentTests {
    @Test func hiddenByDefaultAddsOpacityZero() {
        #expect(MetalHUDEnvironment.values(showHUD: false)
                == ["MTL_HUD_ENABLED": "1", "MTL_HUD_LOG_ENABLED": "1", "MTL_HUD_OPACITY": "0"])
        #expect(RecordingSession.Options(runsRoot: .init(fileURLWithPath: "/tmp"), appVersion: "x").showHUD == false)
    }

    @Test func shownLeavesOpacityOut() {
        #expect(MetalHUDEnvironment.values(showHUD: true) == ["MTL_HUD_ENABLED": "1", "MTL_HUD_LOG_ENABLED": "1"])
        #expect(RecordingSession.hudEnvironment(showHUD: true) == MetalHUDEnvironment.values(showHUD: true))
    }

    @Test func allCoversEveryVariableEitherWaySets() {
        for show in [false, true] {
            #expect(Set(MetalHUDEnvironment.values(showHUD: show).keys).isSubset(of: Set(MetalHUDEnvironment.all)))
        }
        #expect(MetalHUDEnvironment.required == ["MTL_HUD_ENABLED", "MTL_HUD_LOG_ENABLED"])
    }
}
