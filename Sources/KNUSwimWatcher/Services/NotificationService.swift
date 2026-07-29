import Foundation
import UserNotifications

struct NotificationService: Sendable {
    func requestAuthorization() async throws -> Bool {
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            do {
                return try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                // macOS can briefly report an authorization error while the
                // Notifications settings service commits the user's choice.
                try? await Task.sleep(for: .milliseconds(750))
                let refreshed = await center.notificationSettings().authorizationStatus
                if Self.isAuthorized(refreshed) {
                    return true
                }
                throw error
            }
        @unknown default:
            return false
        }
    }

    func send(title: String, body: String) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        try await UNUserNotificationCenter.current().add(request)
    }

    private static func isAuthorized(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return true
        default:
            return false
        }
    }
}
