import Testing
@testable import MPTCore

@Suite struct FrameCounterTests {
    private func event(_ pid: Int32, _ t: Double, _ frames: Int) -> HUDEvent {
        HUDEvent(pid: pid, imagePath: "/game\(pid)", time: t,
                 line: MetalHUDLine(frames: frames, a: 0, b: 0, frameTimes: []))
    }

    @Test func fpsFromCumulativeCounts() throws {
        var c = FrameCounter()
        c.add(event(7, 0.0, 63))
        #expect(c.fps(pid: 7, at: 0.5) == nil)
        c.add(event(7, 1.016, 124))
        let fps = try #require(c.fps(pid: 7, at: 1.5))
        #expect(abs(fps - 61 / 1.016) < 0.001)
    }

    @Test func staleIsNil() {
        var c = FrameCounter()
        c.add(event(7, 0.0, 63))
        c.add(event(7, 1.0, 123))
        #expect(c.fps(pid: 7, at: 3.5) != nil)
        #expect(c.fps(pid: 7, at: 3.6) == nil)
        #expect(c.fps(pid: 99, at: 1.0) == nil)
    }

    @Test func counterResetStartsOver() throws {
        var c = FrameCounter()
        c.add(event(7, 0, 500))
        c.add(event(7, 1, 560))
        c.add(event(7, 2, 30))
        #expect(c.fps(pid: 7, at: 2.0) == nil)
        c.add(event(7, 3, 90))
        #expect(try #require(c.fps(pid: 7, at: 3.0)) == 60)
    }

    @Test func followsBusiestProcess() {
        var c = FrameCounter()
        c.add(event(1, 0, 0)); c.add(event(2, 0, 0))
        c.add(event(1, 1, 100)); c.add(event(2, 1, 5000))
        #expect(c.followedPID == 2)
        #expect(c.totalFrames(pid: 2) == 5000)
        c.add(event(1, 2, 200))
        #expect(c.followedPID == 2)
        c.add(event(1, 3, 6000))
        #expect(c.followedPID == 1)
    }

    @Test func ignoresNegativeFramesAndNonMonotonicTime() throws {
        var c = FrameCounter()
        c.add(event(7, 1, 100))
        c.add(event(7, 2, 160))
        c.add(event(7, 3, -5))        // ignored
        c.add(event(7, 2, 220))       // same time: ignored
        c.add(event(7, 1.5, 220))     // earlier time: ignored
        #expect(c.totalFrames(pid: 7) == 60)
        let fps = try #require(c.fps(pid: 7, at: 2.0))
        #expect(fps == 60 && fps.isFinite)
        c.add(event(8, 1, -1))
        #expect(c.followedPID == 7)
        #expect(c.fps(pid: 8, at: 1) == nil)
    }

    // The unified log can carry each HUD line twice (empty subsystem, then com.apple.metal.hud), ~0.1 ms apart.
    @Test func duplicateLogEntryIsIgnored() throws {
        var c = FrameCounter()
        c.add(event(7, 0.0, 60))
        c.add(event(7, 0.0001, 60))
        c.add(event(7, 1.016, 121))
        c.add(event(7, 1.0161, 121))
        let fps = try #require(c.fps(pid: 7, at: 1.5))
        #expect(abs(fps - 61 / 1.016) < 0.001)
        // A paused game repeats its count a second later: that is a real 0 fps.
        c.add(event(7, 2.03, 121))
        #expect(c.fps(pid: 7, at: 2.1) == 0)
    }

    // A game restart or launcher hand-off: the old process stops sending lines; the busiest live one takes over
    // even though the old one has far more frames in total.
    @Test func followedProcessExitsNewOneTakesOver() throws {
        var c = FrameCounter()
        for t in 0...10 { c.add(event(1, Double(t), t * 600)) }     // 600 fps, 6000 frames, then gone
        #expect(c.followedPID == 1)
        c.add(event(3, 11, 0)); c.add(event(3, 12, 5))               // a quiet launcher window
        c.add(event(2, 12, 0))
        c.add(event(2, 13, 60))
        c.add(event(3, 13, 10))
        #expect(c.followedPID == 2)
        #expect(try #require(c.fps(pid: 2, at: 13.5)) == 60)
        // Within staleAfter the old process still counts as live and keeps the lead.
        var d = FrameCounter()
        for t in 0...10 { d.add(event(1, Double(t), t * 600)) }
        d.add(event(2, 11, 0)); d.add(event(2, 12, 60))
        #expect(d.followedPID == 1)
    }
}
