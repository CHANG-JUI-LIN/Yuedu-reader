import SwiftUI
import UIKit
import XCTest
@testable import yuedu_app

/// Simulator-rendered evidence for the native color controls, reader preview,
/// and accessibility text sizes. Inspect the retained image attachments.
final class ReaderBarEditorRenderingTests: XCTestCase {
    @MainActor
    func testEdgeDistanceControlsAtBothLimits() async throws {
        let settings = GlobalSettings.shared
        let original = settings.readerBarLayout
        defer { _ = settings.saveReaderBarLayout(original) }
        var layout = ReaderBarLayout.default
        layout.edgeDistances = .init(header: 0, footer: 200)
        XCTAssertTrue(settings.saveReaderBarLayout(layout))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let appeared = expectation(description: "Edge distance editor")
        let host = BarEditorHost(rootView: AnyView(
            NavigationStack {
                ReaderBarLayoutEditorView(theme: .white, readerSafeTop: 59, readerSafeBottom: 34)
            }
        ))
        host.onAppearance = { appeared.fulfill() }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }
        await fulfillment(of: [appeared], timeout: 10)
        host.view.layoutIfNeeded()
        func scrollView(in view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height { return scroll }
            return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
        }
        let scroll = try XCTUnwrap(scrollView(in: host.view))
        scroll.setContentOffset(CGPoint(x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)), animated: false)
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "bar-edge-distance-limits"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testColorEditorInLightDarkAndLargeText() async throws {
        let settings = GlobalSettings.shared
        let original = settings.readerBarLayout
        defer { _ = settings.saveReaderBarLayout(original) }
        var custom = ReaderBarLayout.default
        custom.hidesHeaderOnChapterOpening = false
        custom.style.color = .init(source: .custom, hexRGBA: 0x345678FF, darkHexRGBA: 0xB8D8F8FF)
        custom.setColor(.init(source: .custom, hexRGBA: 0xB02020FF, darkHexRGBA: 0xFF8888FF), for: .chapterTitle)
        custom.setColor(.init(source: .custom, hexRGBA: 0x207020FF, darkHexRGBA: 0x88FF88FF), for: .currentTime)
        XCTAssertTrue(settings.saveReaderBarLayout(custom))

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        for (name, theme, scheme, textSize) in [
            ("bar-colors-light", ReaderTheme.white, ColorScheme.light, DynamicTypeSize.large),
            ("bar-colors-dark", ReaderTheme.night, ColorScheme.dark, DynamicTypeSize.large),
            ("bar-colors-large-text", ReaderTheme.night, ColorScheme.dark, DynamicTypeSize.accessibility5)
        ] {
            let appeared = expectation(description: name)
            let host = BarEditorHost(rootView: AnyView(
                NavigationStack {
                    ReaderBarLayoutEditorView(theme: theme)
                }
                .environment(\.colorScheme, scheme)
                .environment(\.dynamicTypeSize, textSize)
            ))
            host.onAppearance = { appeared.fulfill() }
            let window = UIWindow(windowScene: scene)
            window.rootViewController = host
            window.makeKeyAndVisible()
            await fulfillment(of: [appeared], timeout: 10)
            host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            window.isHidden = true
            window.rootViewController = nil
        }
        previousWindow?.makeKeyAndVisible()
    }
}

@MainActor
private final class BarEditorHost: UIHostingController<AnyView> {
    var onAppearance: (() -> Void)?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let callback = onAppearance
        onAppearance = nil
        callback?()
    }
}
