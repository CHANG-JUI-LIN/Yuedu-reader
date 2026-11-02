import SwiftUI
import Testing
import UIKit
@testable import yuedu_app

/// The bottom bar's 閱讀進度 slider (`ReaderProgressSlider`) with no finger on it.
///
/// On the iOS 26.5 simulator a SwiftUI `Slider` took a `valueChanged` that arrives with no finger —
/// the one iOS 26 sends as the thumb settles after release, and the one VoiceOver's swipe up / down
/// sends (`UISliderAccessibility _accessibilityBumpValue:` is `setValue(_:animated:)` plus
/// `valueChanged`) — as a scrub that never ended: the preview stayed on at that value and nothing
/// moved the reader. The first test replays that event; the others are VoiceOver's adjustment
/// itself, which moves a chapter.
@Suite("Reader chapter slider", .serialized)
@MainActor
struct ReaderChapterSliderTests {
    private final class Reader {
        var progress = 0.5
        var applied: [Double] = []
        var nextChapters = 0
        var previousChapters = 0
    }

    private func bar(_ reader: Reader, canGoNext: Bool = true) -> ReaderModernBottomControlBar {
        ReaderModernBottomControlBar(
            readerTheme: .white,
            overlayContentMaxWidth: .infinity,
            canGoPrevChapter: true,
            canGoNextChapter: canGoNext,
            progressText: "",
            chapterSliderProgressValue: { reader.progress },
            applyChapterSliderProgress: { reader.applied.append($0); reader.progress = $0 },
            chapterTitleForProgress: { _ in "" },
            isCurrentPageBookmarked: false,
            onPrevChapter: { reader.previousChapters += 1 },
            onNextChapter: { reader.nextChapters += 1 },
            onOpenTOC: {},
            onOpenSettings: {},
            onListen: {},
            onToggleDarkMode: {},
            onOpenBookmarks: {},
            onToggleBookmark: {},
            moreActions: []
        )
    }

    /// Hosts `bar` in a window and hands `body` its 閱讀進度 element, as VoiceOver finds it.
    private func withSlider(in bar: ReaderModernBottomControlBar,
                            body: (UISlider, UIView) async throws -> Void) async throws {
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

        let root = UIHostingController(rootView: bar)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }

        func element(in object: NSObject) -> NSObject? {
            if object.isAccessibilityElement {
                return object.accessibilityLabel == localized("閱讀進度") ? object : nil
            }
            let children = (object.accessibilityElements as? [NSObject]) ?? (object as? UIView)?.subviews ?? []
            return children.lazy.compactMap(element(in:)).first
        }
        let deadline = ContinuousClock.now + .seconds(5)
        var found = element(in: root.view)
        while found == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            found = element(in: root.view)
        }
        let slider = try #require(found as? UISlider, "閱讀進度 never reached the accessibility tree as a slider")
        #expect(slider.accessibilityTraits.contains(.adjustable))
        try await body(slider, root.view)
    }

    @Test("a valueChanged with no finger on the slider neither scrubs nor moves the reader")
    func valueChangedWithoutTouchIsNoScrub() async throws {
        let reader = Reader()
        try await withSlider(in: bar(reader)) { slider, host in
            #expect(slider.accessibilityValue == "50%")
            slider.setValue(0.9, animated: false)
            slider.sendActions(for: .valueChanged)
            // Whatever that changed is drawn after this pass.
            host.setNeedsLayout()
            host.layoutIfNeeded()
            #expect(slider.accessibilityValue == "50%")
            #expect(slider.value == 0.5)
            #expect(reader.applied.isEmpty)
        }
    }

    @Test("VoiceOver's swipe up and down move a chapter")
    func voiceOverAdjustsByChapter() async throws {
        let reader = Reader()
        try await withSlider(in: bar(reader)) { slider, _ in
            slider.accessibilityIncrement()
            #expect(reader.nextChapters == 1)
            slider.accessibilityDecrement()
            #expect(reader.previousChapters == 1)
            #expect(reader.applied.isEmpty)
        }
    }

    @Test("at the last chapter VoiceOver's swipe up does nothing")
    func voiceOverStopsAtTheEnd() async throws {
        let reader = Reader()
        try await withSlider(in: bar(reader, canGoNext: false)) { slider, _ in
            slider.accessibilityIncrement()
            #expect(reader.nextChapters == 0)
            #expect(reader.applied.isEmpty)
        }
    }
}
