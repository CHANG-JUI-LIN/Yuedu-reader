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
        // Linear work gives ≈4×; measured 4.7× on iOS 27.2, 4.9× on 26.5 and 5.5× on 17.5.
        // The per-page whole-string bridge grew toward 16×, and one typesetter for the whole
        // chapter took 9.3× on iOS 27.2 (325 ms → 3,022 ms) and 11× on 26.5.
        #expect(ratio < 7, "4× the text took \(String(format: "%.1f", ratio))× the time")
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

    /// One chapter built the way a web-novel chapter is: paragraphs of CJK dialogue, through
    /// the production HTML pipeline, so the attributed string's backing store, fonts,
    /// paragraph styles and punctuation kerns are the ones CoreText sees on device.
    ///
    /// The adjacent marks (`。」`, `：「`) matter: the squeeze kerns on them make one
    /// typesetter for the whole chapter grow far faster than its length (simulator, iOS 27.2:
    /// 5.2 s for 400k characters, 16.6 s for 857k; worse on iOS 26.5), which is why a long
    /// chapter is laid out in windows (`CoreTextChapterFramesetter`). The event's own chapter
    /// was an audio drama's listing and built its typesetter inside an 882 ms first page, so
    /// it says nothing about how a device handles dialogue.
    private static func chapter(characterCount: Int) async -> NSAttributedString {
        let paragraph = "「你來了。」他抬起頭，看見城牆上的旗幟在風中翻捲，低聲說道：「這一戰我們必須贏下來。」眾人沉默片刻，隨即齊聲應和。"
        let paragraphCount = max(1, characterCount / (paragraph.utf16.count + 1))
        let body = String(repeating: "<p>\(paragraph)</p>", count: paragraphCount)
        return await EPUBTestFixtures.renderIR(
            html: EPUBTestFixtures.xhtml(title: "long", body: body),
            config: EPUBTestFixtures.htmlConfig(renderWidth: renderSize.width)
        )
    }
}
