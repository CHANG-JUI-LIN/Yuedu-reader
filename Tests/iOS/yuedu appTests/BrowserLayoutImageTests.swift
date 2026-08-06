import Testing
import UIKit
@testable import yuedu_app

/// Replaced elements: intrinsic size, width/height, aspect ratio, max-width:100%,
/// inline atomic boxes and block images. Uses in-memory images (no network).
struct BrowserLayoutImageTests {

    private func loader(_ images: [String: UIImage]) -> (String) -> UIImage? {
        { src in images[src] }
    }

    @Test func inlineImageSitsInsideTextLine() async throws {
        let img = BrowserLayoutTestSupport.makeImage(size: CGSize(width: 20, height: 10), color: .red)
        let html = """
        <html><body><p>Before <img src="dot.png"> after</p></body></html>
        """
        let (pages, doc) = try await BrowserLayoutTestSupport.layout(
            html, imageLoader: loader(["dot.png": img])
        )
        let images = BrowserLayoutTestSupport.allImageFragments(pages)
        let texts = BrowserLayoutTestSupport.allTextFragments(pages)
        #expect(images.count == 1)
        #expect(!texts.isEmpty)
        let imageRect = images[0].rect
        // Intrinsic size honored: 20×10.
        #expect(abs(imageRect.width - 20) < 0.01)
        #expect(abs(imageRect.height - 10) < 0.01)
        // Baseline aligned: bottom sits at the first text line's baseline area.
        let firstText = try #require(texts.first)
        #expect(abs(imageRect.maxY - firstText.baselineY) < 0.5)
    }

    @Test func widthAndHeightOverrideWithAspect() async throws {
        let img = BrowserLayoutTestSupport.makeImage(size: CGSize(width: 200, height: 100), color: .blue)
        // width: 80px → height preserved ratio 80×40.
        let html = """
        <html><body><p><img src="wide.png" style="width: 80px"></p></body></html>
        """
        let (pages, _) = try await BrowserLayoutTestSupport.layout(html, imageLoader: loader(["wide.png": img]))
        let images = BrowserLayoutTestSupport.allImageFragments(pages)
        #expect(images.count == 1)
        #expect(abs(images[0].rect.width - 80) < 0.01)
        #expect(abs(images[0].rect.height - 40) < 0.01)
    }

    @Test func maxWidth100PercentClampsToContainer() async throws {
        // Intrinsic 600×300 in a 200-wide paragraph → clamped to 200×100.
        let img = BrowserLayoutTestSupport.makeImage(size: CGSize(width: 600, height: 300), color: .green)
        let html = """
        <html><body><p><img src="big.png" style="max-width: 100%"></p></body></html>
        """
        let (pages, _) = try await BrowserLayoutTestSupport.layout(html, width: 200, imageLoader: loader(["big.png": img]))
        let images = BrowserLayoutTestSupport.allImageFragments(pages)
        #expect(images.count == 1)
        #expect(abs(images[0].rect.width - 200) < 0.01)
        #expect(abs(images[0].rect.height - 100) < 0.01)
    }

    @Test func blockImageBecomesOwnBlock() async throws {
        let img = BrowserLayoutTestSupport.makeImage(size: CGSize(width: 120, height: 60), color: .purple)
        let html = """
        <html><body><p>Text above</p><img src="blk.png" style="display: block"><p>Text below</p></body></html>
        """
        let (pages, doc) = try await BrowserLayoutTestSupport.layout(html, imageLoader: loader(["blk.png": img]))
        let images = BrowserLayoutTestSupport.allImageFragments(pages)
        let texts = BrowserLayoutTestSupport.allTextFragments(pages)
        #expect(images.count == 1)
        #expect(abs(images[0].rect.width - 120) < 0.01)
        #expect(abs(images[0].rect.height - 60) < 0.01)
        // Block image occupies its own vertical slot between the two paragraphs.
        let first = try #require(texts.first)
        let last = try #require(texts.last)
        #expect(first.rect.maxY <= images[0].rect.minY)
        #expect(images[0].rect.maxY <= last.rect.minY)
        // Text intact.
        #expect(BrowserLayoutTestSupport.visibleText(pages, sourceText: doc.lastSourceText) == "Text aboveText below")
    }

    @Test func blockImageMovesToNextPageWhenNotFit() async throws {
        let img = BrowserLayoutTestSupport.makeImage(size: CGSize(width: 50, height: 90), color: .orange)
        // One line of text (~20pt) then a 90pt image with page height 100:
        // 20 + 90 = 110 > 100 → the image moves wholesale to page 2.
        let html = """
        <html><body><p>Hi</p><img src="tall.png" style="display: block"></body></html>
        """
        let (pages, _) = try await BrowserLayoutTestSupport.layout(html, height: 100, imageLoader: loader(["tall.png": img]))
        let images = BrowserLayoutTestSupport.allImageFragments(pages)
        #expect(pages.count == 2)
        #expect(images.count == 1)
        // The image lands at the TOP of page 1, within page bounds.
        #expect(images[0].rect.minY == 0)
        #expect(images[0].rect.maxY <= 100.01)
    }

    /// Regression: the inline-image CTRunDelegate's refCon (AtomicInlineBox)
    /// must outlive the layout scope. The CTLine (retained on TextFragment)
    /// keeps the delegate alive long after `layoutInline` returns; touching
    /// the line must not hit a freed box (EXC_BAD_ACCESS in
    /// getAscent/getWidth). passRetained + dealloc-takeRetainedValue pairs.
    @Test func inlineImageCTLineDelegateSurvivesLayoutScope() async throws {
        let img = BrowserLayoutTestSupport.makeImage(size: CGSize(width: 20, height: 10), color: .red)
        let html = """
        <html><body><p>Before <img src="dot.png"> after</p></body></html>
        """
        // Run the layout and keep ONLY the produced pages/fragments — the
        // layout's local box-holder array is released when layoutInline
        // returns; the CTLine on the fragments is the only thing keeping the
        // CTRunDelegate (and thus the box) alive.
        let (pages, _) = try await BrowserLayoutTestSupport.layout(
            html, imageLoader: loader(["dot.png": img])
        )
        // Every text fragment sharing a line with the inline image carries the
        // SAME CTLine, which holds the CTRunDelegate for the \u{FFFC} image run.
        let texts = BrowserLayoutTestSupport.allTextFragments(pages)
        #expect(!texts.isEmpty)
        var exercised = 0
        for fragment in texts {
            guard let line = fragment.ctLine else { continue }
            // Force the delegate callbacks: typographic bounds visit every run
            // (image run's getAscent/getDescent/getWidth). This crashed before
            // the passRetained fix.
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            #expect(width >= 0)
            #expect(ascent >= 0)
            _ = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
            exercised += 1
        }
        #expect(exercised > 0, "expected at least one CTLine to exercise")
    }
}
