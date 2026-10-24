import SwiftUI
import Testing
import UIKit
@testable import yuedu_app

/// The root as 新手導覽 covers it: a tab bar over SwiftUI pages, one of which keeps a symbol and
/// a caption from VoiceOver and can present a full-screen cover, as 書架 presents the reader.
/// Verbatim, so the titles read the same in every language the tests run in.
private struct RootTabs: View {
    var cover: String?

    var body: some View {
        TabView {
            VStack {
                Text(verbatim: "書架內容")
                Image(systemName: "star.fill").accessibilityHidden(true)
                Text(verbatim: "藏起來的字").accessibilityHidden(true)
            }
            .fullScreenCover(isPresented: .constant(cover != nil)) { Text(verbatim: cover ?? "") }
            .tabItem { Label { Text(verbatim: "書架") } icon: { Image(systemName: "books.vertical") } }
            Text(verbatim: "設定內容")
                .tabItem { Label { Text(verbatim: "設定") } icon: { Image(systemName: "gearshape") } }
        }
    }
}

/// 長時間閱讀也舒服 on its own, as the tour shows it.
private struct ReadingPage: View {
    let rows: [OnboardingContent.Row]
    @AccessibilityFocusState private var focus: OnboardingPage?

    var body: some View {
        OnboardingReadingPage(rows: rows, focus: $focus)
    }
}

/// What VoiceOver reaches while 新手導覽 is up and after it closes. XCUITest lists elements
/// VoiceOver no longer reaches, so this walks the window's own accessibility elements, as
/// VoiceOver does.
@Suite("新手導覽：VoiceOver", .serialized)
@MainActor
struct OnboardingVoiceOverTests {
    @Test func theTourAloneIsReadWhileItIsUp() async throws {
        try await withTour { state in
            try await hosting(RootTabs().modifier(tour(state))) { window in
                // Closed and brought back, so the tabs under it are surely there to be kept out.
                _ = try await reading(window) { $0.labels.contains(localized("繼續")) }
                state.finish(startingAt: nil)
                _ = try await reading(window) { $0.labels.contains("書架") && $0.labels.contains("設定") }
                state.replay()
                // Neither the tab bar nor the page under the tour.
                _ = try await reading(window) { read in
                    read.labels.contains(localized("略過")) && read.labels.contains(localized("繼續"))
                        && !read.labels.contains("書架") && !read.labels.contains("設定")
                        && !read.labels.contains("書架內容")
                }
            }
        }
    }

    @Test func closedItLeavesTheTabsAsTheyWere() async throws {
        let plain = try await hosting(RootTabs()) { window in
            try await reading(window) {
                $0.labels.contains("書架內容") && $0.labels.contains("書架") && $0.labels.contains("設定")
            }
        }
        #expect(!plain.labels.contains("藏起來的字"), "\(plain.described)")

        try await withTour { state in
            try await hosting(RootTabs().modifier(tour(state))) { window in
                _ = try await reading(window) { $0.labels.contains(localized("繼續")) }
                state.finish(startingAt: nil)
                // What the tabs hide stays hidden, and the rest is read in the same order.
                _ = try await reading(window) { $0.labels == plain.labels }
            }
        }
    }

    /// A book opened into 閱讀 at the launch that shows the tour presents its reader over it,
    /// and that reader is presented from the root the tour keeps VoiceOver from.
    @Test func aCoverOverTheTourIsRead() async throws {
        try await withTour { state in
            try await hosting(RootTabs(cover: "閱讀器").modifier(tour(state))) { window in
                _ = try await reading(window) { $0.labels.contains("閱讀器") }
            }
        }
    }

    /// A 閱讀Pro row is one stop that says once it needs Pro, after the feature's name.
    @Test func aLockedRowSaysProOnce() async throws {
        let content = OnboardingContent(visibleTabs: RootTabItem.tabs, librariesAvailable: true, languages: ["zh"],
                                        lockedFeatures: Set(PremiumFeature.allCases))
        let theme = localized("外觀主題")
        try await hosting(ReadingPage(rows: content.reading)) { window in
            let read = try await reading(window) { $0.labels.contains { $0.hasPrefix(theme) } }
            let row = try #require(read.labels.first { $0.hasPrefix(theme) })
            #expect(row.components(separatedBy: localized("需要 Pro")).count == 2, "\(read.described)")
            #expect(row.contains(localized("在設定裡自己調 App 與閱讀的配色，還有每一頁的背景")), "\(row)")
        }
    }

    // MARK: - Hosting

    private func tour(_ state: OnboardingState) -> OnboardingPresentation {
        OnboardingPresentation(state: state, selectedTab: .constant(.bookshelf), tint: nil)
    }

    /// A tour that has not been seen, on defaults of its own.
    private func withTour(_ body: (OnboardingState) async throws -> Void) async throws {
        let suite = "OnboardingVoiceOverTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = OnboardingState(defaults: defaults)
        try #require(state.isPresented)
        try await body(state)
    }

    private func hosting<Result>(
        _ view: some View,
        _ body: (UIWindow) async throws -> Result
    ) async throws -> Result {
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

        let root = UIHostingController(rootView: view.environmentObject(SubscriptionStore(observeTransactions: false)))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer {
            root.presentedViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }
        return try await body(window)
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
