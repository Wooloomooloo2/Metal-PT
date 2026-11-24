import AppKit
import MPTApp
import SwiftUI
import Testing
@testable import MetalPT

/// Regression: macOS sizes a window from its content's *minimum* size, measured at the narrowest width the
/// content allows. Text with `.fixedSize(horizontal: false, vertical: true)` (empty-state cards, Settings
/// explanations) then wraps a word per line and demands thousands of points of height; the real window kept its
/// size, so its content was laid out too tall and centred — sidebar rows and the Live header were pushed off-screen.
/// Each page is hosted in a standard 1000 × 680 window and must not grow it.
@MainActor @Suite struct WindowLayoutTests {
    private func settledHeight<V: View>(_ view: V) -> CGFloat {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        for _ in 0..<10 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        host.layoutSubtreeIfNeeded()
        let height = host.frame.height
        window.contentView = nil
        return height
    }

    private func model(fpsLogging: Bool) -> AppModel {
        let defaults = MemoryDefaults()
        defaults.set(fpsLogging, forKey: SettingsKey.fpsLogging)
        return AppModel(hub: TelemetryHub(dependencies: .inert), fpsLogging: FPSLogging(), live: false,
                        defaults: defaults)
    }

    @Test(arguments: [Page.live, .runs, .compare, .settings])
    func everyPageFitsAStandardWindow(page: Page) {
        let m = model(fpsLogging: false)   // Live shows its largest empty-state card
        let height = settledHeight(PageView(page: page, model: m, hub: m.hub))
        #expect(height <= 700, "\(page) grew the window to \(height) pt")
    }

    @Test func liveWithFPSLoggingOnFitsToo() {
        let m = model(fpsLogging: true)    // the "No game yet" card
        #expect(settledHeight(PageView(page: .live, model: m, hub: m.hub)) <= 700)
    }
}
