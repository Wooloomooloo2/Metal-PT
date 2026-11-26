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
        /// The overlay is always dark: one image, `<name>.png`.
        var appearanceIndependent = false
    }

    /// Returns false if any image could not be written.
    static func render(to dir: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data("Metal-PT: cannot create \(dir.path): \(error)\n".utf8))
            return false
        }
        var ok = true
        for shot in shots() {
            let variants: [(String, ColorScheme, NSAppearance.Name)] = shot.appearanceIndependent
                ? [("", .dark, .darkAqua)]
                : [("-light", .light, .aqua), ("-dark", .dark, .darkAqua)]
            for (suffix, scheme, appearance) in variants {
                let url = dir.appendingPathComponent("\(shot.name)\(suffix).png")
                if write(shot, scheme: scheme, appearance: appearance, to: url) {
                    print(url.path)
                } else {
                    try? FileHandle.standardError.write(contentsOf: Data("Metal-PT: could not render \(url.lastPathComponent)\n".utf8))
                    ok = false
                }
            }
        }
        Fixture.removeRuns()
        Fixture.removeDefaults()
        return ok
    }

    // MARK: - Shots

    static func shots() -> [Shot] {
        let following = Fixture.model(.following)
        let idle = Fixture.model(.loggingOff)
        let noGame = Fixture.model(.noGame)
        var list: [Shot] = Page.allCases.filter { $0 != .runs && $0 != .compare && $0 != .settings }.map { page in
            Shot(name: page.rawValue, size: windowSize, width: windowSize.width,
                 view: AnyView(WindowFrame(page: page, model: following, hub: following.hub)))
        }
        list += runsShots()
        list += compareShots()
        list.append(Shot(name: "live-nogame", size: windowSize, width: windowSize.width,
                         view: AnyView(WindowFrame(page: .live, model: noGame, hub: noGame.hub))))
        list.append(Shot(name: "live-loggingoff", size: windowSize, width: windowSize.width,
                         view: AnyView(WindowFrame(page: .live, model: idle, hub: idle.hub))))
        let notReporting = Fixture.model(.noGame, suite: "fixture-notreporting")
        notReporting.showFixture(recordState: .idle, fpsLoggingOn: true, recentRuns: [],
                                 frameReportingWarning: Fixture.notReportingWarning)
        list.append(Shot(name: "live-notreporting", size: windowSize, width: windowSize.width,
                         view: AnyView(WindowFrame(page: .live, model: notReporting, hub: notReporting.hub))))
        list.append(Shot(name: "menu", size: nil, width: MenuBarView.width,
                         view: AnyView(MenuBarView(model: following, hub: following.hub))))
        list.append(Shot(name: "menu-nogame", size: nil, width: MenuBarView.width,
                         view: AnyView(MenuBarView(model: idle, hub: idle.hub))))
        list.append(Shot(name: "menu-notreporting", size: nil, width: MenuBarView.width,
                         view: AnyView(MenuBarView(model: notReporting, hub: notReporting.hub))))
        list += menuBarLabelShots()
        list += overlayShots()
        list += settingsShots()
        return list
    }

    /// The menu-bar label: following a game (not recording), recording (red "● 01:23 · 58 fps"), starting, saving.
    private static func menuBarLabelShots() -> [Shot] {
        let following = Fixture.model(.following)
        following.showFixture(recordState: .idle, fpsLoggingOn: true, recentRuns: [])
        let recording = Fixture.model(.following)
        let starting = Fixture.model(.loggingOff)
        starting.showFixture(recordState: .starting, fpsLoggingOn: true, recentRuns: [])
        let saving = Fixture.model(.following)
        saving.showFixture(recordState: .saving, fpsLoggingOn: true, recentRuns: [])
        return [("menubar-label", following), ("menubar-recording", recording), ("menubar-starting", starting),
                ("menubar-saving", saving)].map { name, model in
            Shot(name: name, size: nil, width: 200, view: AnyView(MenuBarStrip(model: model)))
        }
    }

    /// Settings: defaults (unbundled, so launch at login is off with its note); recording the Record hotkey with a
    /// refused combo on Overlay; and the data folder locked by `MPT_DATA_ROOT` with an FPS-logging failure.
    private static func settingsShots() -> [Shot] {
        let plain = Fixture.model(.loggingOff, suite: "settings")
        plain.showFixture(recordState: .idle, fpsLoggingOn: true, recentRuns: [], notificationStatus: .unavailable)
        let allowed = Fixture.model(.loggingOff, suite: "settings-notify-allowed")
        allowed.showFixture(recordState: .idle, fpsLoggingOn: true, recentRuns: [], notificationStatus: .allowed)
        let denied = Fixture.model(.loggingOff, suite: "settings-notify-denied")
        denied.defaults.set(false, forKey: SettingsKey.soundOnRecord)
        denied.showFixture(recordState: .idle, fpsLoggingOn: true, recentRuns: [], notificationStatus: .denied)
        let recording = Fixture.model(.loggingOff, suite: "settings-hotkey")
        recording.defaults.set("⌃⌥R", forKey: SettingsKey.hotkeyOverlay)
        recording.defaults.set(OverlayStyle.detailed.rawValue, forKey: SettingsKey.overlayStyle)
        recording.defaults.set(OverlayCorner.bottomRight.rawValue, forKey: SettingsKey.overlayCorner)
        recording.defaults.set(0.35, forKey: SettingsKey.overlayOpacity)
        let locked = Fixture.model(.loggingOff, suite: "settings-envlocked",
                                   env: ["MPT_DATA_ROOT": "/tmp/mpt-dev-data"])
        locked.showFixture(recordState: .idle, fpsLoggingOn: false, recentRuns: [],
                           fpsLoggingError: "\(FPSLoggingError.commandFailed(operation: "setenv", name: "MTL_HUD_ENABLED", status: 1))")
        // Taller than the window: the whole form (it scrolls in the app).
        func shot(_ name: String, _ model: AppModel, _ page: SettingsPage) -> Shot {
            Shot(name: name, size: CGSize(width: windowSize.width, height: 1200), width: windowSize.width,
                 view: AnyView(WindowFrame(page: .settings, model: model, hub: model.hub) { page }))
        }
        return [
            shot("settings", plain, SettingsPage(model: plain)),
            shot("settings-notify-allowed", allowed, SettingsPage(model: allowed)),
            shot("settings-notify-denied", denied, SettingsPage(model: denied)),
            shot("settings-hotkey", recording,
                 SettingsPage(model: recording, recordingField: .record,
                              hotkeyMessages: [.overlay: "⌃⇧F6 is already the Record hotkey"])),
            shot("settings-envlocked", locked, SettingsPage(model: locked)),
        ]
    }

    /// Runs with three fixture bundles (two ticked for comparison), the edit sheet, and the empty folder.
    private static func runsShots() -> [Shot] {
        let withRuns = Fixture.model(.loggingOff)
        let runsRoot = Fixture.makeRuns()
        withRuns.runs.showFixture(root: runsRoot)
        // The second run is on the website (its row shows the published mark).
        if withRuns.runs.entries.count > 1 {
            try? SiteRecord(id: "k3v9q2x7mp", url: URL(string: "https://metal-pt.com/run/k3v9q2x7mp")!)
                .write(to: runsRoot.appendingPathComponent(withRuns.runs.entries[1].id))
            withRuns.runs.showFixture(root: runsRoot)
        }
        let ids = withRuns.runs.entries.map(\.id)
        let recording = Fixture.model(.loggingOff)
        recording.runs.showFixture(root: Fixture.makeRuns(recording: true))
        let empty = Fixture.model(.loggingOff)
        empty.runs.showFixture(root: Fixture.emptyRunsRoot())
        var list = [
            Shot(name: "runs", size: windowSize, width: windowSize.width,
                 view: AnyView(WindowFrame(page: .runs, model: withRuns, hub: withRuns.hub) {
                     RunsPage(model: withRuns, ticked: Set(ids.prefix(2)))
                 })),
            Shot(name: "runs-filtered", size: windowSize, width: windowSize.width,
                 view: AnyView(WindowFrame(page: .runs, model: withRuns, hub: withRuns.hub) {
                     RunsPage(model: withRuns, filter: "crossover")
                 })),
            Shot(name: "runs-recording", size: windowSize, width: windowSize.width,
                 view: AnyView(WindowFrame(page: .runs, model: recording, hub: recording.hub))),
            Shot(name: "runs-empty", size: windowSize, width: windowSize.width,
                 view: AnyView(WindowFrame(page: .runs, model: empty, hub: empty.hub))),
        ]
        if let first = withRuns.runs.entries.first {
            var graded = first
            graded.graphics = .init(preset: .high, width: 2560, height: 1440, upscaler: .metalfx,
                                    upscalerMode: .quality, frameGeneration: false)
            list.append(Shot(name: "runs-edit", size: nil, width: 480,
                             view: AnyView(EditNotesSheet(
                                entry: graded, store: withRuns.runs,
                                fields: .init(label: first.label, gameSettings: first.settings,
                                              notes: "Mountain path loop from the Mother's Heart save.\n"
                                                + "Fans audible after ~90 s.",
                                              videoURL: "https://youtu.be/dQw4w9WgXcQ")))))
            list.append(Shot(name: "runs-edit-bad-video", size: nil, width: 480,
                             view: AnyView(EditNotesSheet(
                                entry: first, store: withRuns.runs,
                                fields: .init(label: first.label, gameSettings: first.settings, notes: "",
                                              videoURL: "https://youtube.com.evil.com/watch?v=dQw4w9WgXcQ")))))
            // Submit with the notes left out, and ticked in.
            if let url = withRuns.runs.url(of: first.id), var info = try? RunBundle.load(url, frames: false).info {
                info.user.notes = "Mountain path loop from the Mother's Heart save."
                info.settings = .init(powerMode: "High", onACAtStart: true, displayWidth: 3456, displayHeight: 2234,
                                      refreshHz: 120)
                info.warnings = ["recording spanned a sleep"]
                try? RunBundleWriter.writeInfo(info, to: url)
            }
            if let url = withRuns.runs.url(of: first.id), let b = try? RunBundle.load(url, frames: false) {
                let previews = (withoutNotes: RunExport.preview(b, includeNotes: false),
                                withNotes: RunExport.preview(b, includeNotes: true))
                var ready = first
                ready.graphics = .init(preset: .high, width: 2560, height: 1440, upscaler: .metalfx,
                                       upscalerMode: .quality, frameGeneration: false)
                var partial = first
                partial.graphics = .init(preset: .high, upscaler: .fsr)
                let page = URL(string: "https://metal-pt.com/run/k3v9q2x7mp")!
                let video = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
                let states: [(String, RunEntry, Bool, String?, SubmitSheet.Phase, Bool)] = [
                    ("runs-submit", ready, false, video, .editing, false),
                    ("runs-submit-notes", ready, true, nil, .editing, false),
                    ("runs-submit-missing", partial, false, nil, .editing, true),
                    ("runs-submit-publishing", ready, false, video, .publishing, false),
                    ("runs-submit-published", ready, false, video,
                     .published(.init(id: "k3v9q2x7mp", url: page,
                                      notice: "Published without the video link: that video is private.")), false),
                    ("runs-submit-already", ready, false, nil,
                     .published(.init(id: "k3v9q2x7mp", url: page, alreadyPublished: true)), false),
                    ("runs-submit-error", ready, false, nil,
                     .failed("A run needs at least 60 seconds of steady play with a frame rate; this one has 42."), false),
                    ("runs-submit-offline", ready, false, nil, .failed(SiteError.offline.message), false),
                ]
                for (name, entry, include, link, phase, missing) in states {
                    list.append(Shot(name: name, size: nil, width: 560,
                                     view: AnyView(SubmitSheet(entry: entry, store: withRuns.runs,
                                                               exportsFolder: URL(fileURLWithPath: "/tmp/exports"),
                                                               previews: previews, includeNotes: include,
                                                               videoURL: link, phase: phase, showMissing: missing))))
                }
                // Over the site's 90-minute cap: Publish disabled with the reason.
                var long = previews
                let reason = PublishLimits.Refusal.tooLong(seconds: 5820).localizedDescription
                long.withoutNotes.publishRefusal = reason
                long.withNotes.publishRefusal = reason
                list.append(Shot(name: "runs-submit-too-long", size: nil, width: 560,
                                 view: AnyView(SubmitSheet(entry: ready, store: withRuns.runs,
                                                           exportsFolder: URL(fileURLWithPath: "/tmp/exports"),
                                                           previews: long, videoURL: video, phase: .editing))))
                // A release build before metal-pt.com is live: export only.
                list.append(Shot(name: "runs-submit-export-only", size: nil, width: 560,
                                 view: AnyView(SubmitSheet(entry: ready, store: withRuns.runs,
                                                           exportsFolder: URL(fileURLWithPath: "/tmp/exports"),
                                                           previews: long, phase: .editing, publishing: false))))
            }
        }
        // A run of an emulator, named after the game: list row, header and the edit sheet's Game field.
        let titled = Fixture.model(.loggingOff)
        titled.runs.showFixture(root: Fixture.makeTitledRuns())
        list.append(Shot(name: "runs-titled", size: windowSize, width: windowSize.width,
                         view: AnyView(WindowFrame(page: .runs, model: titled, hub: titled.hub))))
        if let sotc = titled.runs.entries.first {
            list.append(Shot(name: "runs-edit-title", size: nil, width: 480,
                             view: AnyView(EditNotesSheet(
                                entry: sotc, store: titled.runs,
                                fields: .init(label: sotc.label, gameSettings: sotc.settings,
                                              notes: "Forbidden lands, first colossus.")))))
        }
        return list
    }

    /// Compare with two fixture projects (one with a trashed run), the add-runs and rename sheets, and no projects.
    private static func compareShots() -> [Shot] {
        let model = Fixture.model(.loggingOff)
        let (runsRoot, projectsRoot) = Fixture.makeProjects()
        model.runs.showFixture(root: runsRoot)
        model.projects.showFixture(projectsRoot: projectsRoot, runsRoot: runsRoot)
        let empty = Fixture.model(.loggingOff)
        empty.projects.showFixture(projectsRoot: Fixture.emptyRunsRoot().deletingLastPathComponent()
                                    .appendingPathComponent("projects"), runsRoot: Fixture.emptyRunsRoot())
        var list = [
            Shot(name: "compare", size: windowSize, width: windowSize.width,
                 view: AnyView(WindowFrame(page: .compare, model: model, hub: model.hub) {
                     ComparePage(model: model, selection: Fixture.stacksProject)
                 })),
            Shot(name: "compare-empty", size: windowSize, width: windowSize.width,
                 view: AnyView(WindowFrame(page: .compare, model: empty, hub: empty.hub))),
        ]
        if let detail = model.projects.details[Fixture.stacksProject] {
            let candidates = model.projects.candidates(detail.id, from: model.runs.entries)
            list.append(Shot(name: "compare-add", size: nil, width: 520,
                             view: AnyView(AddRunsSheet(detail: detail, store: model.projects, runs: model.runs,
                                                        ticked: Set(candidates.prefix(1).map(\.id)),
                                                        candidates: candidates, makeBaseline: true,
                                                        onAdd: { _, _ in }))))
            list.append(Shot(name: "compare-add-search", size: nil, width: 520,
                             view: AnyView(AddRunsSheet(detail: detail, store: model.projects, runs: model.runs,
                                                        ticked: Set(candidates.prefix(1).map(\.id)),
                                                        candidates: candidates, filter: "CrossOver",
                                                        onAdd: { _, _ in }))))
        }
        list.append(Shot(name: "compare-rename", size: nil, width: 420,
                         view: AnyView(RenameProjectSheet(
                            name: "HZD stacks", edited: "Runs comparison",
                            problem: CompareProjectError.fileHoldsOther(file: "runs-comparison.json",
                                                                       project: "Runs comparison").errorDescription,
                            onSave: { _ in }))))
        return list
    }

    /// The overlay over a game-like background: compact (not recording), compact style while recording, and the
    /// detailed panel (auto style while recording).
    private static func overlayShots() -> [Shot] {
        let notRecording = Fixture.model(.following)
        notRecording.showFixture(recordState: .idle, fpsLoggingOn: true, recentRuns: [])
        let recording = Fixture.model(.following)
        let cases: [(String, AppModel, OverlayStyle, OverlayCorner)] = [
            ("overlay-compact", notRecording, .auto, .topLeft),
            ("overlay-compact-recording", recording, .compact, .topLeft),
            ("overlay-detailed-recording", recording, .auto, .topLeft),
            ("overlay-detailed-bottomright", recording, .detailed, .bottomRight),
        ]
        return cases.map { name, model, style, corner in
            let defaults = Fixture.defaults(name)
            defaults.set(style.rawValue, forKey: SettingsKey.overlayStyle)
            defaults.set(OverlayDefaults.opacity, forKey: SettingsKey.overlayOpacity)
            return Shot(name: name, size: CGSize(width: 520, height: 300), width: 520,
                        view: AnyView(OverlayOnGame(corner: corner) {
                            OverlayView(model: model, hub: model.hub).defaultAppStorage(defaults)
                        }),
                        appearanceIndependent: true)
        }
    }

    private static func write(_ shot: Shot, scheme: ColorScheme, appearance: NSAppearance.Name, to url: URL) -> Bool {
        let content = shot.view
            .frame(width: shot.size?.width ?? shot.width, height: shot.size?.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme)
            .environment(\.rendersSnapshot, true)
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
    /// The page's view when it needs fixture arguments; nil: `PageView`.
    var content: AnyView?

    init(page: Page, model: AppModel, hub: TelemetryHub) {
        self.page = page; self.model = model; self.hub = hub
    }

    init<C: View>(page: Page, model: AppModel, hub: TelemetryHub, @ViewBuilder content: () -> C) {
        self.page = page; self.model = model; self.hub = hub
        self.content = AnyView(content())
    }

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
                if let content { content } else { PageView(page: page, model: model, hub: hub) }
            }
        }
    }
}

