import Foundation
import Testing
@testable import MPTCore

private final class Box<T: Sendable>: @unchecked Sendable {
    private let l = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T { get { l.withLock { v } } set { l.withLock { v = newValue } } }
}

private func line(_ pid: Int32, _ frames: Int, _ t: Double) -> HUDEvent {
    HUDEvent(pid: pid, imagePath: "/x", time: t, line: MetalHUDLine(frames: frames, a: 0, b: 0, frameTimes: []))
}

/// Per-PID state can be dropped (a quiet PID may be reused by another process).
@Suite struct PIDReuseTests {
    @Test func frameCounterForgetsAPID() {
        var c = FrameCounter()
        c.add(line(1, 0, 0)); c.add(line(1, 60, 1))
        c.add(line(2, 0, 0)); c.add(line(2, 10, 1))
        #expect(c.followedPID == 1)
        #expect(c.lastTime(pid: 1) == 1)
        c.forget(pid: 1)
        #expect(c.lastTime(pid: 1) == nil)
        #expect(c.totalFrames(pid: 1) == 0)
        #expect(c.followedPID == 2)
        #expect(Set(c.pids) == [2])
        c.forget(pid: 2)
        #expect(c.followedPID == nil)
    }

    @Test func stackCacheForgetsAPID() async throws {
        let calls = Box(0)
        let cache = AsyncStackCache(now: { 0 }, startTime: { _ in 1 }, detect: { _ in
            calls.value += 1
            return Stack(runtime: calls.value == 1 ? "Old" : "New")
        })
        #expect(cache.detectNow(pid: 5).runtime == "Old")
        #expect(cache.stack(for: 5)?.runtime == "Old")
        cache.forget(pid: 5)
        #expect(cache.stack(for: 5) == nil)   // unknown again: re-detected
        for _ in 0..<200 where cache.stack(for: 5) == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(cache.stack(for: 5)?.runtime == "New")
        #expect(calls.value == 2)
    }

    /// A PID whose process start time changed (reused at once, before any pruning) is not given the old stack.
    @Test func stackCacheChecksStartTime() async throws {
        let start = Box<UInt64?>(100)
        let calls = Box(0)
        let cache = AsyncStackCache(now: { 0 }, startTime: { _ in start.value }, detect: { _ in
            calls.value += 1
            return Stack(runtime: calls.value == 1 ? "Old" : "New")
        })
        #expect(cache.detectNow(pid: 5).runtime == "Old")
        start.value = nil                         // exited: the cached stack is still the best answer
        #expect(cache.stack(for: 5)?.runtime == "Old")
        start.value = 200                         // a new process with the same PID
        #expect(cache.stack(for: 5) == nil)
        #expect(cache.detectNow(pid: 5).runtime == "New")
        #expect(cache.stack(for: 5)?.runtime == "New")
        #expect(calls.value == 2)
    }

    @Test func startTimeOfThisProcess() {
        let t = ProcessNames.startTime(pid: getpid())
        #expect(t != nil)
        #expect(t == ProcessNames.startTime(pid: getpid()))
        #expect(ProcessNames.startTime(pid: -1) == nil)
    }
}
