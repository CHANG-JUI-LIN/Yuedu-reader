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
    /// Regression (画册残片): an inline image taller than the CSS line-height
    /// must EXPAND the line box (CSS 2.1 §10.8 — atomic inline boxes size the
    /// line box), not be squeezed into line-height. Before the fix the line
    /// height took line-height verbatim, so stacked gallery cells advanced by
    /// ~line-height while each 627pt image painted from its own y → all
    /// images overlapped and only top strips were visible.
    @Test func inlineTallImageExpandsLineBoxNotClamped() async throws {
        let img = BrowserLayoutTestSupport.makeImage(size: CGSize(width: 352, height: 627), color: .cyan)
        let html = """
        <html><head><style>
          body { line-height: 23.4px; font-size: 18.9px; }
          .cell img { width: 80%; }
        </style></head><body>
        <div class="cell"><img src="tall.png"></div>
        <div class="cell"><img src="tall.png"></div>
        <div class="cell"><img src="tall.png"></div>
        </body></html>
        """
        let (pages, _) = try await BrowserLayoutTestSupport.layout(html, imageLoader: loader(["tall.png": img]))
        let images = BrowserLayoutTestSupport.allImageFragments(pages)
        #expect(images.count == 3)
        #expect(pages.count == 3)  // each 400pt image owns a full 400pt page
        for image in images {
            // No top strip cut: the whole image sits inside its page.
            #expect(image.rect.minY >= 0)
            #expect(image.rect.maxY <= 400.01)
            // Scaled to fit the page (627 > 400 → 400 tall, aspect kept).
            #expect(abs(image.rect.height - 400) < 0.1)
            #expect(abs(image.rect.width - 224.561) < 0.1)
        }
    }

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

    /// Real 画册 DOM fragment (from the 金陵十二钗 chapter): gallery →
    /// gallery-cell (inline img + maintitle paragraph) → sibling cell. The
    /// image is a 9:16 portrait (intrinsic 900×1600) sized by `width: 90%` of
    /// the body content — 352.8×627.2 on a 392pt content. Two 627.2pt cells
    /// cannot share a page; the second must move to the next page.
    @Test func realGalleryDOMNoOverlapPerPage() async throws {
        let img = BrowserLayoutTestSupport.makeImage(size: CGSize(width: 900, height: 1600), color: .magenta)
        let html = """
        <html><head><style>
        div.duokan-image-gallery-cell img { margin: 0.35em 0; width: 90%; }
        p.duokan-image-maintitle { margin: 1em 0 0; font-size: 0.9em; }
        div.duokan-image-gallery { margin: 0.5em auto; width: 90%; text-align: center; }
        </style></head><body>
        <div class="duokan-image-gallery">
          <div class="duokan-image-gallery-cell"><img src="p1.jpg"/><p class="duokan-image-maintitle">剧照1</p></div>
          <div class="duokan-image-gallery-cell"><img src="p2.jpg"/><p class="duokan-image-maintitle">剧照2</p></div>
          <div class="duokan-image-gallery-cell"><img src="p3.jpg"/><p class="duokan-image-maintitle">剧照3</p></div>
        </div>
        </body></html>
        """
        let (pages, doc) = try await BrowserLayoutTestSupport.layout(
            html, width: 392, height: 842,
            imageLoader: { ["p1.jpg": img, "p2.jpg": img, "p3.jpg": img][$0] }
        )
        let images = BrowserLayoutTestSupport.allImageFragments(pages)
        #expect(images.count == 3)
        // Each image keeps its authored size (90% of 392 → 352.8 wide).
        for image in images {
            #expect(abs(image.rect.width - 352.8) < 0.5)
            #expect(abs(image.rect.height - 627.2) < 1.0)
        }
        // Horizontal placement: gallery is 90% auto-centered; the image equals
        // the cell width (90% of body), so its left edge sits AT the cell
        // origin — NOT double-centered (previous bug: line maxWidth used the
        // body width → extra ~19.6 slack). Tolerance covers the body-margin
        // percentBase rounding (~0.8pt).
        let first = try #require(images.first)
        #expect(abs(first.rect.minX - 19.6) < 1.5)
        // Critical: no two images overlap on the same page. Images are page-
        // local; compare within each page via documentRect.
        for page in pages {
            let pageImages = page.fragments.compactMap { frag -> ImageFragment? in
                if case .image(let i) = frag { return i }
                return nil
            }
            for pair in zip(pageImages, pageImages.dropFirst()) {
                let a = pair.0.documentRect.rawValue
                let b = pair.1.documentRect.rawValue
                #expect(b.minY >= a.maxY - 0.01,
                        "images overlap on page \(page.index): a=\(a) b=\(b)")
            }
        }
        // Cell 1 image is the first page's only big image (its bottom + caption
        // may exceed the page, so cell 2 starts on the next page).
        #expect(first.rect.minY >= 0)
        #expect(first.rect.maxY <= 842.01)
    }

    /// 章名 text-align:center inside a fixed-width box (k1): the line's
    /// maxWidth must be the BOX width, not the body width — otherwise the
    /// centered line drifts right by half the box-margin slack.
    @Test func chapterTitleCentersWithinFixedWidthBox() async throws {
        let html = """
        <html><head><style>
        div.k1 { width: 255px; text-align: center; }
        </style></head><body>
        <div class="k1"><p>第一回</p></div>
        </body></html>
        """
        let (pages, _) = try await BrowserLayoutTestSupport.layout(html, width: 392, height: 842)
        let texts = BrowserLayoutTestSupport.allTextFragments(pages)
        let first = try #require(texts.first)
        // Text (3 CJK chars ≈ 63pt at 21pt) centered in the 255pt box:
        // the box itself sits at x=0 (no margin) — left edge ≈ (255-63)/2.
        #expect(abs(first.rect.minX - (255 - first.rect.width) / 2) < 2.0)
    }
}
