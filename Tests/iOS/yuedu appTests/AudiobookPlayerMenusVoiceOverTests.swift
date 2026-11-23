import SwiftUI
import Testing
import UIKit
@testable import yuedu_app

/// The player's ••• and sleep-timer menus are views of their own, kept off the page's
/// half-second progress updates (FB-245). VoiceOver still lands on each as one button with the
/// page's name for it: the labels stay on the page, around the menus.
@Suite("Audiobook player menus, VoiceOver", .serialized)
@MainActor
struct AudiobookPlayerMenusVoiceOverTests {
    @Test func moreAndSleepAreOneButtonEach() async throws {
        let page = AudiobookReaderView(bookId: UUID()).environmentObject(BookStore())
        try await hosting(page) { window in
            let read = try await reading(window) {
                $0.labels.contains(localized("更多")) && $0.labels.contains(localized("睡眠定時"))
            }
            let more = read.elements.filter { $0.accessibilityLabel == localized("更多") }
            #expect(more.count == 1, "\(read.described)")
            #expect(more.first?.accessibilityTraits.contains(.button) == true, "\(read.described)")

            let sleep = read.elements.filter { $0.accessibilityLabel == localized("睡眠定時") }
            #expect(sleep.count == 1, "\(read.described)")
            #expect(sleep.first?.accessibilityTraits.contains(.button) == true, "\(read.described)")
            #expect(sleep.first?.accessibilityValue == AudiobookSleepChoice.off.title, "\(read.described)")
            // The moon itself is not read as a second element.
            #expect(!read.labels.contains { $0.localizedCaseInsensitiveContains("moon") }, "\(read.described)")
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
