import SwiftUI
import Testing
import UIKit
@testable import yuedu_app

/// A tab whose page has pushed a book still being readied (`ReaderPreparingView`), as 作品詳情
/// pushes its reader, with the root's tab-bar hiding behind each tab as `ContentView` has it.
/// Verbatim, so the titles read the same in every language the tests run in.
private struct PreparingInATab: View {
    let tabBar: RootTabBarVisibility

    var body: some View {
        TabView {
            NavigationStack {
                Text(verbatim: "詳情內容")
                    .navigationDestination(isPresented: .constant(true)) {
                        ReaderPreparingView(error: nil, onRetry: {}, onClose: {})
                            .environment(\.readerUsesParentNavigationStack, true)
                            .navigationBarBackButtonHidden(true)
                    }
            }
            .background { RootTabBarHider(visibility: tabBar) }
            .tabItem { Label { Text(verbatim: "探索") } icon: { Image(systemName: "safari") } }
            Text(verbatim: "設定內容")
                .background { RootTabBarHider(visibility: tabBar) }
                .tabItem { Label { Text(verbatim: "設定") } icon: { Image(systemName: "gearshape") } }
        }
        .environment(\.rootTabBarVisibility, tabBar)
    }
}

/// A book being readied before its reader opens is the reader's own 載入中…, full screen. Until
/// 2026-10-27 it was a page of its own, 正在開啟書籍 under the tab bar and the status bar
/// (maintainer, iPhone Duo unfolded: 「統一都是加載中」).
@Suite("Reader preparing", .serialized)
@MainActor
struct ReaderPreparingViewTests {
    @Test func pushedInATabItCoversTheTabBarAndTheStatusBar() async throws {
        let tabBar = RootTabBarVisibility()
        try await hosting(PreparingInATab(tabBar: tabBar)) { window in
            let read = try await reading(window) {
                $0.labels.contains(localized("載入中…")) && !$0.labels.contains("探索")
            }
            #expect(!read.labels.contains("設定"), "\(read.described)")
            #expect(!read.labels.contains(localized("退出閱讀")), "\(read.described)")
            #expect(tabBar.isTabBarHidden)
            try await until("the status bar hides") { window.windowScene?.statusBarManager?.isStatusBarHidden == true }
        }
    }

    /// As on the reader's loading page, VoiceOver lands on one button that says what is happening
    /// and that it raises the reading menu, where 退出閱讀 is.
    @Test func voiceOverReadsTheReadersLoading() async throws {
        try await hosting(PreparingInATab(tabBar: RootTabBarVisibility())) { window in
            let read = try await reading(window) { $0.labels.contains(localized("載入中…")) }
            let loading = try #require(read.elements.first { $0.accessibilityLabel == localized("載入中…") })
            #expect(loading.accessibilityHint == localized("顯示閱讀工具列"))
            #expect(loading.accessibilityTraits.contains(.button))
        }
    }

    // MARK: - Hosting

    private func hosting(_ view: some View, _ body: (UIWindow) async throws -> Void) async throws {
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

        let root = UIHostingController(rootView: view)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await body(window)
    }

    /// `window` as VoiceOver reads it, once `ready` holds for it.
    private func reading(_ window: UIWindow, until ready: (Reading) -> Bool) async throws -> Reading {
        let deadline = ContinuousClock.now + .seconds(5)
        var read = Reading(window: window)
        while !ready(read), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            read = Reading(window: window)
        }
        try #require(ready(read), "never read as expected: \(read.described)")
        return read
    }

    private func until(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(condition(), "\(what) never happened")
    }
}

/// The elements VoiceOver can land on in a window, in its order.
@MainActor
private struct Reading {
    let elements: [NSObject]

    init(window: UIWindow) {
        elements = Self.elements(in: window)
    }

    var labels: [String] { elements.map { $0.accessibilityLabel ?? "" } }

    var described: String {
        elements.map { "\($0.accessibilityLabel ?? "")<\(type(of: $0))>" }.joined(separator: ", ")
    }

    /// Left out: what is hidden, what is inside an element (read as one), and the siblings of
    /// a modal element.
    private static func elements(in object: NSObject) -> [NSObject] {
        if object.accessibilityElementsHidden { return [] }
        if let view = object as? UIView, view.isHidden || view.alpha < 0.01 { return [] }
        if object.isAccessibilityElement { return [object] }
        let children: [NSObject]
        if let elements = object.accessibilityElements as? [NSObject] {
            children = elements
        } else if let view = object as? UIView {
            children = view.subviews
        } else {
            children = []
        }
        let modal = children.filter(\.accessibilityViewIsModal)
        return (modal.isEmpty ? children : modal).flatMap(elements(in:))
    }
}
