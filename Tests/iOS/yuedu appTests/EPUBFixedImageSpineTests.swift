import Testing
import UIKit
import WebKit
@testable import yuedu_app

struct EPUBFixedImageSpineTests {
    @Test @MainActor
    func directJPEGSpineLoadsAsVisibleImageInsteadOfBinaryText() async throws {
        let sample = EPUBTestFixtures.fixedImageSpine()
        let url = try await EPUBTestFixtures.makeArchive(entries: sample.entries)
        let session = try await PublicationSession.open(sourceURL: url)
        #expect(session.chapters.map(\.mediaType) == ["image/jpeg"])

        let renderer = EPUBPageRenderer()
        renderer.load(
            publicationSession: session,
            bookIdentifier: "fixed-image-spine-fixture",
            renderSize: CGSize(width: 390, height: 700),
            settings: EPUBTestFixtures.renderSettings()
        )
        for _ in 0..<400 {
            if renderer.isCoreTextReady { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        let engine = try #require(renderer.engine)
        let controller = try #require(
            engine.pageViewController(at: 0) as? FixedLayoutPageViewController
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        controller.view.layoutIfNeeded()
        let webView = try #require(findWebView(in: controller.view))

        var observation = ""
        for _ in 0..<60 {
            if let value = try? await webView.evaluateJavaScript(
                "document.images.length + ':' + Array.from(document.images).filter(i => i.complete && i.naturalWidth > 0).length + ':' + document.body.innerText.trim().length + ':' + (document.images[0]?.src || '')"
            ) as? String {
                observation = value
                if value.hasPrefix("1:1:0:data:image/jpeg;base64,") { break }
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        #expect(observation.hasPrefix("1:1:0:data:image/jpeg;base64,"))
    }

    @MainActor
    private func findWebView(in view: UIView) -> WKWebView? {
        if let webView = view as? WKWebView { return webView }
        for subview in view.subviews {
            if let webView = findWebView(in: subview) { return webView }
        }
        return nil
    }
}
