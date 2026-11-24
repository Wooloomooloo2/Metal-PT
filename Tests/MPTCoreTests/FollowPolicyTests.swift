import Testing
import Foundation
@testable import MPTCore

private final class NoTelemetry: TelemetrySource, @unchecked Sendable {
    func sample() -> TelemetrySample { TelemetrySample() }
}

@Suite struct FollowPolicyTests {
    private func recorder(_ rule: FollowRule, stacks: [Int32: String?]) throws -> RunRecorder {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fp-\(UUID().uuidString)/x.mptrun")
        let info = RunInfo(appVersion: "t", machine: .init(modelID: "m", chip: "c", memoryGB: 1, osVersion: "1", osBuild: "x"),
                           game: .init(exe: "run"), start: Date(timeIntervalSince1970: 0))
        let w = try RunBundleWriter(directory: dir, info: info)
        return RunRecorder(writer: w, telemetry: NoTelemetry(), startTime: 0, follow: rule, argv0: { _ in nil },
                           stackOf: { pid in stacks[pid].flatMap { $0 }.map { Stack(runtime: $0) } })
    }

    private func feed(_ r: RunRecorder, pid: Int32, frames: Int, until t: Double) {
        for (i, tt) in [0.0, t].enumerated() {
            r.hud(HUDEvent(pid: pid, imagePath: "/x/\(pid)", time: tt,
                           line: MetalHUDLine(frames: i == 0 ? 0 : frames, a: 0, b: 0, frameTimes: [])))
        }
    }

    @Test func prefersWineOverBusierNative() throws {
        let r = try recorder(.preferTranslated(exclude: [], pinned: nil), stacks: [3000: "native", 500: "Wine (unknown)"])
        feed(r, pid: 3000, frames: 3000, until: 1)
        feed(r, pid: 500, frames: 30, until: 1)
        #expect(r.followedPID == 500)
    }

    @Test func fallsBackToBusiest() throws {
        // Unknown (nil) must not count as translated: 1 is busier and wins.
        let r = try recorder(.preferTranslated(exclude: [], pinned: nil), stacks: [1: "native", 2: nil])
        feed(r, pid: 1, frames: 99, until: 1)
        feed(r, pid: 2, frames: 10, until: 1)
        #expect(r.followedPID == 1)
    }

    @Test func pinnedExcludedIsIgnored() throws {
        let r = try recorder(.preferTranslated(exclude: [7], pinned: 7), stacks: [7: "native", 8: "native"])
        feed(r, pid: 7, frames: 500, until: 1)
        feed(r, pid: 8, frames: 5, until: 1)
        #expect(r.followedPID == 8)
    }

    @Test func staleTranslatedLosesToLiveNative() throws {
        let r = try recorder(.preferTranslated(exclude: [], pinned: nil), stacks: [1: "CrossOver", 2: "native"])
        feed(r, pid: 1, frames: 500, until: 1)
        feed(r, pid: 2, frames: 5, until: 10)
        #expect(r.followedPID == 2)
    }

    @Test func nothingLiveFallsBackToMostFrames() throws {
        let r = try recorder(.preferTranslated(exclude: [9], pinned: nil), stacks: [:])
        feed(r, pid: 1, frames: 50, until: 1)
        feed(r, pid: 2, frames: 500, until: 1)
        feed(r, pid: 9, frames: 9000, until: 1)
        feed(r, pid: 3, frames: 1, until: 60)   // live, but only 1 frame; 1 and 2 are stale
        // The only live candidate wins over stale ones with more frames.
        #expect(r.followedPID == 3)
        let q = try recorder(.preferTranslated(exclude: [9], pinned: nil), stacks: [:])
        feed(q, pid: 1, frames: 50, until: 1)
        feed(q, pid: 2, frames: 500, until: 1)
        feed(q, pid: 9, frames: 9000, until: 60)   // newest line is from the excluded PID: nothing live
        #expect(q.followedPID == 2)
    }

    @Test func excludesSelf() throws {
        let r = try recorder(.preferTranslated(exclude: [7], pinned: nil), stacks: [7: "Wine (unknown)", 8: "native"])
        feed(r, pid: 7, frames: 500, until: 1)
        feed(r, pid: 8, frames: 5, until: 1)
        #expect(r.followedPID == 8)
    }

    @Test func pinnedWinsWhileLive() throws {
        let r = try recorder(.preferTranslated(exclude: [], pinned: 8), stacks: [7: "CrossOver", 8: "native"])
        feed(r, pid: 7, frames: 500, until: 1)
        feed(r, pid: 8, frames: 5, until: 1)
        #expect(r.followedPID == 8)
    }

    @Test func pinnedExpiresWhenStale() throws {
        let r = try recorder(.preferTranslated(exclude: [], pinned: 8), stacks: [7: "CrossOver", 8: "native"])
        feed(r, pid: 8, frames: 5, until: 1)
        feed(r, pid: 7, frames: 500, until: 10)   // 8 is now 9 s quiet
        #expect(r.followedPID == 7)
    }

    @Test func asyncCacheDetectsOnceAndNeverBlocks() async throws {
        let gate = DispatchSemaphore(value: 0)
        let calls = Atomic()
        let cache = AsyncStackCache(detect: { _ in calls.bump(); gate.wait(); return Stack(runtime: "Protium") })
        #expect(cache.stack(for: 1) == nil)
        #expect(cache.stack(for: 1) == nil)
        gate.signal()
        for _ in 0..<100 where cache.stack(for: 1) == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(cache.stack(for: 1)?.runtime == "Protium")
        #expect(calls.value == 1)
    }
}

