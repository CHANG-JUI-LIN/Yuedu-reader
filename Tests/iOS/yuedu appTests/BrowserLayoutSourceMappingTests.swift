import Testing
import UIKit
@testable import yuedu_app

/// Source mapping + anonymous block ordering.
struct BrowserLayoutSourceMappingTests {

    @Test func interleavedInlineBlockInlinePreservesOrder() async throws {
        let html = """
        <html><body><div>
        Lead <span>mid</span>
        <div class="b">Block</div>
        <span>tail</span> End
        </div></body></html>
        """
        let (pages, doc) = try await BrowserLayoutTestSupport.layout(html)
        // All text fragments in order → exactly the visible text with no loss/dup/reorder.
        // CSS trims whitespace at anonymous-block edges: "Lead mid" | "Block" | "tail End".
        let visible = BrowserLayoutTestSupport.visibleText(pages, sourceText: doc.lastSourceText)
        #expect(visible == "Lead midBlocktail End")
        #expect(BrowserLayoutTestSupport.rangesAreOrdered(pages))
    }

    @Test func sourceRangesReassembleVisibleTextAcrossPages() async throws {
        // Long enough text to span 2 pages (page height 60).
        let text = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 10)
        let html = "<html><body><p>\(text)</p></body></html>"
        let (pages, doc) = try await BrowserLayoutTestSupport.layout(html, width: 200, height: 60)
        #expect(pages.count >= 2)
        let visible = BrowserLayoutTestSupport.visibleText(pages, sourceText: doc.lastSourceText)
        // Every character of the collapsed text is covered by a fragment range,
        // including spaces that fall at line breaks; the final block-edge
        // trailing space is trimmed (CSS).
        #expect(visible == text.trimmingCharacters(in: .whitespaces))
        #expect(BrowserLayoutTestSupport.rangesAreOrdered(pages))
    }

    @Test func fragmentsCarryNodeIdentityAndWritingMode() async throws {
        let html = """
        <html><body><p class="alpha">First</p><p class="beta">Second</p></body></html>
        """
        let (pages, doc) = try await BrowserLayoutTestSupport.layout(html)
        let fragments = BrowserLayoutTestSupport.allTextFragments(pages)
        #expect(fragments.count == 2)
        // The two paragraphs are distinct DOM nodes → distinct node IDs.
        #expect(fragments[0].nodeID != fragments[1].nodeID)
        #expect(fragments[0].writingMode == .horizontal)
        #expect(fragments[1].writingMode == .horizontal)
        // nodeIDs are stable across the tree (each element got one).
        #expect(fragments.allSatisfy { $0.nodeID > 0 })
    }

    @Test func linksCarryTargetAndAnchorOffsets() async throws {
        let html = """
        <html><body>
        <p><a href="http://example.com/x.html" id="intro">Intro text</a></p>
        <p>Middle <a href="http://example.com/y.html">Y link</a> tail</p>
        </body></html>
        """
        let (pages, doc) = try await BrowserLayoutTestSupport.layout(html)
        let fragments = BrowserLayoutTestSupport.allTextFragments(pages)
        let intro = try #require(fragments.first { $0.sourceRange.length > 0 && $0.linkTarget != nil })
        #expect(intro.linkTarget == "http://example.com/x.html")
        #expect(intro.sourceRange.length == 10) // "Intro text"
        let y = try #require(fragments.first { $0.linkTarget == "http://example.com/y.html" })
        #expect(y.sourceRange.length == 6) // "Y link"
        // anchor offset registered for the id="intro" element.
        let anchorOffset = try #require(doc.lastAnchorOffsets["intro"])
        let visiblePrefix = (doc.lastSourceText as NSString).substring(with: NSRange(location: 0, length: anchorOffset))
        #expect(visiblePrefix == "")
    }

    @Test func linkSpanningLinesAndPagesKeepsTarget() async throws {
        let inner = String(repeating: "linked ", count: 30)  // spans multiple lines/pages
        let html = """
        <html><body><p><a href="http://example.com/long">\(inner)</a></p></body></html>
        """
        let (pages, doc) = try await BrowserLayoutTestSupport.layout(html, width: 180, height: 50)
        #expect(pages.count >= 2)
        let fragments = BrowserLayoutTestSupport.allTextFragments(pages)
        let linked = fragments.filter { $0.linkTarget != nil }
        #expect(!linked.isEmpty)
        #expect(linked.allSatisfy { $0.linkTarget == "http://example.com/long" })
        // Every linked fragment's rect is a valid hit region (center inside rect).
        for fragment in linked {
            let center = CGPoint(x: fragment.rect.midX, y: fragment.rect.midY)
            #expect(fragment.rect.contains(center))
        }
        // Ranges are ordered across pages (fragments arrive in source order).
        #expect(BrowserLayoutTestSupport.rangesAreOrdered(pages))
    }
}
