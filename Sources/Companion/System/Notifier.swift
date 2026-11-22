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
        Task { await post(message) }
    }

    private func post(_ message: String) async {
        let center = UNUserNotificationCenter.current()
        if authorized == nil {
            authorized = (try? await center.requestAuthorization(options: [.alert])) ?? false
        }
        guard authorized == true else { return }
        let content = UNMutableNotificationContent()
        content.title = "Take a breather"
        content.body = message
        let request = UNNotificationRequest(identifier: "tilt-\(UUID().uuidString)", content: content, trigger: nil)
        try? await center.add(request)
    }
}
