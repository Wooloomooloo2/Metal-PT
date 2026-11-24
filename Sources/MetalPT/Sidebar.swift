import MPTApp
import SwiftUI

/// The main window's pages, in sidebar order.
enum Page: String, CaseIterable, Identifiable {
    case live, runs, compare, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .live: "Live"
        case .runs: "Runs"
        case .compare: "Compare"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .live: "waveform.path.ecg"
        case .runs: "list.bullet.rectangle"
        case .compare: "chart.bar.xaxis"
        case .settings: "gearshape"
        }
    }
}

/// The main window: sidebar + the selected page.
struct MainWindow: View {
    @ObservedObject var model: AppModel
    @ObservedObject var hub: TelemetryHub
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $model.page) { p in
                Label(p.title, systemImage: p.symbol).tag(p)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 240)
        } detail: {
            PageView(page: model.page ?? .live, model: model, hub: hub)
                .navigationTitle((model.page ?? .live).title)
        }
        .frame(minWidth: 820, minHeight: 520)   // sidebar (up to 240) + PageView.minimumWidth
        .background(WindowObserver(state: model.windowState))
        .onAppear {
            // Kept after the window closes, so a notification click can reopen it.
            let open = openWindow
            model.openMainWindow = { open(id: MetalPTApp.mainWindowID) }
        }
    }
}

/// The content of one page.
struct PageView: View {
    let page: Page
    @ObservedObject var model: AppModel
    @ObservedObject var hub: TelemetryHub

    /// Pages are never measured narrower than this. macOS sizes the window from the content's minimum size, taken
    /// at the narrowest width the content allows; without a floor, wrapping text (empty-state cards, Settings
    /// explanations) asks for thousands of points of height there, and the window content is laid out too tall —
    /// the sidebar rows and the page header end up off-screen (WindowLayoutTests).
    static let minimumWidth: CGFloat = 600

    var body: some View {
        Group {
            switch page {
            case .live: LivePage(model: model, hub: hub)
            case .runs: RunsPage(model: model)
            case .compare: ComparePage(model: model)
            case .settings: SettingsPage(model: model)
            }
        }
        .frame(minWidth: Self.minimumWidth)
    }
}
