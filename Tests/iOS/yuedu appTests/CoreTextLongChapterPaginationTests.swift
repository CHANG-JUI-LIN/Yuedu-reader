import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// Crashlytics 7d6c4b95 (MetricKit cpu-exception): one 857,793-character chapter took
/// 27.8 s in `coreText.fullLayout` on an iPhone 15 Plus because every page re-bridged
/// the whole chapter's NSString to a Swift String — O(characters × pages).
/// Pagination of a single long chapter has to grow linearly with its length.
@Suite("CoreText long chapter pagination", .serialized)
struct CoreTextLongChapterPaginationTests {
    private static let renderSize = CGSize(width: 390, height: 844)

    @Test("Paginating one long chapter scales linearly with its length")
    @MainActor
    func longChapterPaginationIsLinear() async {
        let shortCount = 100_000
        let longCount = shortCount * 4

        // Warm CoreText's font caches so the first measurement is not penalised.
        _ = await layout(characterCount: 5_000)

        let short = await layout(characterCount: shortCount)
        let long = await layout(characterCount: longCount)

        let ratio = long.milliseconds / max(short.milliseconds, 1)
        print("⏱ longChapter short=\(shortCount)ch \(Int(short.milliseconds))ms pages=\(short.pages) long=\(longCount)ch \(Int(long.milliseconds))ms pages=\(long.pages) ratio=\(String(format: "%.2f", ratio))")

        // The event's chapter, for before/after milliseconds (simulator on a Mac, not a phone).
        let event = await layout(characterCount: 857_793)
        print("⏱ longChapter event=\(event.characters)ch \(Int(event.milliseconds))ms pages=\(event.pages)")

        #expect(long.pages > short.pages * 3)
        // Linear work gives ≈4×; the per-page whole-string bridge grows toward 16×.
        #expect(ratio < 6, "4× the text took \(String(format: "%.1f", ratio))× the time")
    }

    /// The same event's second half: a reader closed mid-layout kept laying the chapter out
    /// for 30 s, side by side with the reopened reader's pass. Cancelling the caller has to
    /// stop the detached computation, and what it stopped with must not be cached.
    @Test("Cancelling a full pagination stops it early and keeps it out of the cache")
    @MainActor
    func cancelledPaginationStopsAndIsNotCached() async {
        let attributedString = await Self.chapter(characterCount: 400_000)
        let paginator = CoreTextPaginator()
        let revision = ContentRevision()
        let shared = LayoutShared(attributedString)

        let cancelled = Task { @MainActor in
            await paginator.paginate(
                spineIndex: 0,
                attrStr: shared.wrappedValue,
                renderSize: Self.renderSize,
                fontSize: 17,
                revision: revision
            )
        }
        cancelled.cancel()
        let stopped = await cancelled.value
        #expect(stopped.isPartial)

        let full = await paginator.paginate(
            spineIndex: 0,
            attrStr: attributedString,
            renderSize: Self.renderSize,
            fontSize: 17,
            revision: revision
        )
        #expect(!full.isPartial)
        #expect(full.pageRanges.count > stopped.pageRanges.count)
        #expect(full.pageRanges.last.map { $0.location + $0.length } == attributedString.length)
    }

    @MainActor
    private func layout(characterCount: Int) async -> (milliseconds: Double, pages: Int, characters: Int) {
        let attributedString = await Self.chapter(characterCount: characterCount)
        let paginator = CoreTextPaginator()
        let start = ProcessInfo.processInfo.systemUptime
        let layout = await paginator.paginate(
            spineIndex: 0,
            attrStr: attributedString,
            renderSize: Self.renderSize,
            fontSize: 17,
            revision: ContentRevision()
        )
        let milliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
        return (milliseconds, layout.pageRanges.count, attributedString.length)
    }

    /// One chapter built the way a web-novel chapter is: paragraphs of CJK text, through the
    /// production HTML pipeline, so the attributed string's backing store, fonts and
    /// paragraph styles are the ones CoreText sees on device.
    ///
    /// Adjacent CJK marks (`。」`, `，「`) are left out on purpose: they make CoreText's own
    /// typesetter creation superlinear on the simulator (TCompositionEngine::AdjustSpacing,
    /// 13.5 s for 857,790 characters), which would swamp the page loop this test measures.
    /// On device the event's chapter built its typesetter inside an 882 ms first page.
    private static func chapter(characterCount: Int) async -> NSAttributedString {
        let paragraph = "他抬起頭看見城牆上的旗幟在風中翻捲他知道這一戰他們必須贏下來眾人沉默片刻後隨即齊聲應和。"
        let paragraphCount = max(1, characterCount / (paragraph.utf16.count + 1))
        let body = String(repeating: "<p>\(paragraph)</p>", count: paragraphCount)
        return await EPUBTestFixtures.renderIR(
            html: EPUBTestFixtures.xhtml(title: "long", body: body),
            config: EPUBTestFixtures.htmlConfig(renderWidth: renderSize.width)
        )
    }
}
