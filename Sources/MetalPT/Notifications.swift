import AppKit
import Foundation
import MPTCore
import UserNotifications

/// One recording notification: its text, and the run it opens when clicked (stop only).
struct RecordingNotice: Equatable {
    let title: String
    let body: String
    let run: URL?

    /// "Recording <app> · <stack line>", or "Recording — no game detected yet".
    static func started(app: String?, stack: Stack?) -> RecordingNotice {
        guard let app, !app.isEmpty else {
            return RecordingNotice(title: "Recording — no game detected yet",
                                   body: "FPS fills in once a game with FPS logging appears.", run: nil)
        }
        return RecordingNotice(title: "Recording \(app) · \(Fmt.stack(stack) ?? "detecting stack")",
                               body: "Press the record hotkey again to stop.", run: nil)
    }

    /// "Run saved — add settings" ("Run saved with problems — see the run" when an error occurred during the run),
    /// with the run's game; clicking it opens the run.
    static func saved(_ run: RunResult, withProblems: Bool = false) -> RecordingNotice {
        RecordingNotice(title: withProblems ? "Run saved with problems — see the run" : "Run saved — add settings",
                        body: gameName(of: run.directory), run: run.directory)
    }

    /// The run's game from its run.json (title, else exe), else the folder name.
    static func gameName(of directory: URL) -> String {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: directory.appendingPathComponent("run.json")),
           let info = try? dec.decode(RunInfo.self, from: data) {
            let name = info.game.title ?? info.game.exe
            if !name.isEmpty { return name }
        }
        return directory.deletingPathExtension().lastPathComponent
    }
}

/// Posts recording notifications and reports clicks on a saved-run notification.
@MainActor
protocol RecordingNotifying: AnyObject {
    /// Called with the run folder when a "Run saved" notification is clicked.
    var onOpenRun: ((URL) -> Void)? { get set }
    /// Asks for permission once (first recording). Recording does not wait for or depend on the answer.
    func requestAuthorizationIfNeeded()
    func post(_ notice: RecordingNotice)
}

/// `UNUserNotificationCenter` in the bundled app. In an unbundled executable (`swift run`) the notification
/// center is unavailable (it raises), so notifications are written to stderr instead.
@MainActor
final class Notifications: NSObject, RecordingNotifying {
    nonisolated static let runKey = "run"

    var onOpenRun: ((URL) -> Void)?
    private var askedForAuthorization = false
    private let center: UNUserNotificationCenter?

    override init() {
        center = Bundle.main.bundleIdentifier != nil ? UNUserNotificationCenter.current() : nil
        super.init()
        center?.delegate = self
    }

    func requestAuthorizationIfNeeded() {
        guard !askedForAuthorization else { return }
        askedForAuthorization = true
        guard let center else {
            log("notifications unavailable (unbundled executable); logging them here")
            return
        }
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if !granted {
                let why = error.map { ": \($0.localizedDescription)" } ?? ""
                try? FileHandle.standardError.write(contentsOf: Data("Metal-PT: notifications not allowed\(why)\n".utf8))
            }
        }
    }

    func post(_ notice: RecordingNotice) {
        guard let center else {
            log("notification: \(notice.title) — \(notice.body)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        if let run = notice.run { content.userInfo = [Self.runKey: run.path] }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request) { error in
            // Denied permission lands here; the recording is unaffected.
            if let error {
                try? FileHandle.standardError.write(contentsOf: Data("Metal-PT: notification not shown: \(error.localizedDescription)\n".utf8))
            }
        }
    }

    private func log(_ text: String) {
        try? FileHandle.standardError.write(contentsOf: Data("Metal-PT: \(text)\n".utf8))
    }
}

extension Notifications: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler:
                                                @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let path = response.notification.request.content.userInfo[Self.runKey] as? String
        completionHandler()
        guard let path, response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.onOpenRun?(URL(fileURLWithPath: path, isDirectory: true)) }
        }
    }
}
