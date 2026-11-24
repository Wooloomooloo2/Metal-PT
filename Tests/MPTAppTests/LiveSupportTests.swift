import Testing
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
        #expect(!lease.isHeld)
        lease.hold(.samples, on: hub)
        lease.hold(.samples, on: hub)   // appear twice: still one hold
        #expect(lease.isHeld)
        #expect(hub.holdCountForTesting(.samples) == 1)
        lease.release()
        lease.release()
        #expect(!lease.isHeld)
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
