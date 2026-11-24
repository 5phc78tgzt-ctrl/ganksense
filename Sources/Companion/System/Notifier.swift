import Foundation
import OSLog
import UserNotifications
import CompanionCore

enum AppLog {
    static let app = Logger(subsystem: AppInfo.bundleID, category: "app")
}

@MainActor
final class Notifier {
    /// false in --demo (and outside an app bundle): nudges are logged instead of posted, so a demo run never
    /// triggers the system permission prompt.
    private let enabled: Bool
    private var authorized: Bool?

    init(enabled: Bool) {
        self.enabled = enabled && Bundle.main.bundleIdentifier != nil
    }

    func notifyTilt(_ message: String) {
        guard enabled else {
            AppLog.app.notice("Tilt nudge: \(message, privacy: .public)")
            return
        }
        Task { await post(title: "Take a breather", body: message, id: "tilt-\(UUID().uuidString)", sound: false) }
    }

    /// a match was found while you were away from the client. one identifier, so a new one replaces the last.
    func notifyMatchFound(accepted: Bool) {
        let body = accepted ? "ganksense accepted it. Champ select starts once everyone accepts."
                            : "Accept it in the League client."
        guard enabled else {
            AppLog.app.notice("Match found: \(body, privacy: .public)")
            return
        }
        Task { await post(title: "Match found", body: body, id: "match-found", sound: true) }
    }

    private func post(title: String, body: String, id: String, sound: Bool) async {
        let center = UNUserNotificationCenter.current()
        if authorized == nil {
            authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        }
        guard authorized == true else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        try? await center.add(request)
    }
}
