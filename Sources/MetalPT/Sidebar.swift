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
        .frame(minWidth: 760, minHeight: 520)
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

    var body: some View {
        switch page {
        case .live: LivePage(model: model, hub: hub)
        case .runs: RunsPage(model: model)
        case .compare:
            PlaceholderPage(symbol: page.symbol, title: "Compare",
                            text: "Saved comparisons of runs will appear here, each with its report.")
        case .settings:
            PlaceholderPage(symbol: page.symbol, title: "Settings",
                            text: "Hotkeys, overlay, FPS logging, data folder and launch at login will be set here.")
        }
    }
}
