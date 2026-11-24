import Testing
@testable import FWCore

@Suite struct MetalHUDLineTests {
    @Test func parsesPublicLogLine() {
        let line = MetalHUDLine.parse("metal-HUD: 63,5.77,446.17<private>")
        #expect(line?.frames == 63)
        #expect(line?.a == 5.77)
        #expect(line?.b == 446.17)
        #expect(line?.frameTimes.isEmpty == true)
    }

    @Test func parsesFullStderrLine() {
        let line = MetalHUDLine.parse(
            "2026-11-24 12:24:13.635 spin[34283:27302095] metal-HUD: 75,10.61,468.19,51.11,0.01,8.34,0.01")
        #expect(line?.frames == 75)
        #expect(line?.frameTimes == [
            FrameTime(intervalMs: 51.11, presentDelayMs: 0.01),
            FrameTime(intervalMs: 8.34, presentDelayMs: 0.01),
        ])
    }

    @Test func rejectsOtherLines() {
        #expect(MetalHUDLine.parse("[libMTLHud] Metric x already exist") == nil)
        #expect(MetalHUDLine.parse("metal-HUD: abc") == nil)
    }

    @Test func oddTrailingValueIgnored() {
        let line = MetalHUDLine.parse("metal-HUD: 10,1.0,2.0,5.0,0.1,7.0")
        #expect(line?.frameTimes == [FrameTime(intervalMs: 5.0, presentDelayMs: 0.1)])
    }
}
