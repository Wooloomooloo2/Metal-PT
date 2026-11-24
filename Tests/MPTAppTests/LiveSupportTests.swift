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
}
