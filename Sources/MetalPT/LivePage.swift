import Charts
import MPTApp
import MPTCore
import SwiftUI

/// Live (spec §5): who is being followed, Record/Stop, the current numbers and the last five minutes as charts.
/// Holds `.samples` while shown in a visible main window (`LiveSeries.wantsSamples`): released on disappear and
/// when the window closes, is minimised or fully covered, even if SwiftUI never calls `onDisappear`.
struct LivePage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var hub: TelemetryHub
    @ObservedObject private var window: MainWindowState
    @StateObject private var lease = HubLease()
    @State private var pageVisible = false

    init(model: AppModel, hub: TelemetryHub) {
        self.model = model
        self.hub = hub
        self.window = model.windowState
    }

    private var following: Bool { hub.latest?.followedPID != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LiveHeader(model: model, hub: hub)
            ProblemsView(model: model, hub: hub)
            if !model.fpsLoggingOn {
                EmptyStateCard(
                    symbol: "gauge.with.dots.needle.0percent",
                    title: "FPS logging is off — turn it on, then start your game",
                    text: "Metal-PT reads frame rates from the Metal HUD log. Games started before FPS logging was "
                        + "on are not seen. Power, utilisation and temperatures below are live either way.",
                    action: ("Turn On FPS Logging", { model.setFPSLogging(true) }))
            } else if !following {
                EmptyStateCard(
                    symbol: "gamecontroller",
                    title: "No game yet — start or relaunch your game after turning on FPS logging",
                    text: "A game that was already running when FPS logging was turned on does not log frames. "
                        + "Power, utilisation and temperatures below are live.",
                    action: nil)
            }
            NumbersRow(snapshot: hub.latest, following: following)
            if following || hub.recording != nil {
                LimitedByChip(history: hub.history)
            }
            LiveCharts(history: hub.history, showFPS: following)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { pageVisible = true; syncLease() }
        .onDisappear { pageVisible = false; syncLease() }
        .onChange(of: window.isVisible) { syncLease() }
    }

    private func syncLease() {
        lease.set(LiveSeries.wantsSamples(pageVisible: pageVisible, window: window), .samples, on: hub)
    }
}

// MARK: - Header

/// "Following: <exe> ▾" with the stack under it; Record/Stop on the right.
private struct LiveHeader: View {
    @ObservedObject var model: AppModel
    @ObservedObject var hub: TelemetryHub

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                FollowMenu(hub: hub)
                Text(stackLine)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            RecordingBadge(model: model, hub: hub)
            RecordButton(model: model)
        }
    }

    private var stackLine: String {
        guard hub.latest?.followedPID != nil else { return "Waiting for a game that logs frames" }
        return Fmt.stack(hub.latest?.stack) ?? "Detecting stack…"
    }
}

/// The follow picker: Automatic (the follow rule) or one of the live candidates, which sticks until it exits.
private struct FollowMenu: View {
    @ObservedObject var hub: TelemetryHub

