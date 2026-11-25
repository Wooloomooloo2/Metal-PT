import Testing
import Combine
import Foundation
import MPTCore
@testable import MPTApp

@MainActor
@Suite struct LiveSupportTests {
    private func snap(_ t: Double, fps: Double?) -> HubSnapshot {
        HubSnapshot(time: t, sample: TelemetrySample(), fps: fps, followedPID: nil, followedApp: nil, stack: nil)
    }

    @Test func leaseHoldsOnceAndReleases() {
        let hub = TelemetryHub(dependencies: .inert)
        let lease = HubLease()
        lease.hold(.samples, on: hub)
        lease.hold(.samples, on: hub)   // appear twice: still one hold
        #expect(hub.holdCountForTesting(.samples) == 1)
        lease.release()
        lease.release()
        #expect(hub.holdCountForTesting(.samples) == 0)
        lease.hold(.samples, on: hub)   // reappear
        #expect(hub.holdCountForTesting(.samples) == 1)
        lease.release()
    }

    @Test func leaseReleasesOnDeinit() {
        let hub = TelemetryHub(dependencies: .inert)
        var lease: HubLease? = HubLease()
        lease?.hold(.samples, on: hub)
        #expect(hub.holdCountForTesting(.samples) == 1)
        lease = nil
        #expect(hub.holdCountForTesting(.samples) == 0)
    }

    @Test func seriesIsSecondsAgoWithGaps() {
        let history = [snap(100, fps: 60), snap(101, fps: 59), snap(102, fps: nil), snap(103, fps: .nan),
                       snap(104, fps: 30), snap(105, fps: 31)]
        let p = LiveSeries.points(history) { $0.fps }
        #expect(p.map(\.secondsAgo) == [-5, -4, -1, 0])
        #expect(p.map(\.segment) == [0, 0, 1, 1])
        #expect(p.map(\.value) == [60, 59, 30, 31])
    }

    @Test func seriesDropsOlderThanWindow() {
        let history = (0...400).map { snap(Double($0), fps: 60) }
        let p = LiveSeries.points(history) { $0.fps }
        #expect(p.first?.secondsAgo == -300)
        #expect(p.count == 301)
        #expect(LiveSeries.points([]) { $0.fps }.isEmpty)
    }
}

@MainActor
@Suite struct LiveSupportFixRound1Tests {
    private func snap(_ t: Double, fps: Double?) -> HubSnapshot {
        HubSnapshot(time: t, sample: TelemetrySample(), fps: fps, followedPID: nil, followedApp: nil, stack: nil)
    }

    @Test func leaseSetFollowsWant() {
        let hub = TelemetryHub(dependencies: .inert)
        let lease = HubLease()
        lease.set(true, .samples, on: hub)
        lease.set(true, .samples, on: hub)
        #expect(hub.holdCountForTesting(.samples) == 1)
        #expect(hub.isSampling)
        lease.set(false, .samples, on: hub)
        #expect(hub.holdCountForTesting(.samples) == 0)
        #expect(!hub.isSampling)
    }

    @Test func samplingChangeIsReported() {
        let hub = TelemetryHub(dependencies: .inert)
        var seen: [Bool] = []
        hub.onSamplingChange = { seen.append($0) }
        let a = hub.acquire(.samples)
        let b = hub.acquire(.samples)
        a.release()
        b.release()
        #expect(seen == [true, false])
    }

    /// Closing the main window stops the Live page's hold even though the page never disappears.
    @Test func windowStateGatesLiveHold() {
        let hub = TelemetryHub(dependencies: .inert)
        let window = MainWindowState()
        let lease = HubLease()
        let sync = { lease.set(LiveSeries.wantsSamples(pageVisible: true, window: window), .samples, on: hub) }
        window.update(windowVisible: true, onScreen: true)
        sync()
        #expect(window.isOpen && window.isVisible)
        #expect(hub.holdCountForTesting(.samples) == 1)
        window.update(windowVisible: true, onScreen: false)   // minimised or fully covered
        sync()
        #expect(window.isOpen && !window.isVisible)
        #expect(hub.holdCountForTesting(.samples) == 0)
        window.update(windowVisible: true, onScreen: true)
        sync()
        #expect(hub.holdCountForTesting(.samples) == 1)
        window.closed()
        sync()
        #expect(!window.isOpen && !window.isVisible)
        #expect(hub.holdCountForTesting(.samples) == 0)
        // A late occlusion note from the closing window does not reopen it.
        window.update(windowVisible: false, onScreen: true)
        #expect(!window.isOpen && !window.isVisible)
    }

