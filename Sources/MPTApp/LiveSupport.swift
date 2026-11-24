import Combine
import Foundation
import MPTCore

/// A view's hold on one hub need while it is visible: `hold` on appear, `release` on disappear (and on deinit,
/// through the token). Holding twice keeps one token.
@MainActor
public final class HubLease: ObservableObject {
    private var token: TelemetryHub.Token?

    public init() {}

    public func hold(_ need: TelemetryHub.Need, on hub: TelemetryHub) {
        guard token == nil else { return }
        token = hub.acquire(need)
    }

    /// Holds while `want`, releases otherwise.
    public func set(_ want: Bool, _ need: TelemetryHub.Need, on hub: TelemetryHub) {
        if want { hold(need, on: hub) } else { release() }
    }

    public func release() {
        let t = token
        token = nil
        t?.release()
    }
}

/// The main window as the Live page needs it, fed by the window's own notifications (the SwiftUI `Window` scene
/// outlives a closed window, so `onDisappear` alone is not a guaranteed release).
@MainActor
public final class MainWindowState: ObservableObject {
    /// The window is open (it may be minimised or covered). Drives the Dock icon.
    @Published public private(set) var isOpen = false
    /// Open, and at least partly on screen (not minimised, not fully covered).
    @Published public private(set) var isVisible = false

    public init() {}

    /// After the window appears, becomes key, or changes occlusion: `windowVisible` is `NSWindow.isVisible`
    /// (false once ordered out, also when minimised), `onScreen` its occlusion state's `.visible`.
    /// Only a visible window counts as open, so a late note from a closing window does not reopen it.
    public func update(windowVisible: Bool, onScreen: Bool, miniaturized: Bool = false) {
        let open = windowVisible || miniaturized
        set(open: open, visible: windowVisible && onScreen && !miniaturized)
    }

    /// `NSWindow.willCloseNotification` (the window is still `isVisible` at that point).
    public func closed() { set(open: false, visible: false) }

    private func set(open: Bool, visible: Bool) {
        if isOpen != open { isOpen = open }
        if isVisible != visible { isVisible = visible }
    }
}

/// One chart point: x is seconds before the newest snapshot (−300…0). `segment` numbers each unbroken run of
/// values, so a chart drawing one line per segment shows a gap where a value was unknown. `time` (the snapshot's
/// epoch seconds) is a stable identity as the window slides.
public struct LivePoint: Sendable, Equatable {
    public let time: Double
    public let secondsAgo: Double
    public let value: Double
    public let segment: Int

    public init(time: Double, secondsAgo: Double, value: Double, segment: Int) {
        self.time = time
        self.secondsAgo = secondsAgo
        self.value = value
        self.segment = segment
    }
}

public enum LiveSeries {
    /// The window the Live charts show, seconds.
    public static let window = Double(TelemetryHub.historyLimit)
    /// Adjacent snapshots further apart than this (sleep, a paused sampler) are not joined.
    public static let maxStep = 5.0

    /// The Live page holds `.samples` only while it is shown in a visible main window.
    @MainActor
    public static func wantsSamples(pageVisible: Bool, window: MainWindowState) -> Bool {
        pageVisible && window.isVisible
    }

    /// Points of `value` over `history` (oldest first), relative to its newest snapshot. Unknown or non-finite
    /// values are skipped and start a new segment, as does a step longer than `maxStep`; snapshots older than
    /// `window` are dropped.
    public static func points(_ history: [HubSnapshot], _ value: (HubSnapshot) -> Double?) -> [LivePoint] {
        guard let now = history.last?.time else { return [] }
        var out: [LivePoint] = []
        var segment = 0
        var inRun = false
        var lastTime: Double?
        for snap in history {
            let ago = snap.time - now
            guard ago >= -window else { continue }
            if let v = value(snap), v.isFinite {
                if inRun, let t = lastTime, snap.time - t > maxStep { segment += 1 }
                out.append(LivePoint(time: snap.time, secondsAgo: ago, value: v, segment: segment))
                lastTime = snap.time
                inRun = true
            } else if inRun {
                segment += 1
                inRun = false
            }
        }
        return out
    }
}
