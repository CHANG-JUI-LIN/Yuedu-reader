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

    @Test("仿真 spreads turn one page at a time around the centre spine", arguments: [false, true])
    func doubleColumnCurl(isRTL: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try await spreadEngine(directory: directory) { $0 >= 6 }
        let (pvc, window) = try show(spreadReader(engine: engine, isRTL: isRTL, page: 0))
        defer { window.isHidden = true; window.rootViewController = nil }
        #expect(pvc.transitionStyle == .pageCurl)
        #expect(pvc.spineLocation == .mid)
        #expect(pvc.isDoubleSided)
        // UIKit keeps index 0 on the left whatever the content direction, so an RTL book
        // shows its earlier page second.
        #expect(pageIndices(pvc.viewControllers) == (isRTL ? [1, 0] : [0, 1]))
        let left = try #require(pvc.viewControllers?.first)
        #expect(left.view.convert(left.view.bounds, to: pvc.view).minX == 0)

        // Forward lifts the outer page of the reading side: its back is the next page,
        // and the page under it the one after.
        let outer = try #require(isRTL ? pvc.viewControllers?.first : pvc.viewControllers?.last)
        let back = try #require(forward(from: outer, in: pvc, isRTL: isRTL))
        let front = try #require(forward(from: back, in: pvc, isRTL: isRTL))
        #expect(pageIndices([back, front]) == [2, 3])
        let finished = await withCheckedContinuation { continuation in
            pvc.setViewControllers(
                isRTL ? [front, back] : [back, front],
                direction: isRTL ? .reverse : .forward,
                animated: true
            ) { continuation.resume(returning: $0) }
        }
        #expect(finished)
        #expect(pageIndices(pvc.viewControllers) == (isRTL ? [3, 2] : [2, 3]))

        let inner = try #require(isRTL ? pvc.viewControllers?.last : pvc.viewControllers?.first)
        let previousBack = try #require(backward(from: inner, in: pvc, isRTL: isRTL))
        let previousFront = try #require(backward(from: previousBack, in: pvc, isRTL: isRTL))
        #expect(pageIndices([previousBack, previousFront]) == [1, 0])
        #expect(backward(from: previousFront, in: pvc, isRTL: isRTL) == nil)
    }

    @Test("a book ending on a spread's first page closes it with a blank page", arguments: [false, true])
    func midSpineOddEnd(isRTL: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try await spreadEngine(directory: directory) { $0 >= 5 && $0 % 2 == 1 }
        let last = engine.totalPages - 1
        let (pvc, window) = try show(spreadReader(engine: engine, isRTL: isRTL, page: last))
        defer { window.isHidden = true; window.rootViewController = nil }
        let stack = try #require(pvc.viewControllers)
        #expect(stack.count == 2)
        let blank = try #require(stack.compactMap { $0 as? ReaderSpreadBlankPageViewController }.first)
        #expect(blank.facingPage == last)
        // The blank is on the far side of the reading order: right in LTR, left in RTL.
        #expect((isRTL ? stack.first : stack.last) === blank)
        #expect(pageIndices(stack).compactMap { $0 } == [last])
        // Nothing turns past it, and turning back starts from the page it faces.
        #expect(forward(from: blank, in: pvc, isRTL: isRTL) == nil)
        let lastPage = try #require(isRTL ? stack.last : stack.first)
        let previousBack = try #require(backward(from: lastPage, in: pvc, isRTL: isRTL))
        #expect(pageIndices([previousBack]) == [last - 1])
    }

    @Test("a 載入中 page beside the reading page is swapped in when its chapter lands", arguments: [false, true])
    func midSpinePartnerChapterLands(isRTL: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try await chapterBoundaryEngine(directory: directory)
        // The first chapter ends on a spread's first page, so the next chapter's first
        // page faces it — before that chapter is laid out.
        let last = try #require(engine.layouts[0]?.pageRanges.count) - 1
        let (pvc, window) = try show(spreadReader(engine: engine, isRTL: isRTL, page: last))
        defer { window.isHidden = true; window.rootViewController = nil }
        #expect(pageIndices(pvc.viewControllers) == (isRTL ? [last + 1, last] : [last, last + 1]))
        #expect(pvc.viewControllers?.contains { $0 is PlaceholderPageViewController } == true)

        _ = await engine.preloadChapter(at: 1)
        // The engine's own signal; the coordinator answers it on the next main-queue turn.
        engine.onChapterReady?(1)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }

        let stack = try #require(pvc.viewControllers)
        #expect(!stack.contains { $0 is PlaceholderPageViewController })
        #expect(pageIndices(stack) == (isRTL ? [last + 1, last] : [last, last + 1]))
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

    /// A CoreText engine whose page count satisfies `accepts`, for spreads that must end
    /// on a given parity. Page counts are deterministic for a text, so this tries lengths.
    private func spreadEngine(
        directory: URL,
        accepts: (Int) -> Bool
    ) async throws -> CoreTextPageEngine {
        for lines in stride(from: 300, through: 360, by: 7) {
            let engine = CoreTextPageEngine(
                attributedBuilder: MockAttributedStringBuilder(texts: [String(repeating: "iPad reading spread 測試翻頁。\n", count: lines)]),
                renderSettings: EPUBTestFixtures.renderSettings(),
                offsetStore: CharOffsetStore(directoryURL: directory)
            )
            await engine.start(renderSize: CGSize(width: 500, height: 700), bookId: UUID().uuidString)
            if accepts(engine.totalPages) { return engine }
        }
        throw SpreadEngineUnavailable()
    }

    /// Two chapters, the first fully laid out with an odd page count and the second not
    /// laid out at all, so a spread can straddle the boundary.
    private func chapterBoundaryEngine(directory: URL) async throws -> CoreTextPageEngine {
        for lines in stride(from: 300, through: 360, by: 7) {
            let engine = CoreTextPageEngine(
                attributedBuilder: MockAttributedStringBuilder(texts: [
                    String(repeating: "iPad reading spread 測試翻頁。\n", count: lines),
                    String(repeating: "下一章 next chapter。\n", count: 40),
                ]),
                renderSettings: EPUBTestFixtures.renderSettings(),
                offsetStore: CharOffsetStore(directoryURL: directory)
            )
            await engine.start(renderSize: CGSize(width: 500, height: 700), bookId: UUID().uuidString)
            _ = await engine.preloadChapter(at: 0)
            if let pages = engine.layouts[0]?.pageRanges.count, pages % 2 == 1, engine.layouts[1] == nil {
                return engine
            }
        }
        throw SpreadEngineUnavailable()
    }

    private struct SpreadEngineUnavailable: Error {}

    private func spreadReader(engine: CoreTextPageEngine, isRTL: Bool, page: Int) -> UIHostingController<CoreTextPageEngineView> {
        UIHostingController(rootView: CoreTextPageEngineView(
            engine: engine, pageTurnStyle: .curl, theme: .white, playbackHighlight: nil,
            isRTL: isRTL, isDoublePageSpread: true,
            spreadGutter: PageViewControllerPagingAdapterDescriptor(pageTurnStyle: .curl).spreadGutter,
            sessionCoordinator: nil, externalTargetVersion: 0, externalTargetPosition: nil,
            pageTurnCommand: nil, clearExternalTargetPosition: {}, currentPage: .constant(page),
            onPageChanged: { _, _ in }, onTapZone: { _ in }
        ))
    }

    /// Shows a spread reader in a window two 500pt pages wide, and returns its page view controller.
    private func show(_ host: UIHostingController<CoreTextPageEngineView>) throws -> (UIPageViewController, UIWindow) {
        let window = try show(host, size: CGSize(width: 1000, height: 700))
        let pvc = try #require(controllers(host).compactMap { $0 as? UIPageViewController }.first)
        return (pvc, window)
    }

    /// UIKit's data-source call for turning on in reading order: an RTL book reads on
    /// toward the left, which UIKit calls "before".
    private func forward(from viewController: UIViewController, in pvc: UIPageViewController, isRTL: Bool) -> UIViewController? {
        isRTL
            ? pvc.dataSource?.pageViewController(pvc, viewControllerBefore: viewController)
            : pvc.dataSource?.pageViewController(pvc, viewControllerAfter: viewController)
    }

    private func backward(from viewController: UIViewController, in pvc: UIPageViewController, isRTL: Bool) -> UIViewController? {
        isRTL
            ? pvc.dataSource?.pageViewController(pvc, viewControllerAfter: viewController)
            : pvc.dataSource?.pageViewController(pvc, viewControllerBefore: viewController)
    }

    private func pageIndices(_ viewControllers: [UIViewController]?) -> [Int?] {
        (viewControllers ?? []).map { ($0 as? any PageIndexProviding)?.globalPageIndex }
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
