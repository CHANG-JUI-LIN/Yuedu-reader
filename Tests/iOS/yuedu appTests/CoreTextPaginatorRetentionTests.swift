import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// TestFlight AGA6UftGrSZehKw65KigEv8 / Crashlytics 17c788ce, 3.0.2 (154): after an hour of
/// switching chapters, `CTTypesetterCreateWithAttributedStringAndOptions` faulted at 0x30 on
/// two layout threads at the same instruction. The fault is `TASCIIEncoder::Encode` reading a
/// field of the `TRun` that `TGlyphEncoder::EncodeChars` had just asked
/// `_CFRuntimeCreateInstance` for, and that pointer was NULL: the process could no longer
/// allocate a 416-byte object.
///
/// What grew: `CoreTextPaginator` kept every full chapter layout it ever produced — string,
/// framesetter, one `CTFrame` per page, attachments — for the reader's lifetime. Each build of
/// a chapter mints a new `ContentRevision`, so a chapter rebuilt after leaving the document
/// store's eight entries was stored again under a new key, and nothing ever removed either.
/// The engine's own five-chapter `LayoutCache` and its memory-warning purge freed nothing,
/// because the paginator still held the same objects.
@Suite("Paginator layout retention", .serialized)
@MainActor
struct CoreTextPaginatorRetentionTests {
    private static let chapterCount = 30

    private static func chapterText(_ index: Int) -> String {
        String(repeating: "第\(index)章，「這是一段對話。」他說：「好的，我們走吧！」然後一起離開了。\n", count: 120)
    }

    private func makeEngine(paginator: CoreTextPaginator, directory: URL) -> CoreTextPageEngine {
        CoreTextPageEngine(
            attributedBuilder: MockAttributedStringBuilder(texts: (0..<Self.chapterCount).map(Self.chapterText)),
            renderSettings: EPUBTestFixtures.renderSettings(),
            paginationManager: PaginationManager(paginator: paginator),
            offsetStore: CharOffsetStore(directoryURL: directory)
        )
    }

    /// Next chapter, next chapter, … as the reader's chapter buttons do.
    private func readThrough(_ engine: CoreTextPageEngine, chapters: Range<Int>) async {
        for spine in chapters {
            engine.updateReadingPosition(.chapterStart(spine))
            await engine.preloadChapter(at: spine)
        }
    }

    @Test("reading chapter after chapter keeps no more layouts than the document store can reuse")
    func retentionIsBoundedWhileReading() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paginator = CoreTextPaginator()
        let engine = makeEngine(paginator: paginator, directory: directory)
        await engine.start(renderSize: CGSize(width: 390, height: 760), bookId: UUID().uuidString)

        let before = MemoryFootprint.current()
        await readThrough(engine, chapters: 0..<Self.chapterCount)
        // Back and forth over the last stretch: chapters that left the document store are
        // rebuilt under a new revision.
        for spine in stride(from: Self.chapterCount - 1, through: 0, by: -1) {
            engine.updateReadingPosition(.chapterStart(spine))
            await engine.preloadChapter(at: spine)
        }
        let after = MemoryFootprint.current()
        print("⟐ retention chapters=\(Self.chapterCount) kept=\(paginator.cachedLayoutCount) footprintDelta=\(String(format: "%.1f", Double(after - before) / 1_000_000))MB")

        #expect(paginator.cachedLayoutCount <= ChapterDocumentStore.defaultCapacity)
    }

    @Test("a memory warning drops the paginator's layouts along with the engine's")
    func memoryWarningDropsPaginatorLayouts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paginator = CoreTextPaginator()
        let engine = makeEngine(paginator: paginator, directory: directory)
        await engine.start(renderSize: CGSize(width: 390, height: 760), bookId: UUID().uuidString)
        await readThrough(engine, chapters: 0..<4)
        try #require(paginator.cachedLayoutCount > 0)

        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)

        #expect(paginator.cachedLayoutCount == 0)
    }

    @Test("a chapter whose document is still stored is not laid out again")
    func storedDocumentStillHitsTheCache() async throws {
        let paginator = CoreTextPaginator()
        let revision = ContentRevision()
        // The same document as far as the cache can tell: the key is the revision.
        func layout() async -> CoreTextPaginator.ChapterLayout {
            let text = NSAttributedString(string: Self.chapterText(0), attributes: [.font: UIFont.systemFont(ofSize: 18)])
            return await paginator.paginate(spineIndex: 0, attrStr: text, renderSize: CGSize(width: 390, height: 760),
                                     fontSize: 18, revision: revision)
        }
        let first = await layout()
        let second = await layout()
        #expect(first.framesetter === second.framesetter)
    }
}
