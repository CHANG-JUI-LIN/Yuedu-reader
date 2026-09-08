import Testing
import UIKit
@testable import yuedu_app

@Suite("EPUB legacy routing", .serialized)
@MainActor
struct EPUBLegacyRoutingTests {
    @Test("opening and reopening EPUB renders through legacy")
    func openingAndReopeningUsesLegacy() async throws {
        let url = try await EPUBTestFixtures.makeArchive(entries: EPUBTestFixtures.proseSmoke().entries)
        let session = try await PublicationSession.open(sourceURL: url)
        let bookID = UUID().uuidString
        for _ in 0..<2 {
            let renderer = EPUBPageRenderer()
            // Defer the renderer's UI startup so this test can await the engine's
            // actual load completion without polling or a timing-based delay.
            renderer.load(publicationSession: session, bookIdentifier: bookID,
                          renderSize: .zero, settings: EPUBTestFixtures.renderSettings())
            let engine = try #require(renderer.engine as? CoreTextPageEngine)
            await engine.start(renderSize: CGSize(width: 320, height: 480), bookId: bookID)
            #expect(engine.totalPages > 0)
            #expect(engine.chapterText(forSpine: 0)?.contains("Simple prose paragraph.") == true)
            let position = CoreTextReadingPosition(spineIndex: 0, charOffset: 8)
            engine.updateReadingPosition(position)
            #expect(engine.pageIndex(for: position) != nil)
            #expect(renderer.engine is CoreTextPageEngine)
        }
    }

    @Test("entering scroll and returning to pages retains legacy")
    func scrollAndPagedShareLegacy() async throws {
        let url = try await EPUBTestFixtures.makeArchive(entries: EPUBTestFixtures.proseSmoke().entries)
        let session = try await PublicationSession.open(sourceURL: url)
        let renderer = EPUBPageRenderer()
        let bookID = UUID().uuidString
        renderer.load(publicationSession: session, bookIdentifier: bookID,
                      renderSize: .zero, settings: EPUBTestFixtures.renderSettings())
        let engine = try #require(renderer.engine as? CoreTextPageEngine)
        let scrollEngine = try #require(renderer.scrollEngine)
        await engine.start(renderSize: CGSize(width: 320, height: 480), bookId: bookID)
        await scrollEngine.start(initialChapter: 0, contentWidth: 320, viewportExtent: 480)
        #expect(scrollEngine.isReady)
        #expect(renderer.engine as? CoreTextPageEngine === engine)
        #expect(engine.pageIndex(for: .chapterStart(0)) != nil)
        #expect(engine.chapterText(forSpine: 0)?.contains("Simple prose paragraph.") == true)
    }
}
