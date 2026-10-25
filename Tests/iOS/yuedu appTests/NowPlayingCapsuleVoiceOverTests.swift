import SwiftUI
import Testing
import UIKit
@testable import yuedu_app

/// What VoiceOver says the now-playing capsule's cover does. Narration whose book was closed has
/// no playback panel — no reader on screen drives it — so its cover reopens the book, and the
/// hint says so. In another book's reader the cover used to do nothing while VoiceOver still
/// promised 「打開播放控制面板」. XCUITest cannot read a hint, so this reads the hosting window's
/// own accessibility elements, as VoiceOver does.
@Suite("Now-playing capsule: VoiceOver", .serialized)
@MainActor
struct NowPlayingCapsuleVoiceOverTests {
    /// The capsule's cover is named after what is playing, verbatim.
    private let title = "第十章 玄雅的赔礼"

    @Test func aClosedBooksNarrationReopensTheBook() async throws {
        for placement in [NowPlayingMiniPlayer.Placement.reader, .global] {
            let hint = try await coverHint(in: placement, narrationOutlivesReader: true)
            #expect(hint == localized("打開這本書到正在朗讀的地方"), "\(placement)")
        }
    }

    @Test func theReadersOwnNarrationOpensThePanel() async throws {
        let hint = try await coverHint(in: .reader, narrationOutlivesReader: false)
        #expect(hint == localized("打開播放控制面板"))
    }

    /// The hint VoiceOver reads on the capsule's cover, narration playing on the shared hub the
    /// capsule observes.
    private func coverHint(
        in placement: NowPlayingMiniPlayer.Placement,
        narrationOutlivesReader: Bool
    ) async throws -> String? {
        let hub = NowPlayingHub.shared
        hub.configurePreview(title: title, playbackState: .playing, currentSegmentIndex: 0, totalSegments: 10,
                             holdsNarrationPastReader: narrationOutlivesReader)
        defer {
            hub.configurePreview(title: "", playbackState: .stopped, currentSegmentIndex: 0, totalSegments: 0)
            hub.detachDeallocatedCoordinator()
        }

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

        let root = UIHostingController(rootView: NowPlayingMiniPlayer(placement: placement))
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
        let deadline = ContinuousClock.now + .seconds(5)
        var cover = elements(in: root.view).first { $0.accessibilityLabel == title }
        while cover == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            cover = elements(in: root.view).first { $0.accessibilityLabel == title }
        }
        let found = try #require(cover, "the capsule's cover never reached the accessibility tree")
        return found.accessibilityHint
    }
}
