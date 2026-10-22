import SwiftUI
import Testing
import UIKit
@testable import yuedu_app

/// A row with what VoiceOver reads and what it is kept from: a decorative symbol, a caption.
private struct RowWithHiddenParts: View {
    var body: some View {
        VStack {
            Text("可見文字")
            Image(systemName: "star.fill").accessibilityHidden(true)
            Text("藏起來的字").accessibilityHidden(true)
        }
    }
}

/// `accessibilityHidden(onlyWhen:)`, which 編輯首頁 puts around every row of the home. A plain
/// `accessibilityHidden(false)` there brought back what the row hides — the symbol read out as
/// "Favorite" — on iOS 17.5 and 27 alike. XCUITest lists hidden elements too, so this reads the
/// hosting view's own accessibility elements, as VoiceOver does.
@Suite("accessibilityHidden(onlyWhen:)", .serialized)
@MainActor
struct AccessibilityHiddenOnlyWhenTests {
    private func spokenLabels(of view: some View) async throws -> [String] {
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

        // A label beside the row, so the tree is there to read whether or not the row is hidden.
        let root = UIHostingController(rootView: VStack { Text("旁邊"); view })
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }

        func labels(in object: NSObject) -> [String] {
            var found = object.isAccessibilityElement ? [object.accessibilityLabel ?? ""] : []
            if let elements = object.accessibilityElements as? [NSObject] {
                found += elements.flatMap(labels(in:))
            } else if let view = object as? UIView {
                found += view.subviews.flatMap(labels(in:))
            }
            return found
        }
        let deadline = ContinuousClock.now + .seconds(5)
        var found = labels(in: root.view)
        while !found.contains("旁邊"), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            found = labels(in: root.view)
        }
        try #require(found.contains("旁邊"), "the view never reached the accessibility tree")
        return found
    }

    @Test("not hiding leaves what the row hides hidden")
    func notHidingKeepsInnerHidden() async throws {
        let plain = try await spokenLabels(of: RowWithHiddenParts())
        #expect(plain == ["旁邊", "可見文字"])
        #expect(try await spokenLabels(of: RowWithHiddenParts().accessibilityHidden(onlyWhen: false)) == plain)
    }

    @Test("hiding hides the whole row")
    func hidingHidesAll() async throws {
        #expect(try await spokenLabels(of: RowWithHiddenParts().accessibilityHidden(onlyWhen: true)) == ["旁邊"])
    }
}
