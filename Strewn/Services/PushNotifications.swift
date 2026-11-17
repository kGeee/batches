import UIKit
import UserNotifications

/// Bridges UNUserNotificationCenter and APNs device token callbacks to `AppModel` so notification
/// taps deep-link to the batch, photo or person, foreground alerts show a banner, and APNs tokens
/// register with the backend once permission is granted.
@MainActor
final class PushNotifications: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var model: AppModel?
    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    private var currentToken: String?

    func attach(to model: AppModel) {
        self.model = model
        UNUserNotificationCenter.current().delegate = self
        Task { await refreshAuthorizationStatus() }
    }

    func refreshAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus
        if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    @discardableResult
    func requestPermission() async -> Bool {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])) ?? false
        await refreshAuthorizationStatus()
        return granted
    }

    func updateBadgeCount(_ count: Int) {
        guard authorizationStatus == .authorized || authorizationStatus == .provisional else { return }
        UNUserNotificationCenter.current().setBadgeCount(count) { _ in }
        // Everything has been read in the app, so the alerts left in Notification Center are stale.
        if count == 0 { UNUserNotificationCenter.current().removeAllDeliveredNotifications() }
    }

    func clearCurrentToken() async -> String? {
        defer { currentToken = nil }
        return currentToken
    }

    func syncStoredTokenIfNeeded() async {
        guard let currentToken, let model else { return }
        await model.registerDeviceToken(currentToken, environment: Self.apnsEnvironment)
    }

    /// Posts a local notification when new unread notifications arrive while the app is open or
    /// refreshing. Once this device has an APNs token the server pushes every notification itself
    /// (and `willPresent` shows it in the foreground), so a local banner would only repeat it.
    func deliverLocalBannerIfNeeded(for item: ActivityItem) {
        guard currentToken == nil else { return }
        guard authorizationStatus == .authorized || authorizationStatus == .provisional else { return }
        let content = UNMutableNotificationContent()
        let actorName = item.actor?.displayName ?? "Someone"
        content.title = "Batches"
        switch item.kind {
        case .like:
            content.body = "\(actorName) liked your photo"
        case .comment(let body):
            content.body = "\(actorName) commented: \(body)"
        case .mention(let body):
            content.body = "\(actorName) mentioned you: \(body)"
        case .tag:
            content.body = item.batchTitle.map { "\(actorName) tagged you in \($0)" } ?? "\(actorName) tagged you in a photo"
        case .batchShared(let canAdd):
            if let title = item.batchTitle {
                content.body = canAdd ? "\(actorName) invited you to add photos to \(title)" : "\(actorName) shared \(title) with you"
            } else {
                content.body = canAdd ? "\(actorName) invited you to add to a batch" : "\(actorName) shared a batch with you"
            }
        case .photoAdded(let count):
            let frames = count == 1 ? "a photo" : "\(count) photos"
            content.body = item.batchTitle.map { "\(actorName) added \(frames) to \($0)" } ?? "\(actorName) added \(frames) to your batch"
        case .follow:
            content.body = "\(actorName) started following you"
        }
        content.sound = .default
        var userInfo: [String: String] = ["notification_id": item.id]
        if let collectionID = item.collectionID { userInfo["collection_id"] = collectionID.uuidString.lowercased() }
        if let photoID = item.photoID { userInfo["photo_id"] = photoID.uuidString.lowercased() }
        if let handle = item.actor?.handle { userInfo["actor_handle"] = handle }
        content.userInfo = userInfo

        let request = UNNotificationRequest(identifier: "batches-\(item.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: UIApplicationDelegate

    nonisolated func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in
            self.currentToken = hex
            await self.model?.registerDeviceToken(hex, environment: Self.apnsEnvironment)
        }
    }

    nonisolated func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {}

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        let notificationID = info["notification_id"] as? String
        let urlString = info["url"] as? String
        let collectionID = (info["collection_id"] as? String).flatMap(UUID.init(uuidString:))
        let photoID = (info["photo_id"] as? String).flatMap(UUID.init(uuidString:))
        let handle = info["actor_handle"] as? String

        await MainActor.run {
            guard let model = self.model else { return }
            if let notificationID {
                model.markNotificationRead(notificationID)
            }
            Task {
                if let urlString, let url = URL(string: urlString) {
                    await model.open(url)
                } else if let collectionID {
                    var components = URLComponents()
                    components.scheme = "strewn"
                    components.host = "pile"
                    components.path = "/" + collectionID.uuidString.lowercased()
                    if let photoID {
                        components.queryItems = [URLQueryItem(name: "photo", value: photoID.uuidString.lowercased())]
                    }
                    if let url = components.url { await model.open(url) }
                } else if let handle {
                    if let url = URL(string: "strewn://u/\(handle)") { await model.open(url) }
                } else {
                    await model.open(URL(string: "strewn://notifications")!)
                }
            }
        }
    }

    private static var apnsEnvironment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }
}