/// A stand-in game frame (the mockup's gradient, with a bright patch to check legibility) with the overlay in a
/// corner, inset as on screen.
private struct OverlayOnGame<Content: View>: View {
    let corner: OverlayCorner
    @ViewBuilder let content: Content

    var body: some View {
        let alignment: Alignment = switch corner {
        case .topLeft: .topLeading
        case .topRight: .topTrailing
        case .bottomLeft: .bottomLeading
        case .bottomRight: .bottomTrailing
        }
        ZStack(alignment: alignment) {
            LinearGradient(colors: [Color(red: 0.23, green: 0.29, blue: 0.16), Color(red: 0.48, green: 0.42, blue: 0.23),
                                    Color(red: 0.85, green: 0.86, blue: 0.80), Color(red: 0.16, green: 0.23, blue: 0.29)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            content.padding(OverlayCorner.inset)
        }
    }
}

/// A strip of menu bar with the item's title, to check its width and digits.
private struct MenuBarStrip: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack {
            Spacer()
            MenuBarLabel(model: model, hub: model.hub).font(.system(size: 13))
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
    static let notReportingWarning =
        "Cyberpunk2077 started before FPS logging was on — quit it and Steam and open them again."

    /// FPS for second `i`: ~55–60 with a few sharp dips, and a 4 s gap (a loading screen, no frames logged).
    static func fps(_ i: Int) -> Double? {
        if (150..<154).contains(i) { return nil }
        let x = Double(i)
        let dip: Double = [41, 42, 97, 198, 199, 263].contains(i) ? 16 : 0
        return 57.5 + 2 * sin(x / 5) + 0.8 * sin(x * 1.7) - dip
    }

    /// In-memory defaults for one fixture: nothing reaches cfprefsd, so no plist is left behind.
    static func defaults(_ name: String) -> UserDefaults {
        if let d = memory[name] { return d }
        let d = MemoryDefaults()
        memory[name] = d
        return d
    }

    private static var memory: [String: MemoryDefaults] = [:]

    /// Removes the suites earlier versions persisted (`metal-pt.snapshots*`).
    static func removeDefaults() {
        memory.removeAll()
        // Plus the single suite earlier versions left behind.
        let prefs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences")
        let legacy = ["", ".overlay-compact", ".overlay-compact-recording", ".overlay-detailed-recording",
                      ".overlay-detailed-bottomright", ".settings", ".settings-hotkey", ".settings-envlocked",
                      ".fixture"].map { "metal-pt.snapshots\($0)" }
        for suite in legacy {
            UserDefaults().removePersistentDomain(forName: suite)
            CFPreferencesAppSynchronize(suite as CFString)
            // cfprefsd empties the domain but leaves its (empty) plist behind.
            try? FileManager.default.removeItem(at: prefs.appendingPathComponent("\(suite).plist"))
        }
    }

    static func model(_ state: State, suite: String = "fixture", env: [String: String] = [:]) -> AppModel {
        let following = state == .following
        let hub = TelemetryHub(dependencies: .inert)
        let t0 = 1_790_000_000.0
        let history = (0..<TelemetryHub.historyLimit).map { i -> HubSnapshot in
            let x = Double(i)
            let load = following ? 1.0 : 0.25
            let sample = TelemetrySample(
                gpuW: (18 + 2 * sin(x / 9)) * load, cpuPUtilPct: (31 + 4 * sin(x / 7)) * load,
                cpuEUtilPct: 12 + 3 * sin(x / 17), cpuCoreMaxPct: 70, gpuBusyPct: following ? 97 + 2.5 * sin(x / 11) : 8,
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
                             defaults: defaults(suite), env: env)
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
                              hotkeyRegistration: state == .loggingOff
                                  ? [.overlay: "⌃⇧F7 is already used by another app"] : [:])
        }
        model.overlayOn = following
        return model
    }
}

// MARK: - Fixture runs

extension Fixture {
    /// The temporary folder holding fixture run bundles (removed after rendering).
    private static var runsTemp: URL?

