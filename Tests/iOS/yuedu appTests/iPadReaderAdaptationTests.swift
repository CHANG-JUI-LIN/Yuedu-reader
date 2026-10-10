import Combine
import SwiftUI
import Testing
import UIKit
import WebKit
@testable import yuedu_app

@Suite("iPad reader adaptation", .serialized)
@MainActor
struct iPadReaderAdaptationTests {
    @Test("左右邊距 is the user's number on iPad: 0 is the page edge, the old column is the slider's top")
    func readableMargins() {
        for width: CGFloat in [320, 480, 600, 820, 1024, 1133, 1366] {
            // No inset is added on top of the user's value any more.
            #expect(ReaderReadableWidthPolicy.effectiveMargin(0, pageWidth: width) == 0)
            #expect(ReaderReadableWidthPolicy.effectiveMargin(24, pageWidth: width) == 24)

            // The slider still reaches the narrow column iPad used to force.
            let upper = ReaderReadableWidthPolicy.sliderUpperBound(
                pageWidth: width, usesReadableWidth: true, defaultMargin: 24
            )
            #expect(upper >= ReaderReadableWidthPolicy.compactUpperBound)
            #expect(width - 2 * upper <= DSLayout.readableCompactWidth)

            // A synced or imported margin never collapses the text column.
            let clamped = ReaderReadableWidthPolicy.effectiveMargin(10_000, pageWidth: width)
            #expect(width - 2 * clamped >= min(width, ReaderReadableWidthPolicy.minimumTextWidth))
        }
        #expect(ReaderReadableWidthPolicy.sliderUpperBound(
            pageWidth: 390, usesReadableWidth: false, defaultMargin: 24
        ) == ReaderReadableWidthPolicy.compactUpperBound)
        // Landscape iPad mini, single page: the reported screenshot's ~270pt band.
        #expect(ReaderReadableWidthPolicy.sliderUpperBound(
            pageWidth: 1133, usesReadableWidth: true, defaultMargin: 24
        ) == 271)
    }

    @Test("double-column sheets retain native curl and mirror the outer spine", arguments: [false, true])
    func doubleColumnCurl(isRTL: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = CoreTextPageEngine(
            attributedBuilder: MockAttributedStringBuilder(texts: [String(repeating: "iPad reading spread 測試翻頁。\n", count: 300)]),
            renderSettings: EPUBTestFixtures.renderSettings(),
            offsetStore: CharOffsetStore(directoryURL: directory)
        )
        await engine.start(renderSize: CGSize(width: 500, height: 700), bookId: UUID().uuidString)
        try #require(engine.totalPages >= 4)
        let reader = CoreTextPageEngineView(
            engine: engine, pageTurnStyle: .curl, theme: .white, playbackHighlight: nil,
            isRTL: isRTL, isDoublePageSpread: true, spreadGutter: DSLayout.readerSpreadGutter,
            sessionCoordinator: nil, externalTargetVersion: 0, externalTargetPosition: nil,
            pageTurnCommand: nil, clearExternalTargetPosition: {}, currentPage: .constant(0),
            onPageChanged: { _, _ in }, onTapZone: { _ in }
        )
        let host = UIHostingController(rootView: reader)
        let window = try show(host, size: CGSize(width: 1028, height: 700))
        defer { window.isHidden = true; window.rootViewController = nil }
        let pvc = try #require(controllers(host).compactMap { $0 as? UIPageViewController }.first)
        #expect(pvc.transitionStyle == .pageCurl)
        #expect(pvc.spineLocation == (isRTL ? .max : .min))
        #expect(!pvc.isDoubleSided)
        let spread = try #require(pvc.viewControllers?.first as? ReaderSpreadPageViewController)
        #expect(pvc.viewControllers?.count == 1)
        #expect(spread.pageViewControllers.count == 2)
        #expect(spread.globalPageIndex == 0)
        let next = isRTL
            ? pvc.dataSource?.pageViewController(pvc, viewControllerBefore: spread)
            : pvc.dataSource?.pageViewController(pvc, viewControllerAfter: spread)
        let nextSpread = try #require(next as? ReaderSpreadPageViewController)
        #expect(nextSpread.globalPageIndex == 2)
        let finished = await withCheckedContinuation { continuation in
            pvc.setViewControllers([nextSpread], direction: isRTL ? .reverse : .forward, animated: true) {
                continuation.resume(returning: $0)
            }
        }
        #expect(finished)
        #expect((pvc.viewControllers?.first as? ReaderSpreadPageViewController)?.globalPageIndex == 2)
        let previous = isRTL
            ? pvc.dataSource?.pageViewController(pvc, viewControllerAfter: nextSpread)
            : pvc.dataSource?.pageViewController(pvc, viewControllerBefore: nextSpread)
        #expect((previous as? ReaderSpreadPageViewController)?.globalPageIndex == 0)
    }

    @Test("source browser uses a mobile viewport and keeps the bottom submit control reachable", .timeLimit(.minutes(1)))
    func mobileLoginViewport() async throws {
        let bridge = JsBridgeBrowserBridge()
        let browser = JsBridgeBrowserRepresentable(
            urlString: "https://example.com/login", initialHTML: """
            <html><head><meta name="viewport" content="width=device-width,initial-scale=1">
            <style>html,body{margin:0;height:100%;overflow:hidden}button{position:fixed;bottom:0;left:20px;width:120px;height:44px}</style>
            </head><body><input aria-label="Account"><button id="submit" onclick="this.dataset.clicked='yes'">Confirm</button></body></html>
            """, injectedJavaScript: "", sourceRunHandler: nil,
            sourceConfigurationUpdateHandler: nil, bridge: bridge
        )
        let host = UIHostingController(rootView: NavigationStack {
            browser.navigationTitle("Login").toolbarTitleDisplayMode(.inline)
        })
        let window = try show(host, size: CGSize(width: 820, height: 1180))
        defer { window.isHidden = true; window.rootViewController = nil }
        let web = try #require(views(host.view).compactMap { $0 as? WKWebView }.first)
        var observation: AnyCancellable?
        await withCheckedContinuation { continuation in
            observation = bridge.$phase.filter { $0 == .finished || $0 == .failed }.first().sink { _ in
                continuation.resume()
            }
        }
        observation?.cancel()
        #expect(bridge.phase == .finished)
        #expect(web.configuration.defaultWebpagePreferences.preferredContentMode == .mobile)
        #expect(web.customUserAgent == SourceWebIdentity.phoneUserAgent)
        let frame = web.convert(web.bounds, to: host.view)
        #expect(frame.maxY <= host.view.bounds.maxY - host.view.safeAreaInsets.bottom + 1)
        let reachable = try await web.evaluateJavaScript("""
        (() => {const b=document.getElementById('submit');const r=b.getBoundingClientRect();
        return r.bottom<=innerHeight && document.elementFromPoint(r.x+r.width/2,r.y+r.height/2)===b;})()
        """) as? Bool
        #expect(reachable == true)
    }

    @Test("fixed reader controls use native bars at full and split window widths", arguments: [CGFloat(390), 820, 1180])
    func fixedPageNativeToolbar(width: CGFloat) async throws {
        let state = FixedPageReaderState()
        state.chapterTitle = "Chapter 206"
        state.chapterListItems = FixedPageChapterListItem.items(from: [.init(index: 0, title: "Chapter 206", url: "")])
        state.totalPages = 78
        var jumpedPage: Int?
        state.onJumpToPage = { jumpedPage = $0 }
        let host = VisibleReaderControlsHost(rootView: NavigationStack {
            FixedPageReaderControlsOverlay(state: state, onClose: {}, onOpenTouchZoneEditor: {})
                .toolbarTitleDisplayMode(.inline)
        })
        let window = try show(host, size: CGSize(width: width, height: 1180))
        defer { window.isHidden = true; window.rootViewController = nil }
        await host.waitUntilVisible()
        host.view.layoutIfNeeded()
        let bar = try #require(views(host.view).compactMap { $0 as? UINavigationBar }.first)
        #expect(!bar.isHidden)
        let item = try #require(bar.topItem)
        #expect(item.title == "Chapter 206")
        let leadingItems = item.leadingItemGroups.flatMap(\.barButtonItems) + (item.leftBarButtonItems ?? [])
        let trailingItems = item.trailingItemGroups.flatMap(\.barButtonItems) + (item.rightBarButtonItems ?? [])
        #expect(leadingItems.count >= 2)
        #expect(trailingItems.count >= 1)
        #expect(bar.frame.height >= DSLayout.minimumTapTarget)
        // Newer iPadOS uses a floating system bar rather than a UIToolbar view.
        // Verify the visible progress control and its interaction, not a private bar hierarchy.
        let slider = try #require(views(host.view).compactMap { $0 as? UISlider }.first)
        #expect(slider.bounds.width > width / 2)
        let frame = slider.convert(slider.bounds, to: host.view)
        #expect(frame.minX >= 0)
        #expect(frame.maxX <= host.view.bounds.width)
        #expect(frame.minY >= host.view.bounds.height - DSLayout.minimumTapTarget * 2)
        #expect(frame.maxY <= host.view.bounds.height - host.view.safeAreaInsets.bottom)
        let hit = host.view.hitTest(CGPoint(x: frame.midX, y: frame.midY), with: nil)
        #expect(hit === slider || hit?.isDescendant(of: slider) == true)
        // SwiftUI can normalize the underlying UISlider range to 0...1.
        slider.value = slider.minimumValue + (slider.maximumValue - slider.minimumValue) * 10 / 77
        slider.sendActions(for: .valueChanged)
        // Plain forward progress: a right-to-left book mirrors the track, not the value.
        #expect(jumpedPage == 10)

    }

    private func show(_ host: UIViewController, size: CGSize) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        return window
    }

    private func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
    private func controllers(_ vc: UIViewController) -> [UIViewController] { [vc] + vc.children.flatMap(controllers) }
}


@MainActor
private final class VisibleReaderControlsHost<Content: View>: UIHostingController<Content> {
    private var isVisible = false
    private var appearance: CheckedContinuation<Void, Never>?

    func waitUntilVisible() async {
        guard !isVisible else { return }
        await withCheckedContinuation { appearance = $0 }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isVisible = true
        appearance?.resume()
        appearance = nil
    }
}
