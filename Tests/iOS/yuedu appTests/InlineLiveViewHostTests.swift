import Foundation
import Testing
import UIKit
import WebKit
@testable import yuedu_app

/// The live-view host both reading modes share (2026-10-10): a tapped `<iframe>` page is shown
/// in place, leaves with its page and comes back as the same loaded page, and only one page is
/// ever live.
@Suite("Inline live view host", .serialized)
@MainActor
struct InlineLiveViewHostTests {

    private static func host() throws -> (InlineLiveViewHost, UIViewController, UIWindow) {
        let owner = UIViewController()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = owner
        window.makeKeyAndVisible()
        return (InlineLiveViewHost(owner: owner), owner, window)
    }

    private static func webViews(in view: UIView) -> [WKWebView] {
        view.subviews.flatMap { ($0 as? WKWebView).map { [$0] } ?? webViews(in: $0) }
    }

    @Test("a web embed loads only when started, survives leaving the screen, and is the only live page")
    func webEmbedLifecycle() throws {
        defer { ReaderWebEmbedManager.shared.stopAll() }
        let (host, owner, window) = try Self.host()
        defer { window.isHidden = true }
        let first = ReaderWebEmbed(src: "https://player.example/embed/1", title: "一", referer: "https://book.example/1")
        let second = ReaderWebEmbed(src: "https://player.example/embed/2", title: "二", referer: nil)
        let frame = CGRect(x: 20, y: 100, width: 350, height: 200)

        // On screen but not started: nothing is loaded.
        host.reconcile([(content: .web(first), frame: frame)])
        #expect(host.count == 0)
        #expect(!ReaderWebEmbedManager.shared.isActive(first))

        host.start(.web(first), frame: frame)
        #expect(host.count == 1)
        let loaded = try #require(Self.webViews(in: owner.view).first)

        // Scrolled or turned away: the window goes, the page stays loaded.
        host.reconcile([])
        #expect(host.count == 0)
        #expect(ReaderWebEmbedManager.shared.isActive(first))

        // Back on screen: the same page, not a reload.
        host.reconcile([(content: .web(first), frame: frame)])
        #expect(host.count == 1)
        #expect(Self.webViews(in: owner.view).first === loaded)

        // Starting another closes the first — and its window goes too, rather than leaving an
        // empty frame over the first card that would swallow the tap to restart it.
        let secondFrame = frame.offsetBy(dx: 0, dy: 240)
        host.reconcile([(content: .web(first), frame: frame), (content: .web(second), frame: secondFrame)])
        host.start(.web(second), frame: secondFrame)
        #expect(ReaderWebEmbedManager.shared.isActive(second))
        #expect(!ReaderWebEmbedManager.shared.isActive(first))
        #expect(host.count == 1)
        #expect(!owner.view.subviews.contains { $0.frame == frame })

        // The app leaving the foreground closes the page and removes its window.
        ReaderWebEmbedManager.shared.stopAll()
        #expect(host.count == 0)
    }
}
