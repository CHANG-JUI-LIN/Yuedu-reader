import Foundation
import Testing
import UIKit
@testable import yuedu_app

struct EPUBMixedLayoutRoutingTests {
    @Test @MainActor
    func itemOverrideUsesFixedControllerBetweenReflowableSpines() async throws {
        let sample = EPUBTestFixtures.mixedLayout()
        let url = try await EPUBTestFixtures.makeArchive(entries: sample.entries)
        let session = try await PublicationSession.open(sourceURL: url)

        #expect(session.layoutMode == .reflowable)
        #expect(session.chapters.map(\.layoutModeOverride) == [nil, .prePaginated, nil])

        let renderer = EPUBPageRenderer()
        renderer.load(
            publicationSession: session,
            bookIdentifier: "mixed-layout-fixture",
            renderSize: CGSize(width: 390, height: 700),
            settings: EPUBTestFixtures.renderSettings()
        )
        for _ in 0..<400 {
            if renderer.isCoreTextReady { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(renderer.isCoreTextReady)
        #expect(renderer.requiresPagedLayout)
        let engine = try #require(renderer.engine)
        #expect(engine is MixedLayoutPageEngine)

        // CoreText intentionally lays out chapters lazily. Preload the trailing prose so this
        // contract verifies real child controllers without forcing production to paginate an
        // entire book at startup.
        await engine.preloadChapter(at: 2)

        let before = engine.pageViewController(for: .chapterStart(0))
        let painting = engine.pageViewController(for: .chapterStart(1))
        let after = engine.pageViewController(for: .chapterStart(2))

        #expect(before is CoreTextPageViewController)
        #expect(painting is FixedLayoutPageViewController)
        #expect(after is CoreTextPageViewController)

        let fixedGlobalPage = try #require(engine.pageIndex(for: .chapterStart(1)))
        #expect(engine.readingPosition(forPage: fixedGlobalPage)?.spineIndex == 1)
        let fixedLocal = engine.localPosition(for: fixedGlobalPage)
        #expect(fixedLocal.spineIndex == 1)
        #expect(fixedLocal.localPage == 0)

        let beforeLast = try #require(engine.lastPageIndex(ofChapter: 0))
        let fixedPage = try #require(engine.pageIndex(for: .chapterStart(1)))
        let afterFirst = try #require(engine.pageIndex(for: .chapterStart(2)))
        #expect(fixedPage == beforeLast + 1)
        #expect(beforeLast > 0)
        #expect(afterFirst == fixedPage + 1)
        let fixedOffset = engine.charOffset(forPage: fixedPage)
        #expect(fixedOffset.spineIndex == 1)
        #expect(fixedOffset.charOffset == 0)
    }
}
