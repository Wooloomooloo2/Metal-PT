import CoreGraphics
import Foundation
import Testing
@testable import MetalPT
@testable import MPTApp
@testable import MPTCore

@Suite struct OverlayTextTests {
    @Test func stripWithEverythingKnown() {
        let n = OverlayNumbers(recordingElapsed: 83, fps: 58.2, systemW: 40.6, gpuPct: 92.3, dieC: 78.1)
        #expect(n.recText == "● 01:23")
        #expect(n.stripParts == ["58 fps", "41 W", "GPU 92%", "78 °C"])
        #expect(n.stripText == "● 01:23  58 fps · 41 W · GPU 92% · 78 °C")
    }

    /// Not recording: no mark; unknown values are left out; FPS shows "–" without a game.
    @Test func stripLeavesOutUnknowns() {
        let n = OverlayNumbers(fps: nil, systemW: 9.2, gpuPct: nil, dieC: .nan)
        #expect(n.recText == nil)
        #expect(n.stripText == "– fps · 9 W")
    }

    @Test func detailLines() {
        let n = OverlayNumbers(fps: 58.2, systemW: 41, gpuPct: 92, cpuPPct: 31, cpuEPct: 18, dieC: 78,
                               fanRPM: [3080, 3100.4], stack: "Protium · FEX · DXMT", app: "Game")
        #expect(n.detailLines == ["avg frame 17.2 ms", "System 41 W · GPU 92%", "CPU P 31% · E 18%",
                                  "Die 78 °C · fans 3100"])
        #expect(n.stackLine == "Protium · FEX · DXMT")
        let none = OverlayNumbers()
        #expect(none.detailLines == ["System – · GPU –", "CPU P – · E –", "Die –"])
        #expect(none.stackLine == "No game detected")
        #expect(OverlayNumbers(app: "Game").stackLine == "Detecting stack…")
    }

    @Test func styleResolution() {
        #expect(OverlayStyle(setting: nil) == .auto)
        #expect(OverlayStyle(setting: "bogus") == .auto)
        #expect(OverlayStyle.auto.showsDetailed(recording: false) == false)
        #expect(OverlayStyle.auto.showsDetailed(recording: true))
        #expect(OverlayStyle.compact.showsDetailed(recording: true) == false)
        #expect(OverlayStyle.detailed.showsDetailed(recording: false))
    }

    @Test func backgroundAlpha() {
        // "Background opacity" is the background's alpha, directly; the default keeps the earlier look (~60 %).
        #expect(OverlayDefaults.opacity == 0.6)
        #expect(OverlayView.backgroundAlpha(0.6) == 0.6)
        #expect(OverlayView.backgroundAlpha(1) == 1)
        #expect(OverlayView.backgroundAlpha(2) == 1)
        #expect(OverlayView.backgroundAlpha(-1) == 0)
        #expect(OverlayView.backgroundAlpha(.nan) == OverlayDefaults.opacity)
        #expect(OverlayView.opacityPercent(0.6) == "60 %")
        #expect(OverlayView.opacityPercent(0.004) == "0 %")
    }
}

@Suite struct OverlayCornerTests {
    /// A screen at (0, 0) 1512×945 with the menu bar taken off the top (AppKit coordinates, y up).
    let area = CGRect(x: 0, y: 0, width: 1512, height: 920)
    let size = CGSize(width: 260, height: 24)

    @Test func cornersInsetSixteen() {
        #expect(OverlayCorner(setting: nil) == .topLeft)
        #expect(OverlayCorner.topLeft.frame(size: size, in: area) == CGRect(x: 16, y: 880, width: 260, height: 24))
        #expect(OverlayCorner.topRight.frame(size: size, in: area)
                == CGRect(x: 1236, y: 880, width: 260, height: 24))
        #expect(OverlayCorner.bottomLeft.frame(size: size, in: area) == CGRect(x: 16, y: 16, width: 260, height: 24))
        #expect(OverlayCorner.bottomRight.frame(size: size, in: area)
                == CGRect(x: 1236, y: 16, width: 260, height: 24))
    }

    /// A second screen left of and above the main one (negative origin).
    @Test func offsetScreen() {
        let other = CGRect(x: -1920, y: 200, width: 1920, height: 1080)
        #expect(OverlayCorner.topRight.frame(size: size, in: other)
                == CGRect(x: -276, y: 1240, width: 260, height: 24))
    }
}

/// The overlay holds `.samples` exactly while it is on (no AppKit: `usesAppKit: false`).
@MainActor
@Suite struct OverlayLeaseTests {
    private struct NoTimer: HubTimer { func cancel() {} }
    private struct NoScheduler: HubScheduler {
        func repeating(every interval: Double, _ work: @escaping @Sendable () -> Void) -> HubTimer { NoTimer() }
        func once(after delay: Double, _ work: @escaping @Sendable () -> Void) -> HubTimer { NoTimer() }
    }
    private struct NoLaunchctl: LaunchctlRunning {
        func getenv(_ name: String) -> String? { nil }
        func setenv(_ name: String, _ value: String) throws {}
        func unsetenv(_ name: String) throws {}
    }

    private func model() -> (AppModel, TelemetryHub) {
        var deps = TelemetryHub.Dependencies.inert
        deps.scheduler = NoScheduler()
        let hub = TelemetryHub(dependencies: deps)
        let suite = "metal-pt.tests.overlay.\(UUID().uuidString)"
        let model = AppModel(hub: hub, fpsLogging: FPSLogging(launchctl: NoLaunchctl()), live: true,
                             usesAppKit: false, defaults: UserDefaults(suiteName: suite)!, env: [:])
        return (model, hub)
    }

    @Test func samplesHeldOnlyWhileOn() {
        let (model, hub) = model()
        model.launch()
        #expect(model.overlayOn == false)
        #expect(hub.holdCountForTesting(.samples) == 0)
        model.toggleOverlay()
        #expect(model.overlayOn)
        #expect(hub.holdCountForTesting(.samples) == 1)
        model.overlayOn = true
        #expect(hub.holdCountForTesting(.samples) == 1)
        model.toggleOverlay()
        #expect(hub.holdCountForTesting(.samples) == 0)
        model.toggleOverlay()
        model.quit()
        #expect(model.overlayOn == false)
        #expect(hub.holdCountForTesting(.samples) == 0)
        model.toggleOverlay()   // after quit: ignored
        #expect(hub.holdCountForTesting(.samples) == 0)
    }

    /// Snapshot models (`live: false`) never take the lease.
    @Test func notLiveNeverHolds() {
        let hub = TelemetryHub(dependencies: .inert)
        let model = AppModel(hub: hub, fpsLogging: FPSLogging(launchctl: NoLaunchctl()), live: false, env: [:])
        model.overlayOn = true
        #expect(hub.holdCountForTesting(.samples) == 0)
    }
}
