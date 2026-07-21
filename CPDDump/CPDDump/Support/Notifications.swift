import UIKit
import UserNotifications

/// Notifications, the no-guilt way: ask for permission only after the first
/// successful dump, push "ready to review" with a deep link, badge the icon
/// with the awaiting count, and locally announce background upload failures.
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private var center: UNUserNotificationCenter { .current() }

    /// The morning gem's "Got it — don't show again" action.
    private nonisolated static let morningGemDoneAction = "MORNING_GEM_DONE"

    /// Called once at launch.
    func bootstrap() {
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: "MORNING_GEM",
                actions: [
                    UNNotificationAction(
                        identifier: Self.morningGemDoneAction,
                        title: "Got it — don't show again"
                    ),
                ],
                intentIdentifiers: []
            ),
        ])
        registerIfAuthorized()
    }

    /// Re-register whenever the server might have dropped our token
    /// (launch, and again after sign-in since sign-out deletes tokens).
    func registerIfAuthorized() {
        Task {
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .authorized {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    /// The permission moment: right after the first dump lands, when a nudge
    /// "when the AI's done" actually means something.
    func promptAfterFirstDumpIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: "promptedForPush") else { return }
        UserDefaults.standard.set(true, forKey: "promptedForPush")
        Task {
            let granted = (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
            if granted {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    /// APNs handed us a device token — tell the server.
    func uploadDeviceToken(_ token: Data) {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        guard let auth = Keychain.read(account: "token") else { return }
        let api = APIClient(baseURL: SharedStorage.serverURL, token: auth)
        Task {
            try? await api.registerPushToken(hex, deviceName: UIDevice.current.name)
        }
    }

    /// Mirror the awaiting-approval count onto the app icon.
    func setBadge(_ count: Int) {
        center.setBadgeCount(count)
    }

    /// A background upload died and nobody was looking — say so once.
    func notifyUploadFailed(_ upload: SharedStorage.QueuedUpload) {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = "Couldn't dump that"
        content.body = "\(upload.label) — \(upload.failureText.lowercased()). Open the app to retry or discard."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "upload-failed-\(upload.id.uuidString)",
            content: content,
            trigger: nil
        )
        center.add(request)
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .badge, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        let itemId = Self.intValue(userInfo["inbox_item_id"])
        let activityId = Self.intValue(userInfo["activity_id"])
        let nuggetId = userInfo["nugget_id"] as? String

        // "Got it" on the morning gem: tick the nugget quietly, no app opening.
        if response.actionIdentifier == Self.morningGemDoneAction {
            if let activityId, let nuggetId {
                await MainActor.run {
                    self.markMorningGemDone(activityId: activityId, nuggetId: nuggetId)
                }
            }
            return
        }

        await MainActor.run {
            if let itemId {
                LaunchActions.shared.reviewItemId = itemId
            } else if let activityId {
                LaunchActions.shared.openActivityId = activityId
            } else {
                LaunchActions.shared.wantsInbox = true
            }
        }
    }

    /// APNs payloads deliver numbers as Int or String depending on encoder.
    private nonisolated static func intValue(_ value: Any?) -> Int? {
        value as? Int ?? (value as? String).flatMap(Int.init)
    }

    private func markMorningGemDone(activityId: Int, nuggetId: String) {
        guard let auth = Keychain.read(account: "token") else { return }
        let api = APIClient(baseURL: SharedStorage.serverURL, token: auth)
        Task {
            _ = try? await api.updateTakeaway(activityId: activityId, itemId: nuggetId, done: true)
        }
    }
}
