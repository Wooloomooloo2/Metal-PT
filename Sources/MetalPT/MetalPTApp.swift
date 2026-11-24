import AppKit
import MPTApp
import MPTCore
import SwiftUI

/// Process entry: refuses root, handles `--render-snapshots DIR`, else runs the app.
@main
enum MetalPTMain {
    @MainActor
    static func main() {
        if geteuid() == 0 { refuseRoot() }
        // A closed stderr (launched from a terminal that went away) must not kill the app on a log write. Children
        // (`log`, `launchctl`, `ps`) are started by Foundation's Process, which resets signal dispositions.
        signal(SIGPIPE, SIG_IGN)
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-snapshots") {
            guard i + 1 < args.count else {
                try? FileHandle.standardError.write(contentsOf: Data("usage: MetalPT --render-snapshots DIR\n".utf8))
                exit(2)
            }
            exit(Snapshots.render(to: URL(fileURLWithPath: args[i + 1], isDirectory: true)) ? 0 : 1)
        }
        MetalPTApp.main()
    }

    @MainActor
    private static func refuseRoot() -> Never {
        let msg = "Metal-PT must not run as root. Quit and open it again as yourself (without sudo)."
        try? FileHandle.standardError.write(contentsOf: Data("Metal-PT: \(msg)\n".utf8))
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.activate()
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Metal-PT must not run as root"
        alert.informativeText = "Quit and open it again as yourself (without sudo). Metal-PT never needs "
            + "administrator rights."
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        exit(1)
    }
}

struct MetalPTApp: App {
    static let mainWindowID = "main"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Metal-PT", id: Self.mainWindowID) {
            MainWindow(model: delegate.model, hub: delegate.model.hub)
        }
        .defaultSize(width: 1000, height: 680)
        // Not opened by SwiftUI: `AppDelegate` opens it at launch unless macOS opened Metal-PT as a login item.
        .defaultLaunchBehavior(.suppressed)

        MenuBarExtra {
            MenuBarView(model: delegate.model, hub: delegate.model.hub)
        } label: {
            MenuBarLabel(hub: delegate.model.hub)
                .background(OpenWindowRegistrar(model: delegate.model))
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel(hub: TelemetryHub(), fpsLogging: FPSLogging(), live: true)
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Read while the launch's 'oapp' event is still the current Apple event (see `LaunchKind`).
        let event = NSAppleEventManager.shared().currentAppleEvent
        let asLoginItem = LaunchKind.isLoginItemLaunch(event)
        let bundle = Bundle.main.bundleIdentifier ?? "none (unbundled executable)"
        try? FileHandle.standardError.write(contentsOf: Data(("Metal-PT: launched \(MetalPTVersion.current); bundle \(bundle); "
            + "login item \(LoginItem.describeAtLaunch()); "
            + "\(asLoginItem ? "opened as a login item: menu bar only" : "opening the window") "
            + "(\(LaunchKind.describe(event)))\n").utf8))
        // Dock icon only while the main window is open (`AppModel.mainWindowOpened`/`Closed`).
        NSApp.setActivationPolicy(asLoginItem ? .accessory : .regular)
        model.launch()
        // SIGINT (Ctrl-C under `swift run`), SIGTERM and SIGHUP (terminal closed) quit through `terminate`, so the
        // quit path runs (variables handed back, recording finished).
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { NSApp.terminate(nil) }
            src.resume()
            signalSources.append(src)
        }
        if !asLoginItem { model.showMainWindow() }
        DispatchQueue.global(qos: .utility).async {
            // A `log stream` left by a crashed Metal-PT (see `OrphanedLogStreams`).
            let ended = OrphanedLogStreams.terminateAll()
            if !ended.isEmpty {
                try? FileHandle.standardError.write(contentsOf: Data(
                    "Metal-PT: ended leftover log stream(s) \(ended.map(String.init).joined(separator: ", "))\n".utf8))
            }
            // The host names the privacy scrub needs, computed once here rather than under a lock at the first scrub.
            Privacy.prime()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.quit()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
