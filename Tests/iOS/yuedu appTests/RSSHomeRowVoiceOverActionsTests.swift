import SwiftUI
import Testing
import UIKit
@testable import yuedu_app

/// What VoiceOver offers on RSS 訂閱's rows: each row's swipe actions, once. The page is a
/// ScrollView, so the swipe actions open only from iOS 27 (`swipeActionsContainer()`), and
/// VoiceOver offered them only there — on iOS 17.5 the rows had no actions at all. Before
/// iOS 27 the rows add them as accessibility actions themselves. XCUITest cannot read custom
/// actions, so this reads the hosting window's own accessibility elements, as VoiceOver does.
///
/// The page shows `RSSStore.shared`: the test feed (`seedForTesting`, two unread articles) and
/// a folder are added for the test and taken away after.
@Suite("RSS home rows: VoiceOver actions", .serialized)
@MainActor
struct RSSHomeRowVoiceOverActionsTests {
    private static let folderName = "VoiceOverFolder"
    private static let feedName = "首頁訂閱測試"

    @Test func eachRowOffersItsSwipeActionsOnce() async throws {
        let store = RSSStore.shared
        store.seedForTesting()
        _ = store.addFolder(named: Self.folderName)
        // Shown, whatever the simulator was left with.
        let defaults = UserDefaults.standard
        let keys = ["rss_main_feed_hide_read_feeds", "rss_main_feed_local_expanded"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defaults.set(false, forKey: keys[0])
        defaults.set(true, forKey: keys[1])
        defer {
            for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) }
            if let folder = store.folders.first(where: { $0.name == Self.folderName }) {
                store.removeFolder(folder)
            }
            store.removeTestSeed()
        }
        let feed = try #require(store.sources.first { $0.url == RSSStore.testSeedFeedURL })
        try #require(store.unreadCount(for: feed.id) > 0)

        // SwiftUI builds no accessibility elements until something reads them — VoiceOver, or
        // XCUITest's automation. Turned on here as XCUITest does it, and back off after.
        let accessibility = try #require(dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW))
        typealias GetFlag = @convention(c) () -> Bool
        typealias SetFlag = @convention(c) (Bool) -> Void
        let automationEnabled = unsafeBitCast(try #require(dlsym(accessibility, "_AXSAutomationEnabled")), to: GetFlag.self)
        let setAutomationEnabled = unsafeBitCast(try #require(dlsym(accessibility, "_AXSSetAutomationEnabled")), to: SetFlag.self)
        let wasEnabled = automationEnabled()
        setAutomationEnabled(true)
        defer { setAutomationEnabled(wasEnabled) }

        let root = UIHostingController(rootView: NavigationStack { RSSListView() })
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }

        func elements(in object: NSObject) -> [NSObject] {
            if object.isAccessibilityElement { return [object] }
            if let children = object.accessibilityElements as? [NSObject] { return children.flatMap(elements(in:)) }
            return (object as? UIView)?.subviews.flatMap(elements(in:)) ?? []
        }
        func row(_ name: String) -> NSObject? {
            elements(in: root.view).first { ($0.accessibilityLabel ?? "").hasPrefix(name) }
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while row(Self.folderName) == nil || row(Self.feedName) == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let folderRow = try #require(row(Self.folderName), "the folder never reached the accessibility tree")
        let feedRow = try #require(row(Self.feedName), "the feed never reached the accessibility tree")

        let folderActions = (folderRow.accessibilityCustomActions ?? []).map(\.name)
        #expect(folderActions.sorted() == [localized("刪除"), localized("重新命名")].sorted())
        let feedActions = feedRow.accessibilityCustomActions ?? []
        #expect(feedActions.map(\.name).sorted()
            == [localized("標記全部已讀"), localized("刪除"), localized("編輯訂閱")].sorted())

        // And an action runs what its swipe action runs.
        let markRead = try #require(feedActions.first { $0.name == localized("標記全部已讀") })
        if let handler = markRead.actionHandler {
            _ = handler(markRead)
        } else {
            _ = (markRead.target as AnyObject?)?.perform(markRead.selector, with: markRead)
        }
        #expect(store.unreadCount(for: feed.id) == 0)
    }
}
