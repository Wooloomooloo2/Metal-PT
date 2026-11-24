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

private final class Atomic: @unchecked Sendable {
    private let l = NSLock(); private var n = 0
    func bump() { l.withLock { n += 1 } }
    var value: Int { l.withLock { n } }
}
