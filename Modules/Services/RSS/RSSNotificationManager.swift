import BackgroundTasks
import FirebaseCore
import UIKit
import UserNotifications
import os

final class RSSNotificationManager {
    static let shared = RSSNotificationManager()

    private enum Constants {
        static let categoryIdentifier = "RSS_NEW_ARTICLE"
        static let markReadActionIdentifier = "RSS_MARK_READ"
        static let markStarredActionIdentifier = "RSS_MARK_STARRED"
        static let openActionIdentifier = "RSS_OPEN_ARTICLE"
        static let notificationIdentifierPrefix = "articleID:"
        static let maxTitleLength = 1000
        static let maxBodyLength = 300
    }

    private let logger = Logger(subsystem: "com.yuedu.rss", category: "NotificationManager")
    private var isStarted = false

    private init() {}

    // MARK: - Start

    func start(store: RSSStore = .shared) {
        guard !isStarted else { return }
        isStarted = true

        registerCategories()
        UNUserNotificationCenter.current().requestAuthorization(options: [.badge, .sound, .alert]) { granted, _ in
            if granted {
                DispatchQueue.main.async {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
        }
        updateBadge(unreadCount: store.totalUnreadCount())
    }

    // MARK: - Badge

    func updateBadge(unreadCount: Int) {
        UNUserNotificationCenter.current().setBadgeCount(unreadCount)
    }

    // MARK: - Notify New Articles

    /// Send local notifications for new unread articles whose source has notifications enabled.
    func notifyNewArticles(_ articles: [RSSArticleRecord], source: RSSSource) {
        guard source.newArticleNotificationsEnabled, !articles.isEmpty else { return }

        let unreadCount = RSSStore.shared.totalUnreadCount()
        for article in articles {
            guard !article.isRead else { continue }

            let content = UNMutableNotificationContent()
            content.title = source.name
            content.subtitle = truncatedTitle(article.title)
            content.body = truncatedSummary(article.summary)
            content.threadIdentifier = source.id
            content.categoryIdentifier = Constants.categoryIdentifier
            content.sound = .default
            content.badge = NSNumber(value: unreadCount)
            content.userInfo = [
                "sourceID": source.id,
                "articleID": article.id,
                "articleLink": article.link
            ]

            let request = UNNotificationRequest(
                identifier: notificationIdentifier(for: article.id),
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }
    }

    // MARK: - Remove Notifications

    func removeDeliveredNotification(articleID: String) {
        removeDeliveredNotifications(articleIDs: [articleID])
    }

    func removeDeliveredNotifications(articleIDs: [String]) {
        let identifiers = articleIDs.map(notificationIdentifier(for:))
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    /// Listen for status changes and remove notifications for articles marked as read.
    func onArticlesMarkedRead(articleIDs: [String]) {
        removeDeliveredNotifications(articleIDs: articleIDs)
    }

    // MARK: - Handle Notification Action

    func handleNotificationResponse(_ response: UNNotificationResponse) {
        guard let articleID = response.notification.request.content.userInfo["articleID"] as? String else {
            return
        }
        switch response.actionIdentifier {
        case Constants.markReadActionIdentifier:
            RSSStore.shared.markRead(articleId: articleID, isRead: true)
        case Constants.markStarredActionIdentifier:
            RSSStore.shared.toggleFavorite(articleId: articleID)
        case Constants.openActionIdentifier, UNNotificationDefaultActionIdentifier:
            break // Handled by SceneDelegate deep link
        default:
            break
        }
    }

    // MARK: - Private

    private func registerCategories() {
        let openAction = UNNotificationAction(
            identifier: Constants.openActionIdentifier,
            title: localized("開啟"),
            options: [.foreground]
        )
        let markReadAction = UNNotificationAction(
            identifier: Constants.markReadActionIdentifier,
            title: localized("標為已讀"),
            options: []
        )
        let markStarredAction = UNNotificationAction(
            identifier: Constants.markStarredActionIdentifier,
            title: localized("加星號"),
            options: []
        )
        let category = UNNotificationCategory(
            identifier: Constants.categoryIdentifier,
            actions: [openAction, markStarredAction, markReadAction],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    private func notificationIdentifier(for articleID: String) -> String {
        Constants.notificationIdentifierPrefix + articleID
    }

    // MARK: - Content Formatting

    private func truncatedTitle(_ title: String) -> String {
        stripped(title, maxUTF8Length: Constants.maxTitleLength)
    }

    private func truncatedSummary(_ summary: String) -> String {
        stripped(summary, maxUTF8Length: Constants.maxBodyLength)
    }

    private func stripped(_ text: String, maxUTF8Length: Int) -> String {
        let stripped = text
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { return "" }

        var result = ""
        var byteCount = 0
        for char in stripped {
            let charBytes = String(char).utf8.count
            if byteCount + charBytes > maxUTF8Length { break }
            result.append(char)
            byteCount += charBytes
        }
        return result
    }
}

// MARK: - App Notification Delegate

final class RSSAppNotificationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        FirebaseApp.configure()
        UNUserNotificationCenter.current().delegate = self
        RSSNotificationManager.shared.start()
        scheduleBackgroundFeedRefresh()
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        RSSNotificationManager.shared.updateBadge(unreadCount: RSSStore.shared.totalUnreadCount())
        scheduleBackgroundFeedRefresh()
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        ReaderOrientationController.shared.supportedMask(for: UIDevice.current.userInterfaceIdiom)
    }

    // MARK: - Background Fetch

    private func scheduleBackgroundFeedRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: "com.yuedu.rss.feedRefresh")
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60) // 1 hour minimum
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Logger(subsystem: "com.yuedu.rss", category: "BackgroundTask")
                .warning("Failed to schedule background refresh: \(error.localizedDescription)")
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.list, .banner, .badge, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            RSSNotificationManager.shared.handleNotificationResponse(response)
            completionHandler()
        }
    }
}
