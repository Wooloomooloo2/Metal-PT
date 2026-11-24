import AppKit
import MPTApp
import SwiftUI

/// Process entry: refuses root, handles `--render-snapshots DIR`, else runs the app.
@main
enum MetalPTMain {
    @MainActor
    static func main() {
        if geteuid() == 0 { refuseRoot() }
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-snapshots") {
            guard i + 1 < args.count else {
                FileHandle.standardError.write(Data("usage: MetalPT --render-snapshots DIR\n".utf8))
                exit(2)
            }
            exit(Snapshots.render(to: URL(fileURLWithPath: args[i + 1], isDirectory: true)) ? 0 : 1)
        }
        MetalPTApp.main()
    }

    @MainActor
    private static func refuseRoot() -> Never {
        let msg = "Metal-PT must not run as root. Quit and open it again as yourself (without sudo)."
        FileHandle.standardError.write(Data("Metal-PT: \(msg)\n".utf8))
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

        MenuBarExtra {
            MenuBarView(model: delegate.model, hub: delegate.model.hub)
        } label: {
            MenuBarLabel(hub: delegate.model.hub)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel(hub: TelemetryHub(), fpsLogging: FPSLogging(), live: true)
    private var signalSources: [DispatchSourceSignal] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The window opens at launch; `MainWindow` switches to .accessory when it closes.
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        NSApp.activate()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.quit()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
