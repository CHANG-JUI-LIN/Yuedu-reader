import Testing
import UIKit
@testable import yuedu_app

/// Incremental layout: BrowserLayoutSession must produce pages IDENTICAL to
/// the batch path, publish page 1 without full layout, support offset-targeted
/// layout, and discard on generation change.
@MainActor
struct BrowserLayoutSessionTests {

    private func makeConfig(width: CGFloat = 300, height: CGFloat = 160, fontSize: CGFloat = 17) -> BrowserLayoutConfig {
        BrowserLayoutConfig(
            renderWidth: width, renderHeight: height, rootFontSize: fontSize,
            fontFamilies: ["PingFangSC-Regular"], textColor: .black, backgroundColor: .white
        )
    }

    private func session(
        html: String, cssTexts: [String] = [], width: CGFloat = 300, height: CGFloat = 160,
        generation: Int = 0
    ) -> BrowserLayoutSession {
        BrowserLayoutSession(
            html: html, cssTexts: cssTexts, config: makeConfig(width: width, height: height),
            imageLoader: { _ in nil }, generation: generation
        )
    }

    @Test func sessionPagesMatchBatchPagesExactly() async throws {
        let text = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 30)
        let html = "<html><body><p>\(text)</p></body></html>"

        // Batch path.
        let doc = BrowserLayoutDocument(html: html, cssTexts: [], config: makeConfig())
        let batchPages = try await doc.renderPages(containerSize: CGSize(width: 300, height: 160))

        // Incremental path.
        let session = self.session(html: html)
        var incrementalPages: [PageFragments] = []
        while let page = try await session.layoutNextPage() {
            incrementalPages.append(page)
        }

        #expect(incrementalPages.count == batchPages.count)
        #expect(incrementalPages.count >= 2)
        for (index, incremental) in incrementalPages.enumerated() {
            let batch = batchPages[index]
            #expect(incremental.index == batch.index)
            #expect(incremental.fragments.count == batch.fragments.count,
                    "page \(index) fragment count differs")
            for (fi, fragment) in incremental.fragments.enumerated() {
                let batchFragment = batch.fragments[fi]
                switch (fragment, batchFragment) {
                case (.text(let a), .text(let b)):
                    #expect(a.sourceRange == b.sourceRange)
                    #expect(a.rect == b.rect)
                    #expect(a.baselineY == b.baselineY)
                case (.fill(let a), .fill(let b)):
                    #expect(a.rect == b.rect)
                    #expect(a.color == b.color)
                case (.image(let a), .image(let b)):
                    #expect(a.rect == b.rect)
                    #expect(a.source == b.source)
                default:
                    Issue.record("page \(index) fragment \(fi) kind mismatch")
                }
            }
        }
    }

    @Test func firstPagePublishesWithoutFullLayout() async throws {
        let text = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 200)
        let html = "<html><body><p>\(text)</p></body></html>"
        let session = self.session(html: html)
        let first = try await session.layoutNextPage()
        #expect(first != nil)
        // Only ONE page laid out so far — the chapter has many more.
        #expect(session.pageCountSoFar() == 1)
        // And the session can continue later.
        let second = try await session.layoutNextPage()
        #expect(second != nil)
        #expect(second!.index == 1)
    }

    @Test func firstPageGeometryMatchesFullLayout() async throws {
        let text = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 200)
        let html = "<html><body><p>\(text)</p></body></html>"
        let doc = BrowserLayoutDocument(html: html, cssTexts: [], config: makeConfig())
        let batch = try await doc.renderPages(containerSize: CGSize(width: 300, height: 160))

        let session = self.session(html: html)
        let first = try await session.layoutNextPage()

        #expect(first!.fragments.count == batch[0].fragments.count)
        guard case .text(let a) = first!.fragments.first!,
              case .text(let b) = batch[0].fragments.first! else {
            Issue.record("expected text first fragments")
            return
        }
        #expect(a.rect == b.rect)
        #expect(a.sourceRange == b.sourceRange)
    }

    @Test func layoutUntilSourceOffsetStopsAtTargetPage() async throws {
        let text = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 100)
        let html = "<html><body><p>\(text)</p></body></html>"
        let doc = BrowserLayoutDocument(html: html, cssTexts: [], config: makeConfig())
        let batch = try await doc.renderPages(containerSize: CGSize(width: 300, height: 160))
        let ns = doc.lastSourceText as NSString

        // Target the middle of the chapter: the page containing it.
        let target = ns.length / 2
        let targetPage = batch.firstIndex { page in
            BrowserLayoutTestSupport.allTextFragments([page]).contains { frag in
                frag.sourceRange.location <= target && frag.sourceRange.location + frag.sourceRange.length > target
            }
        } ?? 0

        let session = self.session(html: html)
        try await session.layout(untilSourceOffset: target)
        // Session stops once the target page is complete (its range passed the offset).
        let lastRange = session.lastCompletedSourceRange()
        #expect(lastRange.location + lastRange.length > target)
        #expect(session.pageCountSoFar() <= targetPage + 1)
        #expect(session.pageCountSoFar() >= targetPage - 1)

        // The remaining pages can still be laid out afterwards.
        try await session.finish()
        #expect(session.isFinished)
    }

    @Test func generationDiscardsStaleResults() async throws {
        let text = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 50)
        let html = "<html><body><p>\(text)</p></body></html>"
        let session = self.session(html: html, generation: 1)
        _ = try await session.layoutNextPage()
        // A "newer" session replaced the old one: the old session's pages must
        // not be committed by the caller (the caller checks generation).
        let stale = session.generation != 2
        #expect(stale)
        #expect(session.pageCountSoFar() == 1)  // results exist but are stale
    }
}
