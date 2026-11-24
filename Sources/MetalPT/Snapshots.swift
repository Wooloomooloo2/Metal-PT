import AppKit
import MPTApp
import MPTCore
import SwiftUI

/// `MetalPT --render-snapshots DIR`: renders each page and the menu-bar dropdown with fixture data to
/// `DIR/<name>-light.png` and `DIR/<name>-dark.png` (`ImageRenderer`, no Screen Recording permission), then exits.
/// Later tasks add their pages to `shots`.
@MainActor
enum Snapshots {
    static let windowSize = CGSize(width: 1000, height: 680)

    struct Shot {
        let name: String
        /// Height nil: the view's own height.
        let size: CGSize?
        let width: CGFloat
        let view: AnyView
    }

    /// Returns false if any image could not be written.
    static func render(to dir: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("Metal-PT: cannot create \(dir.path): \(error)\n".utf8))
            return false
        }
        var ok = true
        for shot in shots() {
            for (suffix, scheme, appearance) in [("light", ColorScheme.light, NSAppearance.Name.aqua),
                                                 ("dark", .dark, .darkAqua)] {
                let url = dir.appendingPathComponent("\(shot.name)-\(suffix).png")
                if write(shot, scheme: scheme, appearance: appearance, to: url) {
                    print(url.path)
                } else {
                    FileHandle.standardError.write(Data("Metal-PT: could not render \(url.lastPathComponent)\n".utf8))
                    ok = false
                }
            }
        }
        return ok
    }

    // MARK: - Shots

    static func shots() -> [Shot] {
        let following = Fixture.model(.following)
        let idle = Fixture.model(.loggingOff)
        let noGame = Fixture.model(.noGame)
        var list: [Shot] = Page.allCases.map { page in
            Shot(name: page.rawValue, size: windowSize, width: windowSize.width,
                 view: AnyView(WindowFrame(page: page, model: following, hub: following.hub)))
        }
        list.append(Shot(name: "live-nogame", size: windowSize, width: windowSize.width,
                         view: AnyView(WindowFrame(page: .live, model: noGame, hub: noGame.hub))))
        list.append(Shot(name: "live-loggingoff", size: windowSize, width: windowSize.width,
                         view: AnyView(WindowFrame(page: .live, model: idle, hub: idle.hub))))
        list.append(Shot(name: "menu", size: nil, width: MenuBarView.width,
                         view: AnyView(MenuBarView(model: following, hub: following.hub))))
        list.append(Shot(name: "menu-nogame", size: nil, width: MenuBarView.width,
                         view: AnyView(MenuBarView(model: idle, hub: idle.hub))))
        list.append(Shot(name: "menubar-label", size: nil, width: 160,
                         view: AnyView(MenuBarStrip(hub: following.hub))))
        return list
    }

    private static func write(_ shot: Shot, scheme: ColorScheme, appearance: NSAppearance.Name, to url: URL) -> Bool {
        let content = shot.view
            .frame(width: shot.size?.width ?? shot.width, height: shot.size?.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme)
        var data: Data?
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            let r = ImageRenderer(content: content)
            r.scale = 2
            guard let cg = r.cgImage else { return }
            data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        }
        guard let data else { return false }
        do { try data.write(to: url) } catch { return false }
        return true
    }
}

/// The window as the snapshot shows it: a sidebar column drawn like the `List` sidebar (AppKit-backed views such as
/// `NavigationSplitView`/`List` do not render in `ImageRenderer`), a title bar strip, and the real page.
private struct WindowFrame: View {
    let page: Page
    @ObservedObject var model: AppModel
    @ObservedObject var hub: TelemetryHub

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    ForEach([Color.red, .yellow, .green], id: \.self) { c in
                        Circle().fill(c.opacity(0.85)).frame(width: 12, height: 12)
                    }
                }
                .padding(.bottom, 18)
                .padding(.leading, 4)
                ForEach(Page.allCases) { p in
                    HStack(spacing: 8) {
                        Image(systemName: p.symbol).frame(width: 20)
                        Text(p.title)
                    }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(p == page ? Color.secondary.opacity(0.2) : .clear))
                }
                Spacer()
            }
            .padding(12)
            .frame(width: 180)
            .background(Color(nsColor: .underPageBackgroundColor))
            Divider()
            VStack(spacing: 0) {
                HStack {
                    Text(page.title).font(.headline)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .frame(height: 52)
                Divider()
                PageView(page: page, model: model, hub: hub)
            }
        }
    }
}

