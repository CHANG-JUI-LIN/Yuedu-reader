import SwiftUI
import Testing
import UIKit
@testable import yuedu_app

/// What VoiceOver reads for 目錄's 正序／倒序 control (回饋 #37): its name, and the order it is
/// in while closed. The control is a `Menu` in a `ToolbarItem`, which UIKit turns into a bar
/// button; this reads the window's own accessibility elements, as VoiceOver does.
@Suite("Chapter list order VoiceOver", .serialized)
@MainActor
struct ChapterListOrderVoiceOverTests {
    private func host(_ view: some View) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        return window
    }

    /// The element VoiceOver finds outside the page whose name is `label` — the bars sit in
    /// `UINavigationBar` on iOS 17 and in a floating bar beside it from iOS 26, and join the tree
    /// after the page, so this waits for the element itself.
    private func barElement(named label: String, in window: UIWindow) async throws -> NSObject? {
        func navigationController(in controller: UIViewController) -> UINavigationController? {
            controller as? UINavigationController ?? controller.children.lazy.compactMap(navigationController(in:)).first
        }
        func elements(in object: NSObject, outside page: UIView) -> [NSObject] {
            if object === page { return [] }
            if object.isAccessibilityElement { return [object] }
            if let children = object.accessibilityElements as? [NSObject] {
                return children.flatMap { elements(in: $0, outside: page) }
            }
            return (object as? UIView)?.subviews.flatMap { elements(in: $0, outside: page) } ?? []
        }
        func found() -> NSObject? {
            guard let root = window.rootViewController,
                  let page = navigationController(in: root)?.topViewController?.viewIfLoaded else { return nil }
            return elements(in: window, outside: page).first { $0.accessibilityLabel == label }
        }
        let deadline = ContinuousClock.now + .seconds(5)
        var result = found()
        while result == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            result = found()
        }
        return result
    }

    /// SwiftUI builds no accessibility elements until something reads them — VoiceOver, or
    /// XCUITest's automation. Turned on here as XCUITest does it, and back off after.
    private func withAutomation(_ body: () async throws -> Void) async throws {
        let accessibility = try #require(dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW))
        typealias GetFlag = @convention(c) () -> Bool
        typealias SetFlag = @convention(c) (Bool) -> Void
        let automationEnabled = unsafeBitCast(try #require(dlsym(accessibility, "_AXSAutomationEnabled")), to: GetFlag.self)
        let setAutomationEnabled = unsafeBitCast(try #require(dlsym(accessibility, "_AXSSetAutomationEnabled")), to: SetFlag.self)
        let wasEnabled = automationEnabled()
        setAutomationEnabled(true)
        defer { setAutomationEnabled(wasEnabled) }
        try await body()
    }

    @Test("the closed control reads 排序 and the book's order", arguments: ChapterListOrder.allCases)
    func readsOrder(_ order: ChapterListOrder) async throws {
        let bookID = UUID()
        ChapterListOrder.store(order, for: bookID)
        defer { ChapterListOrder.store(.ascending, for: bookID) }
        let chapters = (0..<3).map { OnlineChapterRef(index: $0, title: "c\($0)", url: "") }

        try await withAutomation {
            let window = try host(NavigationStack {
                BookDetailChapterListSheet(chapters: chapters, bookID: bookID, trailing: .disclosure, onSelect: { _ in })
            })
            defer { window.isHidden = true; window.rootViewController = nil }
            let control = try #require(try await barElement(named: localized("排序"), in: window))
            #expect(control.accessibilityValue == order.title)
            #expect(control.accessibilityTraits.contains(.button))
        }
    }
}