    private static func tempRoot() -> URL {
        if let runsTemp { return runsTemp }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("metal-pt-snapshots-\(UUID().uuidString)")
        runsTemp = url
        return url
    }

    static func emptyRunsRoot() -> URL {
        let url = tempRoot().appendingPathComponent("empty/runs")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Three finished runs written by the real bundle writer: two of the same game on different stacks (today), one
    /// of another game (yesterday). Two minutes or three, 1 Hz rows and per-frame times.
    /// `recording`: a separate folder whose newest run is still being written (no end, samples just now).
    static func makeRuns(recording: Bool = false, folder: String? = nil) -> URL {
        let root = tempRoot().appendingPathComponent(folder ?? (recording ? "recording/runs" : "runs"))
        let cases: [RunCase] = [
            ("HorizonZeroDawnRemastered.exe", Stack(runtime: "Protium", runtimeVersion: "0.3.1", translator: "FEX",
                                                    graphics: ["DXMT"]),
             "High, 1440p, FSR off", "Mountain path", 2 * 3600, 120, 58.1, true),
            ("HorizonZeroDawnRemastered.exe", Stack(runtime: "CrossOver", runtimeVersion: "25.1",
                                                    graphics: ["D3DMetal"]),
             "High, 1440p, FSR off", "Mountain path", 2 * 3600 + 21 * 60, 120, 52.6, false),
            ("Cyberpunk2077.exe", Stack(runtime: "CrossOver", runtimeVersion: "25.1", graphics: ["D3DMetal"]),
             "Medium", "", 26 * 3600, 180, 41.0, true),
        ]
        write(cases, in: root, recording: recording)
        return root
    }

    typealias RunCase = (exe: String, stack: Stack, settings: String, label: String, ago: Double, seconds: Int,
                         fps: Double, frames: Bool)

    /// Runs recorded from a PS2 emulator, named by the user: "Shadow of the Colossus" (newest) and "Ico" on ARMSX2,
    /// so the edit sheet has an earlier title to suggest.
    static func makeTitledRuns() -> URL {
        let root = tempRoot().appendingPathComponent("titled/runs")
        let stack = Stack(runtime: "Native")
        write([("ARMSX2", stack, "3× native, 60 fps patch", "Agro ride", 3600, 120, 59.4, true),
               ("ARMSX2", stack, "3× native", "", 30 * 3600, 120, 60.0, true)],
              titles: ["Shadow of the Colossus", "Ico"], in: root, recording: false)
        return root
    }

    private static func write(_ cases: [RunCase], titles: [String?] = [], in root: URL, recording: Bool) {
        let now = Date()
        for (n, c) in cases.enumerated() {
            let start = now.addingTimeInterval(-c.ago)
            let dir = RunBundle.availableDirectory(in: root, start: start, game: c.exe)
            let info = RunInfo(appVersion: AppModel.appVersion,
                               machine: .init(modelID: "Mac16,5", chip: "Apple M4 Max", gpuCores: 40, memoryGB: 48,
                                              osVersion: "26.1", osBuild: "25B78"),
                               game: .init(exe: c.exe, title: n < titles.count ? titles[n] : nil), stack: c.stack,
                               user: .init(label: c.label, gameSettings: c.settings), start: start,
                               fpsSource: "log")
            guard let w = try? RunBundleWriter(directory: dir, info: info) else { continue }
            for i in 1...c.seconds {
                let x = Double(i)
                let fps = c.fps + 1.5 * sin(x / 6) + 0.6 * sin(x * 1.3)
                try? w.append(sample: ["elapsed_s": "\(i)", "fps": String(format: "%.1f", fps),
                                       "fps_app": c.exe, "smc_PSTR_w": String(format: "%.1f", 38 + sin(x / 9))])
            }
            if c.frames {
                let interval = 1000 / c.fps
                let n = Int(Double(c.seconds) * c.fps)
                let frames = (0..<n).map { k in
                    FrameTime(intervalMs: k % 90 == 0 ? interval * 1.6 : interval, presentDelayMs: 2)
                }
                try? w.append(frames: frames, endingAtMs: Double(c.seconds) * 1000)
            }
            if recording && n == 0 { continue }   // left open: in progress
            try? w.finish { $0.end = start.addingTimeInterval(Double(c.seconds)) }
        }
    }

    /// The Compare fixture's project shown in the detail.
    static let stacksProject = "hzd-stacks.json"

    /// The three fixture runs in their own folder and two projects: "Runs comparison" (all three, baseline run 2)
    /// and, newer, "HZD stacks" (the Protium run against a Whisky run since moved to the Trash).
    static func makeProjects() -> (runs: URL, projects: URL) {
        let runs = makeRuns(folder: "compare/runs")
        let projects = runs.deletingLastPathComponent().appendingPathComponent("projects")
        let ids = RunIndex(root: runs).entries().sorted { $0.start < $1.start }.map(\.id)   // CP, HZD CrossOver, HZD Protium
        guard ids.count == 3 else { return (runs, projects) }
        let all = CompareProject(name: "Runs comparison", baseline: 1, runs: ids.map { .init(bundle: $0) })
        let stacks = CompareProject(name: "HZD stacks", baseline: 0,
                                    runs: [.init(bundle: ids[2]),
                                           .init(bundle: "2026-11-20-hzd-whisky.mptrun", name: "Whisky 2.3")])
        let allURL = projects.appendingPathComponent(CompareProject.fileName(for: all.name))
        try? all.save(to: allURL)
        try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-26 * 3600)],
                                               ofItemAtPath: allURL.path)
        try? stacks.save(to: projects.appendingPathComponent(stacksProject))
        return (runs, projects)
    }

    static func removeRuns() {
        if let runsTemp { try? FileManager.default.removeItem(at: runsTemp) }
        runsTemp = nil
    }
}

/// Snapshots never touch the real launchd environment.
private struct NoLaunchctl: LaunchctlRunning {
    func getenv(_ name: String) -> String? { nil }
    func setenv(_ name: String, _ value: String) throws {}
    func unsetenv(_ name: String) throws {}
}