    @Test func pinPublishesAtOnce() {
        let hub = TelemetryHub(dependencies: .inert)
        var fired = 0
        let c = hub.objectWillChange.sink { fired += 1 }
        hub.pinned = 42
        #expect(fired == 1)
        withExtendedLifetime(c) {}
    }

    @Test func seriesBreaksAcrossTimeGap() {
        let history = [snap(100, fps: 60), snap(101, fps: 60), snap(120, fps: 50), snap(121, fps: 50)]
        let p = LiveSeries.points(history) { $0.fps }
        #expect(p.map(\.segment) == [0, 0, 1, 1])
        #expect(p.map(\.time) == [100, 101, 120, 121])
    }

    // MARK: - Limited by (last 30 s)

    private func busy(_ t: Double, _ gpu: Double?, core: Double = 50, fps: Double? = 50, mhz: Double? = nil,
                      thermal: String = "nominal") -> HubSnapshot {
        HubSnapshot(time: t, sample: TelemetrySample(cpuPUtilPct: 30, cpuCoreMaxPct: core, gpuBusyPct: gpu,
                                                     thermalState: thermal, gpuMHz: mhz),
                    fps: fps, followedPID: 1, followedApp: "g", stack: nil)
    }

    @Test func snapshotMapsToSecond() {
        let snap = HubSnapshot(time: 1, sample: TelemetrySample(cpuPUtilPct: 81, cpuCoreMaxPct: 92, gpuBusyPct: 97,
                                                                 thermalState: "serious", gpuMHz: 1200,
                                                                 memPressure: "warn", pageoutsPerS: 12),
                               fps: 59.5, followedPID: 1, followedApp: "g", stack: nil)
        let s = LiveLimiter.second(snap)
        #expect(s.fps == 59.5)
        #expect(s.gpuBusyPct == 97)
        #expect(s.gpuMHz == 1200)
        #expect(s.memPressure == "warn")
        #expect(s.pageoutsPerSecond == 12)
        #expect(s.thermalLevel == 2)
        #expect(s.coreMaxPct == 92)
        #expect(s.pCoresPct == 81)
    }

    @Test func majorityOfTheLastThirtySeconds() {
        // 40 CPU-bound seconds long ago, then 30 s: 20 GPU, 10 unclear → GPU (67 %).
        let old = (0..<40).map { busy(Double($0), 50, core: 99) }
        let recent = (0..<30).map { busy(100 + Double($0), $0 < 20 ? 100 : 90) }
        #expect(LiveLimiter.current(old + recent, topMHz: nil) == .limiter(.gpu))
        #expect(LiveLimiter.label(.limiter(.gpu)) == "Limited by: GPU")
    }

    @Test func noMajorityIsMixedAndUnclearIsNotALimiter() {
        let mixed = (0..<30).map { busy(Double($0), $0 % 2 == 0 ? 100 : 50, core: 99) }
        #expect(LiveLimiter.current(mixed, topMHz: nil) == .mixed)
        #expect(LiveLimiter.label(.mixed) == "Limited by: mixed")
        let unclear = (0..<30).map { busy(Double($0), 90) }
        #expect(LiveLimiter.current(unclear, topMHz: nil) == .limiter(.unclear))
        #expect(LiveLimiter.label(.limiter(.unclear)) == "No single limit")
    }

    @Test func hiddenWithUnderTenSecondsOfData() {
        #expect(LiveLimiter.current((0..<9).map { busy(Double($0), 100) }, topMHz: nil) == nil)
        #expect(LiveLimiter.current((0..<10).map { busy(Double($0), 100) }, topMHz: nil) == .limiter(.gpu))
        // Seconds without GPU busy are not data.
        let gaps = (0..<30).map { busy(Double($0), $0 < 9 ? 100 : nil) }
        #expect(LiveLimiter.current(gaps, topMHz: nil) == nil)
        #expect(LiveLimiter.current([], topMHz: nil) == nil)
    }

