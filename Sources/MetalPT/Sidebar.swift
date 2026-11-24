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
    @State private var page: Page? = .live

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $page) { p in
                Label(p.title, systemImage: p.symbol).tag(p)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 240)
        } detail: {
            PageView(page: page ?? .live, model: model, hub: hub)
                .navigationTitle((page ?? .live).title)
        }
        .frame(minWidth: 760, minHeight: 520)
        .onAppear { model.mainWindowOpened() }
        .onDisappear { model.mainWindowClosed() }
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
        case .runs:
            PlaceholderPage(symbol: page.symbol, title: "Runs",
                            text: "Your recordings will be listed here, with each run's summary, notes and Submit.")
        case .compare:
            PlaceholderPage(symbol: page.symbol, title: "Compare",
                            text: "Saved comparisons of runs will appear here, each with its report.")
        case .settings:
            PlaceholderPage(symbol: page.symbol, title: "Settings",
                            text: "Hotkeys, overlay, FPS logging, data folder and launch at login will be set here.")
        }
    }
}