/// A strip of menu bar with the item's title, to check its width and digits.
private struct MenuBarStrip: View {
    @ObservedObject var hub: TelemetryHub

    var body: some View {
        HStack {
            Spacer()
            MenuBarLabel(hub: hub).font(.system(size: 13))
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
    }
}

// MARK: - Fixture

/// Fixture states: a followed game five minutes into play, recording for 1:23; FPS logging on but no game yet;
/// FPS logging off. All on inert sources.
@MainActor
enum Fixture {
    enum State {
        case following, noGame, loggingOff
    }

    static let game = "HorizonZeroDawnRemastered"
    static let stack = Stack(runtime: "Protium", translator: "FEX", graphics: ["DXMT"])

    /// FPS for second `i`: ~55–60 with a few sharp dips, and a 4 s gap (a loading screen, no frames logged).
    static func fps(_ i: Int) -> Double? {
        if (150..<154).contains(i) { return nil }
        let x = Double(i)
        let dip: Double = [41, 42, 97, 198, 199, 263].contains(i) ? 16 : 0
        return 57.5 + 2 * sin(x / 5) + 0.8 * sin(x * 1.7) - dip
    }

    static func model(_ state: State) -> AppModel {
        let following = state == .following
        let hub = TelemetryHub(dependencies: .inert)
        let t0 = 1_790_000_000.0
        let history = (0..<TelemetryHub.historyLimit).map { i -> HubSnapshot in
            let x = Double(i)
            let load = following ? 1.0 : 0.25
            let sample = TelemetrySample(
                gpuW: (18 + 2 * sin(x / 9)) * load, cpuPUtilPct: (31 + 4 * sin(x / 7)) * load,
                cpuEUtilPct: 12 + 3 * sin(x / 17), cpuCoreMaxPct: 70, gpuBusyPct: following ? 92 + 3 * sin(x / 11) : 8,
                smcPower: ["PSTR": following ? 40 + 2.5 * sin(x / 13) + 0.6 * sin(x * 1.3) : 9 + sin(x / 13)],
                tempMaxC: following ? 72 + 4 * (1 - exp(-x / 60)) + 0.7 * sin(x / 6) : 48 + sin(x / 30),
                tempBatteryC: 33,
                fanRPM: following ? [2900 + 150 * (1 - exp(-x / 80)) + 20 * sin(x / 4),
                                     2850 + 150 * (1 - exp(-x / 80)) + 20 * sin(x / 5)] : [0, 0],
                memUsedGB: 14.2, batteryPct: 80, batteryW: 0.4, onAC: true)
            return HubSnapshot(time: t0 + x, sample: sample,
                               fps: following ? fps(i) : nil,
                               followedPID: following ? 4242 : nil, followedApp: following ? game : nil,
                               stack: following ? stack : nil)
        }
        let model = AppModel(hub: hub, fpsLogging: FPSLogging(launchctl: NoLaunchctl()), live: false,
                             defaults: UserDefaults(suiteName: "metal-pt.snapshots") ?? .standard, env: [:])
        if following {
            let last = history[history.count - 1]
            let fixedLast = HubSnapshot(time: last.time, sample: last.sample, fps: 58.2, followedPID: 4242,
                                        followedApp: game, stack: stack)
            let status = SessionStatus(elapsed: 83, fps: 58.2, followedPID: 4242, followedApp: game, stack: stack,
                                       sample: last.sample, sawFPSSource: true)
            hub.showFixture(history: history, latest: fixedLast, recording: status)
            model.showFixture(recordState: .recording, fpsLoggingOn: true,
                              recentRuns: ["HorizonZeroDawnRemastered 2026-11-23 21.04",
                                           "Cyberpunk2077 2026-11-22 19.40"])
        } else {
            hub.showFixture(history: history)
            model.showFixture(recordState: .idle, fpsLoggingOn: state == .noGame, recentRuns: [],
                              problems: state == .loggingOff
                                  ? ["Overlay hotkey: ⌃⇧F7 is already used by another app"] : [])
        }
        model.overlayOn = following
        return model
    }
}

/// Snapshots never touch the real launchd environment.
private struct NoLaunchctl: LaunchctlRunning {
    func getenv(_ name: String) -> String? { nil }
    func setenv(_ name: String, _ value: String) throws {}
    func unsetenv(_ name: String) throws {}
}
