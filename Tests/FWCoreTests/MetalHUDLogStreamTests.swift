import Testing
@testable import FWCore

@Suite struct MetalHUDLogStreamTests {
    // 2026-11-24 12:25:00 UTC = 1795523100 (checked with `date -u -j`).
    @Test func decodesLogLine() throws {
        let json = #"{"processID":34546,"processImagePath":"\/x\/spin","timestamp":"2026-11-24 12:25:00.502304+0000","eventMessage":"metal-HUD: 63,5.77,446.17<private>"}"#
        let e = try #require(MetalHUDLogStream.decode(ndjsonLine: json))
        #expect(e.pid == 34546)
        #expect(e.imagePath == "/x/spin")
        #expect(e.line.frames == 63)
        #expect(abs(e.time - 1795523100.502) < 0.001)
    }

    @Test func skipsHeaderAndJunk() {
        #expect(MetalHUDLogStream.decode(ndjsonLine: #"Filtering the log data using "composedMessage BEGINSWITH "metal-HUD"""#) == nil)
        #expect(MetalHUDLogStream.decode(ndjsonLine: "") == nil)
        #expect(MetalHUDLogStream.decode(ndjsonLine: #"{"processID":1}"#) == nil)
        #expect(MetalHUDLogStream.decode(ndjsonLine: #"{"processID":1,"processImagePath":"/x","timestamp":"2026-11-24 12:25:00.502304+0000","eventMessage":"other"}"#) == nil)
    }
}
