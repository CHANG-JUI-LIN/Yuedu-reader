import Testing
import UIKit
@testable import yuedu_app

/// Scroll mode is the SAME layout as paged mode with one fragmentainer instead
/// of many. These tests hold that line: continuous flow, no page breaks, no
/// slicing of content into layout units, and a tile is only a window.
@MainActor
struct BrowserScrollDocumentTests {

    private static func pipeline(
        _ html: String,
        width: CGFloat = 300,
        insets: UIEdgeInsets = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12),
        imageLoader: ((String) -> UIImage?)? = nil
    ) throws -> (BrowserLayoutDocument.BrowserLayoutPipelineResult, CGFloat, UIEdgeInsets) {
        var config = BrowserLayoutConfig(
            renderWidth: width, renderHeight: 400, rootFontSize: 17,
            fontFamilies: ["PingFangSC-Regular"], textColor: .black, backgroundColor: .white
        )
        config.contentInsets = insets
        let doc = BrowserLayoutDocument(
            html: html, cssTexts: [], config: config, imageLoader: imageLoader
        )
        let result = try doc.makeLayout(
            containerSize: CGSize(width: width + insets.left + insets.right, height: 400)
        )
        return (result, width, insets)
    }

    private static func scrollDocument(
        _ html: String,
        width: CGFloat = 300,
        insets: UIEdgeInsets = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    ) throws -> BrowserScrollDocument {
        let (result, w, i) = try pipeline(html, width: width, insets: insets)
        return BrowserScrollDocument.make(
            pipeline: result, contentWidth: w, contentInsets: i
        )
    }

    private static let longHTML: String = {
        let paragraphs = (0..<40).map {
            "<p>Paragraph \($0): the quick brown fox jumps over the lazy dog, repeatedly and at length.</p>"
        }.joined()
        return "<html><body>\(paragraphs)</body></html>"
    }()

    // MARK: - Continuous flow

    /// The defining property: content that would occupy many pages produces ONE
    /// continuous flow. If this ever regresses into multiple fragmentainers, the
    /// scroll reader is paginating again.
    @Test func longChapterIsOneContinuousFlow() throws {
        let document = try Self.scrollDocument(Self.longHTML)
        let texts = document.displayList.items.compactMap { item -> DisplayTextItem? in
            if case .text(let t) = item { return t }
            return nil
        }
        #expect(texts.count > 40, "expected the whole chapter, got \(texts.count) text items")

        // Document-space y increases monotonically across the WHOLE chapter.
        // With pagination it would reset to the top of every page.
        var previousY = -CGFloat.greatestFiniteMagnitude
        var resets = 0
        for t in texts {
            if t.rect.minY < previousY - 0.5 { resets += 1 }
            previousY = max(previousY, t.rect.minY)
        }
        #expect(resets == 0, "content restarted \(resets) times — the flow was paginated")
    }

    /// The chapter is far taller than one viewport: the flow is bounded by its
    /// own content, not by a page.
    @Test func contentHeightIsTheWholeChapterNotAViewport() throws {
        let document = try Self.scrollDocument(Self.longHTML)
        #expect(document.contentHeight > 400 * 3,
                "chapter height \(document.contentHeight) looks like a page, not a chapter")

        // Every item sits inside the reported height — nothing overflows the
        // scroll extent (which would be unreachable content).
        let maxBottom = document.displayList.items.reduce(CGFloat(0)) { acc, item in
            switch item {
            case .text(let t): return max(acc, t.rect.maxY)
            case .fill(let f): return max(acc, f.rect.maxY)
            case .image(let i): return max(acc, i.rect.maxY)
            }
        }
        #expect(maxBottom <= document.contentHeight + 0.5,
                "content reaches \(maxBottom) but the scroll extent is \(document.contentHeight)")
    }

    /// Paged and scroll modes must agree on the text: the same chapter, the same
    /// characters, in the same order. Only the fragmentainer differs.
    @Test func scrollFlowCarriesTheSameTextAsPagedLayout() async throws {
        let width: CGFloat = 300
        let insets = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        let scroll = try Self.scrollDocument(Self.longHTML, width: width, insets: insets)

        var config = BrowserLayoutConfig(
            renderWidth: width, renderHeight: 400 - insets.top - insets.bottom,
            rootFontSize: 17, fontFamilies: ["PingFangSC-Regular"],
            textColor: .black, backgroundColor: .white
        )
        config.contentInsets = insets
        let pagedDoc = BrowserLayoutDocument(html: Self.longHTML, cssTexts: [], config: config)
        let pages = try await pagedDoc.renderPages(
            containerSize: CGSize(width: width + insets.left + insets.right, height: 400)
        )
        #expect(pages.count > 1, "the fixture must actually paginate in paged mode")

        let pagedText = BrowserLayoutTestSupport.visibleText(pages, sourceText: pagedDoc.lastSourceText)
        let scrollText = scroll.displayList.items.compactMap { item -> String? in
            if case .text(let t) = item { return t.text }
            return nil
        }.joined()
        #expect(scrollText == pagedText, "scroll and paged disagree about the chapter text")
    }

    // MARK: - Tiles are windows, not layout

    /// A tile shows the items that intersect it, translated — and asking for a
    /// window never changes the document.
    @Test func tileReturnsIntersectingItemsInTileLocalCoordinates() throws {
        let document = try Self.scrollDocument(Self.longHTML)
        let before = document.displayList.items.count

        let tile = CGRect(x: 0, y: 600, width: 324, height: 400)
        let windowed = document.items(in: tile)
        #expect(!windowed.items.isEmpty, "a tile in the middle of the chapter drew nothing")

        for item in windowed.items {
            guard case .text(let t) = item else { continue }
            // Tile-local: an item at document y=600 sits at tile y=0.
            #expect(t.rect.maxY > -1 && t.rect.minY < 401,
                    "item at \(t.rect.rawValue) is outside the tile it was returned for")
        }
        #expect(document.displayList.items.count == before,
                "windowing mutated the document")
    }

    /// Adjacent tiles reproduce the document exactly once: no item is dropped
    /// between them, and an item straddling the seam appears in both (a window
    /// clips, it does not cut content in half).
    @Test func adjacentTilesCoverTheDocumentWithoutLoss() throws {
        let document = try Self.scrollDocument(Self.longHTML)
        let tileHeight: CGFloat = 300

        var seen = Set<String>()
        var y: CGFloat = 0
        while y < document.contentHeight {
            let tile = CGRect(x: 0, y: y, width: 324, height: tileHeight)
            for item in document.items(in: tile).items {
                guard case .text(let t) = item, t.sourceRange.length > 0 else { continue }
                seen.insert("\(t.sourceRange.location):\(t.sourceRange.length)")
            }
            y += tileHeight
        }

        var all = Set<String>()
        for item in document.displayList.items {
            guard case .text(let t) = item, t.sourceRange.length > 0 else { continue }
            all.insert("\(t.sourceRange.location):\(t.sourceRange.length)")
        }
        #expect(seen == all,
                "tiling lost \(all.subtracting(seen).count) item(s) and invented \(seen.subtracting(all).count)")
    }

    // MARK: - Position mapping

    @Test func documentYAndCharOffsetRoundTrip() throws {
        let document = try Self.scrollDocument(Self.longHTML)
        let ns = document.sourceText as NSString
        #expect(ns.length > 0)

        let probe = ns.length / 2
        let y = document.documentY(forCharOffset: probe)
        #expect(y > 0, "a mid-chapter offset resolved to the very top")

        let restored = document.charOffset(atDocumentY: y)
        let restoredY = document.documentY(forCharOffset: restored)
        #expect(abs(restoredY - y) < 1,
                "offset \(probe) → y \(y) → offset \(restored) → y \(restoredY)")
    }

    /// Anchors resolve through the same source-offset map paged mode uses, so a
    /// TOC entry or a link target lands at the right scroll position.
    @Test func anchorResolvesToItsScrollPosition() throws {
        let html = """
        <html><body>
        \((0..<30).map { "<p>Filler paragraph \($0) with enough text to take a line or two.</p>" }.joined())
        <p id="target">The anchored paragraph.</p>
        </body></html>
        """
        let document = try Self.scrollDocument(html)
        let offset = try #require(document.anchorOffsets["target"])
        let y = document.documentY(forCharOffset: offset)
        #expect(y > 200, "the anchor sits far down the chapter but resolved to y=\(y)")
        #expect(y <= document.contentHeight)
    }

    // MARK: - Links

    @Test func linkRegionsAreBuiltOnceForTheWholeChapter() throws {
        let html = """
        <html><body>
        <p><a href="#a">First link</a></p>
        \((0..<30).map { "<p>Filler paragraph \($0) with enough text to take a line or two.</p>" }.joined())
        <p><a href="#b">Last link</a></p>
        </body></html>
        """
        let document = try Self.scrollDocument(html)
        let regions = document.interactionRegions(spineIndex: 4)
        #expect(regions.regions.count >= 2)
        #expect(Set(regions.regions.map(\.href)) == ["#a", "#b"])
        #expect(regions.regions.allSatisfy { $0.spineIndex == 4 })

        // Regions are in DOCUMENT space, so the far link is far down — a tile
        // hit-tests by offsetting the touch point, never by rebuilding regions.
        let last = try #require(regions.regions.first { $0.href == "#b" })
        #expect(last.pageLocalRect.minY > 200,
                "the trailing link resolved to \(last.pageLocalRect) — regions look page-local, not document-local")
        #expect(regions.hitTest(CGPoint(x: last.pageLocalRect.midX, y: last.pageLocalRect.midY))?.href == "#b")
    }
}
