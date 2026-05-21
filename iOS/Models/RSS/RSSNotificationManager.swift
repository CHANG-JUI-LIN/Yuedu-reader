import UIKit
import UserNotifications

final class RSSNotificationManager {
    static let shared = RSSNotificationManager()

    private enum Constants {
        static let categoryIdentifier = "RSS_NEW_ARTICLE"
        static let markReadActionIdentifier = "RSS_MARK_READ"
        static let openActionIdentifier = "RSS_OPEN_ARTICLE"
        static let notificationIdentifierPrefix = "rssArticle:"
    }

    private var isStarted = false

    private init() {}

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

    func updateBadge(unreadCount: Int) {
        UNUserNotificationCenter.current().setBadgeCount(unreadCount)
    }

    func notifyNewArticles(_ articles: [RSSArticleRecord], source: RSSSource) {
        guard !articles.isEmpty else { return }

        let unreadCount = RSSStore.shared.totalUnreadCount()
        for article in articles {
            let content = UNMutableNotificationContent()
            content.title = source.name
            content.subtitle = article.title
            content.body = article.summary
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

    func removeDeliveredNotification(articleID: String) {
        removeDeliveredNotifications(articleIDs: [articleID])
    }

    func removeDeliveredNotifications(articleIDs: [String]) {
        let identifiers = articleIDs.map(notificationIdentifier(for:))
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func handleNotificationResponse(_ response: UNNotificationResponse) {
        guard response.actionIdentifier == Constants.markReadActionIdentifier,
              let articleID = response.notification.request.content.userInfo["articleID"] as? String else {
            return
        }
        RSSStore.shared.markRead(articleId: articleID, isRead: true)
    }

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
        let category = UNNotificationCategory(
            identifier: Constants.categoryIdentifier,
            actions: [openAction, markReadAction],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    private func notificationIdentifier(for articleID: String) -> String {
        Constants.notificationIdentifierPrefix + articleID
    }
}

final class RSSAppNotificationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        RSSNotificationManager.shared.start()
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        RSSNotificationManager.shared.updateBadge(unreadCount: RSSStore.shared.totalUnreadCount())
    }

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
