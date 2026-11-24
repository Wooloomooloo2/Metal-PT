import Testing
import Foundation
@testable import MPTCore

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

    @Test func splitsChunksIntoLines() {
        var buffer = Data()
        // A line split across chunks, then several lines in one chunk, then a trailing partial line.
        #expect(MetalHUDLogStream.splitLines(&buffer, appending: Data("ab".utf8)).isEmpty)
        let first = MetalHUDLogStream.splitLines(&buffer, appending: Data("c\nd\n\ne\nf".utf8))
        #expect(first.map { String(decoding: $0, as: UTF8.self) } == ["abc", "d", "", "e"])
        #expect(buffer == Data("f".utf8))
        let second = MetalHUDLogStream.splitLines(&buffer, appending: Data("g\n".utf8))
        #expect(second.map { String(decoding: $0, as: UTF8.self) } == ["fg"])
        #expect(buffer.isEmpty)
    }

    @Test func skipsHeaderAndJunk() {
        #expect(MetalHUDLogStream.decode(ndjsonLine: #"Filtering the log data using "composedMessage BEGINSWITH "metal-HUD"""#) == nil)
        #expect(MetalHUDLogStream.decode(ndjsonLine: "") == nil)
        #expect(MetalHUDLogStream.decode(ndjsonLine: #"{"processID":1}"#) == nil)
        #expect(MetalHUDLogStream.decode(ndjsonLine: #"{"processID":1,"processImagePath":"/x","timestamp":"2026-11-24 12:25:00.502304+0000","eventMessage":"other"}"#) == nil)
    }

    // A signal can stop the session before its log stream has started; the late start must not spawn `log`.
    @Test func startAfterStopDoesNothing() throws {
        let stream = MetalHUDLogStream { _ in }
        stream.stop()
        try stream.start()
        let running = stream.isRunning
        stream.stop()   // clean up if the start did spawn
        #expect(!running)
    }
}