    @Test func busyAtLowClockIsNotGPU() {
        // Busy 100 % at a third of the top clock: the game isn't pushing the GPU (ruling L1).
        let low = (0..<30).map { busy(Double($0), 100, mhz: 500) }
        #expect(LiveLimiter.current(low, topMHz: 1578) == .limiter(.unclear))
        #expect(LiveLimiter.current(low, topMHz: nil) == .limiter(.gpu))
    }

    /// Same clock rule as a run (ruling L3): the measured table's top steps count as GPU-bound.
    @Test func measuredTableTopStepsAreGPU() {
        let table: [Double] = [338, 618, 796, 924, 952, 1056, 1062, 1182, 1182, 1312, 1242, 1380, 1326, 1470, 1578]
        let p13 = (0..<30).map { busy(Double($0), 99, mhz: $0 % 2 == 0 ? 1326 : 1380) }
        #expect(LiveLimiter.current(p13, topMHz: 1578, tableMHz: table) == .limiter(.gpu))
        #expect(LiveLimiter.current(p13, topMHz: 1578) == .mixed)   // without the table: 85 % only
    }

    @Test func lowPowerOrBatteryJudgesOnBusyOnly() {
        let low = (0..<30).map { busy(Double($0), 100, mhz: 500) }
        #expect(LiveLimiter.current(low, topMHz: 1578, powerMode: "low") == .limiter(.gpu))
        let onBattery = (0..<30).map { i -> HubSnapshot in
            HubSnapshot(time: Double(i), sample: TelemetrySample(cpuPUtilPct: 30, cpuCoreMaxPct: 50, gpuBusyPct: 100,
                                                                 onAC: i >= 20 ? true : false, gpuMHz: 500),
                        fps: 50, followedPID: 1, followedApp: "g", stack: nil)
        }
        #expect(LiveLimiter.current(onBattery, topMHz: 1578) == .limiter(.gpu))
    }

    /// Like a run: memory seconds count even without GPU busy.
    @Test func memorySecondsWithoutBusyCount() {
        let mem = (0..<30).map { i in
            HubSnapshot(time: Double(i), sample: TelemetrySample(memPressure: "critical"), fps: 50, followedPID: 1,
                        followedApp: "g", stack: nil)
        }
        #expect(LiveLimiter.current(mem, topMHz: nil) == .limiter(.memory))
    }

    // MARK: - Live FPS per watt (Review Focus 5)

    private func power(_ t: Double, fps: Double?, watts: Double?) -> HubSnapshot {
        HubSnapshot(time: t, sample: TelemetrySample(smcPower: watts.map { ["PSTR": $0] } ?? [:]), fps: fps,
                    followedPID: 1, followedApp: "g", stack: nil)
    }

    @Test func liveFPSPerWattOverTheLastTenSeconds() throws {
        // 30 s of 30 fps at 60 W, then 10 s of 60 fps at 30 W: only the last 10 s count.
        let h = (0..<30).map { power(Double($0), fps: 30, watts: 60) }
            + (30..<40).map { power(Double($0), fps: 60, watts: 30) }
        let v = try #require(LiveEfficiency.fpsPerWatt(history: h))
        #expect(abs(v - 2.0) < 1e-9)
        #expect(LiveEfficiency.window == 10)
        #expect(LiveEfficiency.text(v) == "2.00")
        #expect(LiveEfficiency.text(nil) == "–")
    }

    @Test func liveFPSPerWattNeedsFPSAndSystemPower() {
        #expect(LiveEfficiency.fpsPerWatt(history: []) == nil)
        let noFPS = (0..<10).map { power(Double($0), fps: nil, watts: 30) }
        #expect(LiveEfficiency.fpsPerWatt(history: noFPS) == nil)
        let noPower = (0..<10).map { power(Double($0), fps: 60, watts: nil) }
        #expect(LiveEfficiency.fpsPerWatt(history: noPower) == nil)
        // No division by ~0 W.
        let tiny = (0..<10).map { power(Double($0), fps: 60, watts: 0.4) }
        #expect(LiveEfficiency.fpsPerWatt(history: tiny) == nil)
        let nan = (0..<10).map { power(Double($0), fps: .nan, watts: 30) }
        #expect(LiveEfficiency.fpsPerWatt(history: nan) == nil)
        // FPS and power older than the window do not count.
        let old = (0..<5).map { power(Double($0), fps: 60, watts: 30) } + [power(40, fps: nil, watts: nil)]
        #expect(LiveEfficiency.fpsPerWatt(history: old) == nil)
    }
}
