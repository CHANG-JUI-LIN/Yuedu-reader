import Testing
import UIKit
@testable import yuedu_app

/// Phase 1.5 fixture suite — box-layout cases that the legacy CoreText engine
/// needs special patches for, computed here naturally from containing blocks.
struct BrowserLayoutFixtureTests {

    /// SUCCESS GATE: the .outer/.inner 80%-width case. Every box derives from
    /// containing-block math — no "if 80% container → patch paragraph indent"
    /// style special cases.
    @Test func nestedContainingBlockDerivation() async throws {
        let css = """
        body { margin: 0; }
        .outer { width: 80%; margin: 20px auto; padding: 12px; border: 2px solid; }
        .inner { width: 50%; margin-left: auto; padding: 8px; }
        .inner p { margin: 0; }
        """
        let html = """
        <html><head><style>\(css)</style></head><body>
        <div class="outer"><div class="inner"><p>Text</p></div></div>
        </body></html>
        """
        let (pages, _) = try await BrowserLayoutTestSupport.layout(html, width: 300)
        // CSS `width` is the CONTENT box width:
        // outer: content 80% of 300 = 240; border-box 240+24+4 = 268;
        //   auto margins → (300-268)/2 = 16 each.
        // inner: containing block = outer content (240). content 50% = 120;
        //   padding 8 → border-box 136. margin-left auto → leftover
        //   240 - 136 = 104 → inner border-box starts at 16+2+12+104 = 134.
        // Text line sits inside inner content: x = 134 + 8(padding) = 142.
        // Y: outer's margin-top 20 collapses with the body's top margin (body
        // has no border/padding) into the BODY's block-start margin (max(8,20)
        // = 20) — the folded margin now pushes the content down (the walker
        // honors the root block-start margin). Line top =
        // 20(margin) + 2(border) + 12(padding) + 8(padding) = 42.
        let textFragments = BrowserLayoutTestSupport.allTextFragments(pages)
        #expect(textFragments.count == 1)
        let line = try #require(textFragments.first)
        #expect(line.rect.minX == 142)
        #expect(line.rect.minY == 42)
        // inner content width 120 → the line is laid out within it.
        #expect(line.rect.width <= 120.01)
    }

    @Test func borderAndPaddingBlockParentChildMarginCollapse() async throws {
        // Parent has padding → child's top margin does NOT collapse out.
        let css = ".outer { padding: 10px; } .child { margin-top: 20px; margin-bottom: 0; }"
        let html = """
        <html><head><style>\(css)</style></head><body>
        <div class="outer"><div class="child">Text</div></div>
        </body></html>
        """
        let (pages, _) = try await BrowserLayoutTestSupport.layout(html)
        let line = try #require(BrowserLayoutTestSupport.allTextFragments(pages).first)
        // Parent padding 10 → child margin 20 does not collapse out of the
        // parent; the UA body margin (8) now applies (root block-start margin
        // honored by the walker). Line top = 8 + 10 + 20 = 38.
        #expect(line.rect.minY == 38)
    }

    @Test func positiveNegativeSiblingMarginCollapse() async throws {
        // A bottom -10, B top 20 → collapse = -10 + 20 = 10.
        let css = """
        .a { margin: 0 0 -10px 0; } .b { margin: 20px 0 0 0; }
        """
        let html = """
        <html><head><style>\(css)</style></head><body>
        <p class="a">A</p><p class="b">B</p>
        </body></html>
        """
        let (pages, _) = try await BrowserLayoutTestSupport.layout(html)
        let fragments = BrowserLayoutTestSupport.allTextFragments(pages)
        #expect(fragments.count == 2)
        let a = fragments[0]
        let b = fragments[1]
        #expect(abs(b.rect.minY - (a.rect.maxY + 10)) < 0.01)

        // Both negative: collapse = more negative (min). A bottom -30, B top -10 → -30.
        let css2 = """
        .a { margin: 0 0 -30px 0; } .b { margin: -10px 0 0 0; }
        """
        let html2 = """
        <html><head><style>\(css2)</style></head><body>
        <p class="a">A</p><p class="b">B</p>
        </body></html>
        """
        let (pages2, _) = try await BrowserLayoutTestSupport.layout(html2)
        let f2 = BrowserLayoutTestSupport.allTextFragments(pages2)
        #expect(abs(f2[1].rect.minY - (f2[0].rect.maxY - 30)) < 0.01)
    }

