import AppKit
import Foundation
import UserNotifications

// MARK: - Sounds (spec §A)

/// The short system sound played when a recording starts or stops (Settings → "Play a sound…").
enum RecordSound: Equatable {
    case start, stop

    /// A system sound name (`/System/Library/Sounds`).
    var name: String {
        switch self {
        case .start: "Tink"
        case .stop: "Pop"
        }
    }
}

@MainActor
protocol SoundPlaying: AnyObject {
    func play(_ sound: RecordSound)
}

/// `NSSound(named:)`: the system sounds, played asynchronously.
@MainActor
final class SystemSounds: SoundPlaying {
    func play(_ sound: RecordSound) {
        NSSound(named: NSSound.Name(sound.name))?.play()
    }
}

// MARK: - Notification permission (spec §C)

/// Whether macOS lets Metal-PT show notifications, for Settings.
enum NotificationStatus: Equatable, Sendable {
    case allowed
    case denied
    /// Metal-PT has not asked yet (it asks at the first recording).
    case notAsked
    /// Unbundled executable (`swift run`): there is no notification center.
    case unavailable

    var text: String {
        switch self {
        case .allowed: "Allowed"
        case .denied: "Not allowed — turn on in System Settings"
        case .notAsked: "Not asked yet"
        case .unavailable: "Available in the installed app"
        }
    }

    /// System Settings → Notifications → Metal-PT.
    static let settingsURL = URL(string:
        "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=io.github.wooloomooloo2.metal-pt")!
}

protocol NotificationStatusProviding: Sendable {
    func status() async -> NotificationStatus
}

/// `UNUserNotificationCenter.notificationSettings()` in the bundled app; `.unavailable` unbundled (the center raises
/// there).
struct SystemNotificationStatus: NotificationStatusProviding {
    let bundled: Bool

    init(bundled: Bool = Bundle.main.bundleIdentifier != nil) { self.bundled = bundled }

    func status() async -> NotificationStatus {
        guard bundled else { return .unavailable }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .allowed
        case .denied: return .denied
        case .notDetermined: return .notAsked
        @unknown default: return .notAsked
        }
    }
}