    var body: some View {
        Menu {
            Button {
                hub.pinned = nil
            } label: {
                if hub.pinned == nil { Image(systemName: "checkmark") }
                Text("Automatic")
                Text("Prefers translated games, then the busiest")
            }
            Divider()
            let candidates = hub.followCandidates
            if candidates.isEmpty {
                Text("No games logging frames").foregroundStyle(.secondary)
            }
            ForEach(candidates, id: \.pid) { c in
                Button {
                    hub.pinned = c.pid
                } label: {
                    if hub.pinned == c.pid { Image(systemName: "checkmark") }
                    Text(c.app)
                    Text(Fmt.stack(c.stack) ?? "Detecting stack…")
                }
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Following:").foregroundStyle(.secondary)
                Text(hub.latest?.followedPID != nil ? (hub.latest?.followedApp ?? "Unknown") : "No game")
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.title2)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: - Empty states

private struct EmptyStateCard: View {
    let symbol: String
    let title: String
    let text: String
    let action: (String, () -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(text)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let action {
                    Button(action.0, action: action.1)
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
    }
}

// MARK: - Current numbers

private struct NumbersRow: View {
    let snapshot: HubSnapshot?
    let following: Bool

    var body: some View {
        let s = snapshot?.sample
        HStack(spacing: 10) {
            BigNumber(name: "FPS", value: following ? Fmt.int(snapshot?.fps) : "–", unit: nil,
                      color: ChartPalette.primary)
            BigNumber(name: "System", value: Fmt.int(s.flatMap(Fmt.systemW)), unit: "W", color: ChartPalette.primary)
            BigNumber(name: "GPU busy", value: Fmt.int(s?.gpuBusyPct), unit: "%", color: ChartPalette.gpu)
            BigNumber(name: "Die", value: Fmt.int(s?.tempMaxC), unit: "°C", color: ChartPalette.fourth)
        }
    }
}

private struct BigNumber: View {
    let name: String
    let value: String
    let unit: String?
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(name).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                if let unit, value != "–" {
                    Text(unit).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }
}

// MARK: - Limited by

/// This Mac's GPU clock table (P1…Pn), read once (one IOReport sample and one IORegistry read) the first time the
/// chip needs it.
enum GPUTopClock {
    static let table: [Double]? = GPUClock.currentTableMHz()
}

/// "Limited by: GPU" over the last 30 s (`LiveLimiter`); hidden until there are 10 seconds to judge.
private struct LimitedByChip: View {
    let history: [HubSnapshot]
    @State private var table: [Double]?
    @State private var refreshHz: Double?

    var body: some View {
        Group {
            if let reading = LiveLimiter.current(history, topMHz: table?.max(), tableMHz: table,
                                                 powerMode: ProcessInfo.processInfo.isLowPowerModeEnabled ? "low" : nil,
                                                 refreshHz: refreshHz) {
                HStack(spacing: 7) {
                    Circle().fill(Self.color(reading)).frame(width: 8, height: 8)
                    Text(LiveLimiter.label(reading)).font(.callout.weight(.medium))
                    Text("last 30 s").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.primary.opacity(0.05)))
                .help("How the last 30 seconds were classified (last 30 s, includes loading screens), by the same rules "
                    + "as a run's \"What held it back\".")
            }
        }
        .task {
            refreshHz = MachineInfo.withMainDisplay(.init()).refreshHz
            table = await Task.detached(priority: .utility) { GPUTopClock.table }.value
        }
    }

    /// Matches the charts: GPU orange, CPU blue.
    static func color(_ r: LiveLimiter.Reading) -> Color {
        switch r {
        case .mixed, .limiter(.unclear): .secondary
        case .limiter(.gpu): ChartPalette.gpu
        case .limiter(.gpuThermal): .red
        case .limiter(.cpu), .limiter(.cpuOneThread): ChartPalette.primary
        case .limiter(.memory): ChartPalette.fourth
        case .limiter(.frameCap): .pink
        }
    }
}

// MARK: - Charts

/// The four charts over the hub history (x = seconds before the newest snapshot).
private struct LiveCharts: View {
    let history: [HubSnapshot]
    let showFPS: Bool

    var body: some View {
        VStack(spacing: 8) {
            if showFPS {
                LiveChart(title: "FPS", unit: "fps", series: [
                    .init(name: "FPS", color: ChartPalette.primary, points: points { $0.fps }),
                ], domain: .zeroTo(minUpper: 60))
            }
            LiveChart(title: "Power", unit: "W", series: [
                .init(name: "System", color: ChartPalette.primary, points: points { Fmt.systemW($0.sample) }),
                .init(name: "GPU (IOReport)", color: ChartPalette.gpu, dashed: true,
                      points: points { $0.sample.gpuW }),
            ], domain: .zeroTo(minUpper: 20))
            LiveChart(title: "Utilisation", unit: "%", series: [
                .init(name: "CPU P", color: ChartPalette.primary, points: points { $0.sample.cpuPUtilPct }),
                .init(name: "CPU E", color: ChartPalette.third, points: points { $0.sample.cpuEUtilPct }),
                .init(name: "GPU busy", color: ChartPalette.gpu, points: points { $0.sample.gpuBusyPct }),
            ], domain: .fixed(0...100))
            HStack(spacing: 8) {
                LiveChart(title: "Die temperature", unit: "°C", series: [
                    .init(name: "Hottest", color: ChartPalette.fourth, points: points { $0.sample.tempMaxC }),
                ], domain: .around(minSpan: 20), xLabels: true)
                LiveChart(title: "Fans", unit: "rpm", series: fanSeries, domain: .zeroTo(minUpper: 2000),
                          xLabels: true)
            }
        }
    }

    private func points(_ value: (HubSnapshot) -> Double?) -> [LivePoint] {
        LiveSeries.points(history, value)
    }

    /// One line per fan (Apple Silicon laptops have at most two).
    private var fanSeries: [LiveChart.Series] {
        let count = min(2, history.map(\.sample.fanRPM.count).max() ?? 0)
        let colors = [ChartPalette.primary, ChartPalette.third]
        return (0..<count).map { i in
            .init(name: count == 1 ? "Fan" : "Fan \(i + 1)", color: colors[i],
                  points: points { $0.sample.fanRPM.indices.contains(i) ? $0.sample.fanRPM[i] : nil })
        }
    }
}

private struct LiveChart: View {
    struct Series {
        let name: String
        let color: Color
        var dashed = false
        let points: [LivePoint]
    }

    enum Domain {
        /// 0 to the data's max (rounded up), at least `minUpper`.
        case zeroTo(minUpper: Double)
        case fixed(ClosedRange<Double>)
        /// Data min…max padded and rounded to tens, at least `minSpan` wide.
        case around(minSpan: Double)

        func range(_ values: [Double]) -> ClosedRange<Double> {
            switch self {
            case .fixed(let r):
                return r
            case .zeroTo(let minUpper):
                let top = max(minUpper, values.max() ?? 0)
                return 0...Self.niceCeil(top * 1.1)
            case .around(let minSpan):
                guard let lo = values.min(), let hi = values.max() else { return 30...(30 + minSpan) }
                var low = ((lo - 5) / 10).rounded(.down) * 10
                var high = ((hi + 5) / 10).rounded(.up) * 10
                if high - low < minSpan {
                    let pad = (minSpan - (high - low)) / 2
                    low -= pad
                    high += pad
                }
                return max(0, low)...high
            }
        }

        private static func niceCeil(_ v: Double) -> Double {
            let step: Double = v > 2000 ? 1000 : v > 200 ? 100 : v > 50 ? 20 : 10
            return max(step, (v / step).rounded(.up) * step)
        }
    }

    let title: String
    let unit: String
    let series: [Series]
    let domain: Domain
    var xLabels = false

    private static let ticks: [Double] = [-300, -240, -180, -120, -60, 0]
    private static let yLabelWidth: CGFloat = 26

    /// "75", "2k".
    static func axisLabel(_ v: Double) -> String {
        if abs(v) >= 1000 {
            let k = v / 1000
            return k == k.rounded() ? "\(Int(k))k" : String(format: "%.1fk", k)
        }
        return Fmt.int(v)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 12) {
                Text(title).font(.caption.weight(.semibold))
                Text(unit).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                ForEach(series, id: \.name) { s in
                    if series.count > 1 { LegendChip(name: s.name, color: s.color, dashed: s.dashed) }
                }
            }
            Chart {
                ForEach(series, id: \.name) { s in
                    ForEach(s.points, id: \.time) { p in
                        LineMark(x: .value("Seconds ago", p.secondsAgo),
                                 y: .value(unit, p.value),
                                 series: .value("Series", "\(s.name)#\(p.segment)"))
                            .foregroundStyle(s.color)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round,
                                                   dash: s.dashed ? [5, 3] : []))
                            .interpolationMethod(.linear)
                    }
                }
            }
            .chartLegend(.hidden)
            .chartXScale(domain: -LiveSeries.window...0)
            .chartYScale(domain: domain.range(series.flatMap { $0.points.map(\.value) }))
            .chartXAxis {
                AxisMarks(values: Self.ticks) { v in
                    AxisGridLine()
                    // No label at −5 min: at the left edge it would crowd −4 min.
                    if xLabels, let s = v.as(Double.self), s > -LiveSeries.window {
                        AxisValueLabel(s == 0 ? "now" : "−\(Int(-s) / 60) min", anchor: s == 0 ? .topTrailing : .top)
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine()
                    AxisValueLabel {
                        // Fixed width, so the plot areas of all the charts line up.
                        Text(v.as(Double.self).map(Self.axisLabel) ?? "")
                            .frame(width: Self.yLabelWidth, alignment: .trailing)
                    }
                }
            }
            .frame(minHeight: 50, maxHeight: .infinity)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }
}

private struct LegendChip: View {
    let name: String
    let color: Color
    let dashed: Bool

    var body: some View {
        HStack(spacing: 5) {
            Path { p in
                p.move(to: CGPoint(x: 0, y: 1.5))
                p.addLine(to: CGPoint(x: 16, y: 1.5))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: dashed ? [4, 3] : []))
            .frame(width: 16, height: 3)
            Text(name).font(.caption).foregroundStyle(.secondary)
        }
    }
}
