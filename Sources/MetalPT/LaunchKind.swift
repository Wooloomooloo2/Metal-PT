import AppKit
import SwiftUI

/// How this launch happened. A login item (SMAppService.mainApp, Settings → "Open at login") is opened by macOS with
/// the 'oapp' Apple event carrying `keyAEPropData` = `keyAELaunchedAsLogInItem`; `AppDelegate` reads it from
/// `NSAppleEventManager.currentAppleEvent` in `applicationDidFinishLaunching` (which runs while that event is being
/// handled). Such a launch starts in the menu bar only; any other launch (Finder, Dock, `open`, `swift run`) opens
/// the main window.
enum LaunchKind {
    static func isLoginItemLaunch(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let event, event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
            == OSType(keyAELaunchedAsLogInItem)
    }

    /// For the launch log line.
    static func describe(_ event: NSAppleEventDescriptor?) -> String {
        guard let event else { return "no launch event" }
        let prop = event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
        return "event \(fourCC(event.eventClass))/\(fourCC(event.eventID))" + (prop.map { " prop \(fourCC($0))" } ?? "")
    }

    private static func fourCC(_ code: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Placed in the menu-bar label (which exists from launch, unlike the main window): gives the model a way to open
/// the main window before the window has ever appeared (a launch, a notification click).
struct OpenWindowRegistrar: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                let open = openWindow
                model.openMainWindow = { open(id: MetalPTApp.mainWindowID) }
            }
    }
}
