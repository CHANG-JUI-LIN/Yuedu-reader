import SwiftUI
import Testing
import UIKit
@testable import yuedu_app

/// What VoiceOver's rotor offers on a book in the shelf's list: 作品詳情, 置頂, 編輯書籍資訊
/// and a delete, once each. The row's swipe carries 置頂 and 刪除, and from iOS 27 SwiftUI adds
/// a `List` row's swipe actions to the row's accessibility element by itself; a row that also
/// declared them was read with a delete twice (a blind user's report, 2026-11-14). Before
/// iOS 27 the element carries only what the row declares, so there the row declares all four
/// (`BookshelfRowSwipe`). Run this on both sides of iOS 27: the older side is what catches a
/// row that leaves 置頂 and the delete to a swipe VoiceOver never hears of.
///
/// XCUITest cannot read custom actions; this reads the hosting window's own accessibility
/// elements. It reads the row's element, not what VoiceOver assembles around it.
@Suite("Bookshelf list rows: VoiceOver actions", .serialized)
@MainActor
struct BookshelfRowVoiceOverActionsTests {
    private static let title = "轉子動作測試書"

    @Test func aBookOffersEachActionOnce() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookshelfRowVoiceOver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = BookStore(metadataFileURL: directory.appendingPathComponent("books_meta.json"))
        var book = ReadingBook(title: Self.title, author: "作者", contentFilename: "")
        book.isOnline = true
        store.replaceBooksFromSync([book])
        store.waitForQueuedWrites()

        let defaults = UserDefaults.standard
        let previousGrid = defaults.object(forKey: "bookLayoutIsGrid")
        defaults.set(false, forKey: "bookLayoutIsGrid")

        // SwiftUI builds no accessibility elements until something reads them — VoiceOver, or
        // XCUITest's automation. Turned on here as XCUITest does it, and back off after.
        let accessibility = try #require(dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW))
        typealias GetFlag = @convention(c) () -> Bool
        typealias SetFlag = @convention(c) (Bool) -> Void
        let automationEnabled = unsafeBitCast(try #require(dlsym(accessibility, "_AXSAutomationEnabled")), to: GetFlag.self)
        let setAutomationEnabled = unsafeBitCast(try #require(dlsym(accessibility, "_AXSSetAutomationEnabled")), to: SetFlag.self)
        let wasEnabled = automationEnabled()
        setAutomationEnabled(true)

        let host = try WindowHost(HomeView().environmentObject(store))
        defer {
            host.tearDown()
            setAutomationEnabled(wasEnabled)
            defaults.set(previousGrid, forKey: "bookLayoutIsGrid")
            store.waitForQueuedWrites()
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                Issue.record("the test's shelf was not removed: \(error)")
            }
        }

        func elements(in object: NSObject) -> [NSObject] {
            if object.isAccessibilityElement { return [object] }
            if let children = object.accessibilityElements as? [NSObject] { return children.flatMap(elements(in:)) }
            return (object as? UIView)?.subviews.flatMap(elements(in:)) ?? []
        }
        func row() -> NSObject? {
            elements(in: host.window).first { ($0.accessibilityLabel ?? "").hasPrefix(Self.title) }
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while row() == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let bookRow = try #require(row(), "the book never reached the accessibility tree")

        let offered = (bookRow.accessibilityCustomActions ?? []).map(\.name)
        let pin = BookshelfPinLabel.title(isPinned: false)
        #expect(offered.filter { $0 == localized("作品詳情") }.count == 1, "\(offered)")
        #expect(offered.filter { $0 == pin }.count == 1, "\(offered)")
        #expect(offered.filter { $0 == localized("編輯書籍資訊") }.count == 1, "\(offered)")
        // The swipe says 刪除 and the row 刪除書籍: one delete, whichever names it.
        let deletes = offered.filter { $0 == localized("刪除") || $0 == localized("刪除書籍") }
        #expect(deletes.count == 1, "\(offered)")
        #expect(offered.count == 4, "\(offered)")
    }
}
