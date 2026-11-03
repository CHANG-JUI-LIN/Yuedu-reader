import SwiftUI
import Testing
import UIKit
@testable import yuedu_app

/// Hosts `view` in a window, with the accessibility elements VoiceOver would find built, and
/// hands `body` the hosting view.
@MainActor
func withAccessibilityHost<V: View>(in view: V,
                                    body: (UIView) async throws -> Void) async throws {
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
    defer { window.isHidden = true; window.rootViewController = nil }
    try await body(root.view)
}

/// The elements VoiceOver steps through under `object`, in order.
@MainActor
func accessibilityElements(in object: NSObject) -> [NSObject] {
    if object.isAccessibilityElement { return [object] }
    let children = (object.accessibilityElements as? [NSObject]) ?? (object as? UIView)?.subviews ?? []
    return children.flatMap(accessibilityElements(in:))
}

/// Hosts `view` in a window and hands `body` its slider as VoiceOver finds it: the accessibility
/// element that is a `UISlider`. The view holds one.
@MainActor
func withAccessibleSlider<V: View>(in view: V,
                                   body: (UISlider, UIView) async throws -> Void) async throws {
    try await withAccessibilityHost(in: view) { host in
        @MainActor func slider() -> UISlider? {
            accessibilityElements(in: host).lazy.compactMap { $0 as? UISlider }.first
        }
        let deadline = ContinuousClock.now + .seconds(5)
        var found = slider()
        while found == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            found = slider()
        }
        let element = try #require(found, "the slider never reached the accessibility tree")
        #expect(element.accessibilityTraits.contains(.adjustable))
        try await body(element, host)
    }
}

/// Draws what the last change did.
@MainActor
func settle(_ host: UIView) {
    host.setNeedsLayout()
    host.layoutIfNeeded()
}

/// Draws what the last change did, then reports whether `condition` holds — at once, or once a
/// change made outside the view (a model the view observes) has reached it.
@MainActor
func eventually(_ host: UIView, within timeout: Duration = .seconds(2),
                _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while true {
        settle(host)
        if condition() { return true }
        if ContinuousClock.now >= deadline { return false }
        // Throws only when the test is cancelled, which ends the wait as a failure.
        do { try await Task.sleep(for: .milliseconds(20)) } catch { return false }
    }
}

extension UISlider {
    /// Where the thumb is, as a fraction of the track. A SwiftUI `Slider` keeps its `UISlider`
    /// on 0–1 whatever range it was given; `ScrubSlider` keeps the caller's.
    var fraction: Double {
        Double((value - minimumValue) / (maximumValue - minimumValue))
    }

    /// Puts the thumb at a fraction of the track, as VoiceOver's bump or the settling thumb does.
    func setFraction(_ fraction: Double) {
        setValue(minimumValue + Float(fraction) * (maximumValue - minimumValue), animated: false)
    }
}