@Suite struct AsyncStackCacheTests {
    @Test func nativeIsRedetectedOnceAfterFiveSeconds() async throws {
        let clock = Atomic()   // seconds
        let calls = Atomic()
        let cache = AsyncStackCache(now: { Double(clock.value) }, detect: { _ in
            calls.bump()
            return Stack(runtime: calls.value == 1 ? "native" : "Wine (unknown)")
        })
        func settle(_ n: Int) async throws {
            for _ in 0..<200 where calls.value < n || cache.pendingCount > 0 { try await Task.sleep(for: .milliseconds(10)) }
        }
        _ = cache.stack(for: 1)
        try await settle(1)
        #expect(cache.stack(for: 1)?.runtime == "native")
        for _ in 0..<5 { clock.bump() }   // 5 s later
        #expect(cache.stack(for: 1)?.runtime == "native")   // returns old value while retrying
        try await settle(2)
        #expect(cache.stack(for: 1)?.runtime == "Wine (unknown)")
        for _ in 0..<10 { clock.bump() }
        _ = cache.stack(for: 1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(calls.value == 2)
    }

    @Test func earlyLookupDoesNotRetry() async throws {
        let calls = Atomic()
        let cache = AsyncStackCache(now: { 0 }, detect: { _ in calls.bump(); return Stack(runtime: "native") })
        _ = cache.stack(for: 1)
        for _ in 0..<100 where cache.stack(for: 1) == nil { try await Task.sleep(for: .milliseconds(10)) }
        _ = cache.stack(for: 1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(calls.value == 1)
    }
}

@Suite struct FollowResolverTests {
    private func counter(_ feeds: [(pid: Int32, frames: Int, until: Double)]) -> FrameCounter {
        var c = FrameCounter()
        for f in feeds {
            c.add(HUDEvent(pid: f.pid, imagePath: "/x", time: 0, line: MetalHUDLine(frames: 0, a: 0, b: 0, frameTimes: [])))
            c.add(HUDEvent(pid: f.pid, imagePath: "/x", time: f.until,
                           line: MetalHUDLine(frames: f.frames, a: 0, b: 0, frameTimes: [])))
        }
        return c
    }

    @Test func liveCandidatesBusiestFirstWithoutExcluded() {
        let c = counter([(1, 10, 5), (2, 300, 5), (3, 99, 5), (4, 9999, 1)])   // 4 is stale at 5
        #expect(FollowResolver.liveCandidates(counter: c, pids: [1, 2, 3, 4], exclude: [3], at: 5) == [2, 1])
    }

    @Test func resolverMatchesTheRule() {
        let c = counter([(1, 300, 5), (2, 10, 5)])
        let stacks: [Int32: Stack] = [1: Stack(runtime: "native"), 2: Stack(runtime: "CrossOver")]
        #expect(FollowResolver.preferTranslated(counter: c, pids: [1, 2], exclude: [], pinned: nil, at: 5,
                                                stack: { stacks[$0] }) == 2)
        #expect(FollowResolver.preferTranslated(counter: c, pids: [1, 2], exclude: [], pinned: 1, at: 5,
                                                stack: { stacks[$0] }) == 1)
    }
}

@Suite struct AsyncStackCacheWaitTests {
    @Test func detectNowSharesADetectionUnderWay() async throws {
        let gate = DispatchSemaphore(value: 0)
        let calls = Atomic()
        let cache = AsyncStackCache(detect: { _ in calls.bump(); gate.wait(); return Stack(runtime: "Protium") })
        #expect(cache.stack(for: 1) == nil)   // starts the background detection
        for _ in 0..<100 where calls.value == 0 { try await Task.sleep(for: .milliseconds(10)) }
        let box = StackBox()
        DispatchQueue.global().async { box.value = cache.detectNow(pid: 1) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(box.value == nil)   // waiting for the detection under way
        gate.signal()
        for _ in 0..<200 where box.value == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(box.value?.runtime == "Protium")
        #expect(calls.value == 1)
        // Known: returned at once; unknown: detected inline.
        #expect(cache.detectNow(pid: 1).runtime == "Protium")
        gate.signal()
        #expect(cache.detectNow(pid: 2).runtime == "Protium")
        #expect(calls.value == 2)
        #expect(cache.stack(for: 2)?.runtime == "Protium")
    }
}

@Suite struct AsyncStackCacheRetryWaitTests {
    /// A known "native" result being re-detected: `detectNow` waits for the retry instead of returning the old one.
    @Test func detectNowWaitsForRetry() async throws {
        let clock = Atomic()
        let calls = Atomic()
        let gate = DispatchSemaphore(value: 0)
        let cache = AsyncStackCache(now: { Double(clock.value) }, detect: { _ in
            calls.bump()
            if calls.value == 1 { return Stack(runtime: "native") }
            gate.wait()
            return Stack(runtime: "Wine (unknown)")
        })
        #expect(cache.detectNow(pid: 1).runtime == "native")
        for _ in 0..<5 { clock.bump() }
        #expect(cache.stack(for: 1)?.runtime == "native")   // starts the retry
        let box = StackBox()
        DispatchQueue.global().async { box.value = cache.detectNow(pid: 1) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(box.value == nil)
        gate.signal()
        for _ in 0..<200 where box.value == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(box.value?.runtime == "Wine (unknown)")
    }
}

private final class StackBox: @unchecked Sendable {
    private let l = NSLock(); private var s: Stack?
    var value: Stack? { get { l.withLock { s } } set { l.withLock { s = newValue } } }
}

private final class Atomic: @unchecked Sendable {
    private let l = NSLock(); private var n = 0
    func bump() { l.withLock { n += 1 } }
    var value: Int { l.withLock { n } }
}
