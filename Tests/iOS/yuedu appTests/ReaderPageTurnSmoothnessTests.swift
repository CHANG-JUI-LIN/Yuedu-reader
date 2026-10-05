import Testing
import UIKit
@testable import yuedu_app

/// What a 2026-10-05 device trace found behind dropped frames in tapped and swiped
/// page turns, pinned so it cannot quietly come back.
@Suite("Reader page turn smoothness", .serialized)
@MainActor
struct ReaderPageTurnSmoothnessTests {
    @Test("UIKit's curl tap-to-turn is off, its curl pan is not")
    func curlTapRecognizerIsDisabled() {
        let curl = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal)
        _ = curl.view
        let taps = curl.gestureRecognizers.filter { $0 is UITapGestureRecognizer }
        #expect(!taps.isEmpty, "UIKit no longer gives a curl controller a tap recognizer")
        #expect(taps.allSatisfy { $0.isEnabled })

        PageViewControllerPagingAdapterDescriptor(pageTurnStyle: .curl).disableBuiltInTapToTurn(on: curl)

        #expect(taps.allSatisfy { !$0.isEnabled })
        let pans = curl.gestureRecognizers.filter { $0 is UIPanGestureRecognizer }
        #expect(!pans.isEmpty)
        #expect(pans.allSatisfy { $0.isEnabled })
    }

    @Test("the frame-rate request lasts while any turn still holds it")
    func frameRateRequestIsHeldUntilTheLastTurnEnds() {
        let request = ReaderTurnFrameRateRequest()
        #expect(!request.isActive)
        request.begin()
        request.begin()
        request.end()
        #expect(request.isActive)
        request.end()
        #expect(!request.isActive)
        // An unpaired end must not leave the next turn without its request.
        request.end()
        request.begin()
        #expect(request.isActive)
        request.end()
        #expect(!request.isActive)
    }

    @Test("a prefetched page goes on screen as that bitmap, and it is what drawing paints")
    func prefetchedPageIsShownWithoutDrawing() async throws {
        let engine = try await makeLaidOutEngine()
        engine.prefetchPageImages(around: 2)
        await engine.finishPageImagePrefetches()

        let window = UIWindow(frame: CGRect(origin: .zero, size: Self.size))
        let shown = try displayedContents(of: engine.pageViewController(at: 3), in: window)
        // A cache hit hands back the prefetched bitmap itself.
        let prefetched = try #require(engine.renderSnapshot(forPage: 3)?.cgImage)
        #expect(shown === prefetched)

        // Page 6 was never prefetched, so its view draws it; the prefetch rendered
        // afterwards must be the same picture.
        let drawn = try displayedContents(of: engine.pageViewController(at: 6), in: window)
        engine.prefetchPageImages(around: 6)
        await engine.finishPageImagePrefetches()
        let rendered = try #require(engine.renderSnapshot(forPage: 6)?.cgImage)
        #expect(drawn !== rendered)
        #expect(pixels(of: drawn) == pixels(of: rendered))
    }

    @Test("a page built before its prefetch landed still shows the prefetched bitmap")
    func pageBuiltBeforeItsPrefetchShowsIt() async throws {
        let engine = try await makeLaidOutEngine()
        // UIKit builds the next page the moment a turn lands, before its render is done.
        let controller = engine.pageViewController(at: 4)
        engine.prefetchPageImages(around: 4)
        await engine.finishPageImagePrefetches()

        let window = UIWindow(frame: CGRect(origin: .zero, size: Self.size))
        let shown = try displayedContents(of: controller, in: window)
        let prefetched = try #require(engine.renderSnapshot(forPage: 4)?.cgImage)
        #expect(shown === prefetched)
    }

    @Test("a page built before an appearance change never takes a bitmap rendered after it")
    func pageKeepsItsOwnLayoutAcrossAppearanceChange() async throws {
        let engine = try await makeLaidOutEngine()
        let controller = engine.pageViewController(at: 4)
        engine.applyThemeChange(textColor: .white, backgroundColor: .black)
        engine.prefetchPageImages(around: 4)
        await engine.finishPageImagePrefetches()
        let dark = try #require(engine.renderSnapshot(forPage: 4)?.cgImage)

        let window = UIWindow(frame: CGRect(origin: .zero, size: Self.size))
        let shown = try displayedContents(of: controller, in: window)
        #expect(shown !== dark)
        #expect(pixels(of: shown) != pixels(of: dark), "the page still shows the layout it was built with")
    }

    @Test("a bookmarked page's snapshot carries the ribbon, so the live page draws itself")
    func bookmarkedSnapshotIsNotTheLivePage() async throws {
        let engine = try await makeLaidOutEngine()
        engine.pageBarsProvider = { _ in
            ReaderPageBars(header: nil, footer: nil, headerTopOffset: 0, footerBottomOffset: 0, isBookmarked: true)
        }
        engine.refreshPageBars()
        engine.prefetchPageImages(around: 2)
        await engine.finishPageImagePrefetches()

        let window = UIWindow(frame: CGRect(origin: .zero, size: Self.size))
        let shown = try displayedContents(of: engine.pageViewController(at: 3), in: window)
        let snapshot = try #require(engine.renderSnapshot(forPage: 3)?.cgImage)
        #expect(shown !== snapshot)
        #expect(pixels(of: shown) != pixels(of: snapshot), "the live page shows its ribbon as a view")
    }

    @Test("a prefetch from before an appearance change is never shown")
    func stalePrefetchIsNotShown() async throws {
        let engine = try await makeLaidOutEngine()
        engine.prefetchPageImages(around: 2)
        await engine.finishPageImagePrefetches()
        let light = try #require(engine.renderSnapshot(forPage: 3)?.cgImage)

        engine.applyThemeChange(textColor: .white, backgroundColor: .black)
        let window = UIWindow(frame: CGRect(origin: .zero, size: Self.size))
        let shown = try displayedContents(of: engine.pageViewController(at: 3), in: window)
        #expect(shown !== light)
        #expect(pixels(of: shown) != pixels(of: light))
    }

    // MARK: - Fixture

    private func makeLaidOutEngine() async throws -> CoreTextPageEngine {
        let engine = CoreTextPageEngine(
            attributedBuilder: TurnSmoothnessFixtureBuilder(),
            renderSettings: Self.settings,
            offsetStore: CharOffsetStore(directoryURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("TurnSmoothness-\(UUID().uuidString)"))
        )
        await engine.start(renderSize: Self.size, bookId: UUID().uuidString)
        await engine.preloadChapter(at: 0)
        // The engine starts with dynamic UIKit colours; pin both.
        engine.applyThemeChange(textColor: .black, backgroundColor: .white)
        #expect(engine.totalPages > 8)
        return engine
    }

    /// What the page view put in its layer, once on screen at the render size.
    private func displayedContents(of controller: UIViewController, in window: UIWindow) throws -> CGImage {
        window.rootViewController = controller
        window.isHidden = false
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        let pageView = try #require(controller.view.subviews.compactMap { $0 as? CoreTextPageView }.first)
        #expect(pageView.bounds.size == Self.size)
        pageView.layer.displayIfNeeded()
        let contents = try #require(pageView.layer.contents)
        return contents as! CGImage
    }

    private func pixels(of image: CGImage) -> Data? {
        UIImage(cgImage: image).pngData()
    }

    private static let size = CGSize(width: 360, height: 560)
    private static let settings = ReaderRenderSettings(
        theme: "light", textColor: .black, backgroundColor: .white,
        fontSize: 18, lineHeightMultiple: 1.4, lineSpacing: 4, paragraphSpacing: 6,
        letterSpacing: 0, marginH: 24, marginV: 16, footerHeight: 16,
        contentInsets: UIEdgeInsets(top: 24, left: 24, bottom: 48, right: 24)
    )
}

private actor TurnSmoothnessFixtureBuilder: AttributedStringBuilding {
    nonisolated var chapterCount: Int { 1 }
    nonisolated var prefersLazyByteScan: Bool { true }
    private let text = String(repeating: "風穿過山林，江水映著月光，行人仍沿著古道前進。\n", count: 600)
    nonisolated func chapterTitle(at index: Int) -> String { "Fixture" }
    func chapterDataSize(at index: Int) -> Int { text.utf8.count }
    func buildChapter(at index: Int, settings: ReaderRenderSettings,
                      themeTextColor: UIColor, themeBackgroundColor: UIColor) async throws -> AttributedChapterBuildResult {
        AttributedChapterBuildResult(attributedString: NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: settings.fontSize),
            .foregroundColor: themeTextColor, .backgroundColor: themeBackgroundColor
        ]), imagePage: nil, pageBackgroundImage: nil, anchorOffsets: [:])
    }
}