    @Test func multiLineTextCrossesPagesWithCorrectLocalCoords() async throws {
        let text = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 12)
        let html = "<html><body><p>\(text)</p></body></html>"
        let (pages, doc) = try await BrowserLayoutTestSupport.layout(html, width: 220, height: 100)
        #expect(pages.count >= 3)
        for page in pages {
            for fragment in BrowserLayoutTestSupport.allTextFragments([page]) {
                // Every fragment must be within the page's content area.
                #expect(fragment.rect.minX >= 0)
                #expect(fragment.rect.minY >= -0.01)
                #expect(fragment.rect.maxY <= 100.01)
                #expect(fragment.rect.maxX <= 220.01)
            }
        }
        // No text lost across page boundaries (final block-edge space trimmed).
        let visible = BrowserLayoutTestSupport.visibleText(pages, sourceText: doc.lastSourceText)
        #expect(visible == text.trimmingCharacters(in: .whitespaces))
    }

    @Test func inlineAndBlockImagesGeometry() async throws {
        let inline = BrowserLayoutTestSupport.makeImage(size: CGSize(width: 30, height: 15), color: .red)
        let block = BrowserLayoutTestSupport.makeImage(size: CGSize(width: 150, height: 50), color: .blue)
        let html = """
        <html><body>
        <p>Before <img src="i.png"> after</p>
        <img src="b.png" style="display: block">
        <p>After</p>
        </body></html>
        """
        let (pages, doc) = try await BrowserLayoutTestSupport.layout(html, imageLoader: { src in
            src == "i.png" ? inline : (src == "b.png" ? block : nil)
        })
        let images = BrowserLayoutTestSupport.allImageFragments(pages)
        let texts = BrowserLayoutTestSupport.allTextFragments(pages)
        #expect(images.count == 2)
        let inlineImage = try #require(images.first { $0.rect.height == 15 })
        let blockImage = try #require(images.first { $0.rect.height == 50 })
        // Inline image is inside the first paragraph's line box (baseline-aligned).
        let before = try #require(texts.first)
        #expect(abs(inlineImage.rect.maxY - before.baselineY) < 0.5)
        // Block image occupies its own slot between the paragraphs.
        #expect(before.rect.maxY <= blockImage.rect.minY)
        #expect(texts.last!.rect.minY >= blockImage.rect.maxY)
        // Text intact.
        #expect(BrowserLayoutTestSupport.visibleText(pages, sourceText: doc.lastSourceText) == "Before  afterAfter")
    }

    @Test func linkAcrossPagesHitRegionsMatchFragments() async throws {
        let text = String(repeating: "linked words ", count: 40)
        let html = """
        <html><body><p><a href="http://example.com/x">\(text)</a></p></body></html>
        """
        let (pages, _) = try await BrowserLayoutTestSupport.layout(html, width: 200, height: 70)
        let linked = BrowserLayoutTestSupport.allTextFragments(pages).filter { $0.linkTarget != nil }
        #expect(pages.count >= 2)
        #expect(linked.count >= 2)
        // Every fragment's own rect IS its hit region: its center and edges hit it.
        for fragment in linked {
            let center = CGPoint(x: fragment.rect.midX, y: fragment.rect.midY)
            #expect(fragment.rect.contains(center))
            #expect(fragment.rect.rect.intersects(fragment.rect.rect))
        }
    }
}
