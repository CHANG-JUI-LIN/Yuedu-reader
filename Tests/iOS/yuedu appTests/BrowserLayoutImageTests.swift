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
        // Each 400pt image owns a full 400pt page, and page 0 holds only the
        // document's leading margin: this fixture never resets `body`, so the
        // default 8pt `margin-top` applies, and page 0 is the FLOW START — not
        // a break — so CSS Fragmentation §4.2 retains that margin. 400pt of
        // image cannot fit the remaining 392pt, so the first image takes page 1.
        // (This asserted 3 before, which only held because a `minY < 0` clamp
        // was silently relocating the image to y=0 while the flow believed it
        // sat 106.9pt lower.)
        #expect(pages.count == 4)
        #expect(BrowserLayoutTestSupport.allTextFragments([pages[0]]).isEmpty)
        for image in images {
            // No top strip cut: the whole image sits inside its page.
            #expect(image.rect.minY >= 0)
            #expect(image.rect.maxY <= 400.01)
            // Scaled to fit the page (627 > 400 → 400 tall, aspect kept).
            #expect(abs(image.rect.height - 400) < 0.1)
            #expect(abs(image.rect.width - 224.561) < 0.1)
        }
    }

    /// Regression (图片残页): an inline image must occupy EXACTLY the block-flow
    /// space reserved for it — its top must never be above the preceding
    /// content's bottom.
    ///
    /// Why the existing tall-image tests missed this: they all used an image
    /// TALLER than the page, which takes `placeImage` case 3 (scale to fit) and
    /// rewrites the rect to the page top — normalizing the y away. On a real
    /// 842pt page a 627.2pt gallery image is SHORTER than the page, so it takes
    /// case 1/2 and the authored y survives to the screen.
    ///
    /// The defect: `AtomicInlineBox` gave the image a 75/25 ascent/descent
    /// split, so the image hung `height × 0.25` BELOW the baseline while the
    /// walker painted it at `baseline − height` — i.e. `height × 0.25` above
    /// its own line box top. A 400pt image was drawn 100pt too high, over
    /// whatever sat above it. Page height here is 2000 so nothing paginates or
    /// scales: this measures pure document geometry.
    @Test func inlineImageNeverPaintsAbovePrecedingContent() async throws {
        let img = BrowserLayoutTestSupport.makeImage(size: CGSize(width: 200, height: 400), color: .magenta)
        let html = """
        <html><body>
        <p>前段文字佔住圖片上方的流位置。</p>
        <div><img src="tall.png"></div>
        </body></html>
        """
        let (pages, _) = try await BrowserLayoutTestSupport.layout(
            html, width: 300, height: 2000, imageLoader: loader(["tall.png": img])
        )
        let images = BrowserLayoutTestSupport.allImageFragments(pages)
        let texts = BrowserLayoutTestSupport.allTextFragments(pages)
        let image = try #require(images.first)
        let textBottom = try #require(texts.map(\.rect.maxY).max())
        // Not scaled (400 < 2000) and not repositioned by pagination: this is
        // the authored geometry.
        #expect(abs(image.rect.height - 400) < 0.01)
        #expect(image.rect.minY >= textBottom - 0.5,
                "image top \(image.rect.minY) is ABOVE preceding text bottom \(textBottom) — painted over it")
    }

    /// Regression (图片残页, real 画册 DOM at real device metrics): 392×842 page,
    /// gallery cells whose 627.2pt image is SHORTER than the page. Each image
    /// must stay below the previous cell's caption instead of painting over it,
    /// and no image may overlap any text on its page.
    @Test func galleryImageDoesNotPaintOverPreviousCaption() async throws {
        let img = BrowserLayoutTestSupport.makeImage(size: CGSize(width: 1080, height: 1920), color: .cyan)
        let html = """
        <html><head><style>
        div.duokan-image-gallery { margin: 0.5em auto; width: 90%; text-align: center; }
        div.duokan-image-gallery-cell img { margin: 0.35em 0; width: 90%; }
        p.duokan-image-maintitle { margin: 1em 0 0; font-size: 0.9em; line-height: 1.25em; }
        </style></head><body>
        <div class="duokan-image-gallery">
          <div class="duokan-image-gallery-cell">
            <img alt="z1" src="a.jpg"/>
            <p class="duokan-image-maintitle">贾探春</p>
          </div>
          <div class="duokan-image-gallery-cell">
            <img alt="z1" src="b.jpg"/>
            <p class="duokan-image-maintitle">史湘云</p>
          </div>
        </div>
        </body></html>
        """
        let (pages, _) = try await BrowserLayoutTestSupport.layout(
            html, width: 392, height: 842, imageLoader: loader(["a.jpg": img, "b.jpg": img])
        )
        let images = BrowserLayoutTestSupport.allImageFragments(pages)
        #expect(images.count == 2)
        // 90% of 392 → 352.8 wide, 9:16 → 627.2 tall. Shorter than the 842pt
        // page, so `placeImage` must NOT scale it.
        for image in images {
            #expect(abs(image.rect.height - 627.2) < 1.0,
                    "image height \(image.rect.height) — expected the authored 627.2 (unscaled)")
        }
        // Both captions must survive: an image painted over one would still be
        // in the fragment list, so assert geometric non-overlap per page.
        for page in pages {
            var pageImages: [ImageFragment] = []
            var pageTexts: [TextFragment] = []
            for fragment in page.fragments {
                switch fragment {
                case .image(let i): pageImages.append(i)
                case .text(let t): pageTexts.append(t)
                default: break
                }
            }
            for image in pageImages {
                for text in pageTexts {
                    let overlapsVertically = image.rect.minY < text.rect.maxY - 0.5
                        && text.rect.minY < image.rect.maxY - 0.5
                    let overlapsHorizontally = image.rect.minX < text.rect.maxX - 0.5
                        && text.rect.minX < image.rect.maxX - 0.5
                    #expect(!(overlapsVertically && overlapsHorizontally),
                            "page \(page.index): image \(image.rect.rawValue) paints over text \(text.rect.rawValue)")
                }
            }
        }
    }

    /// CSS Fragmentation §4.2 as a GENERAL rule — text only, no images, so it
    /// pins the margin behaviour independently of replaced-element pagination:
    ///
    /// - page 0 is the flow start, NOT a break → the document's leading margin
    ///   is retained;
    /// - every later page was entered by an unforced break → the block-start
    ///   margin adjoining that break is discarded, so no page opens with a
    ///   leftover margin band.
    ///
    /// The distinguishing case is a paragraph that FITS the new page's
    /// remainder and therefore is never snapped by the straddle path: paragraph
    /// 3 lands at document y 118 with a 24pt margin above it, i.e. 18pt below
    /// the page-1 top. Before the rule it painted at y 18.
    @Test func unforcedBreakDiscardsAdjoiningMarginFlowStartKeepsIt() async throws {
        let paragraphs = (1...40).map { "<p>段落\($0)</p>" }.joined()
        let html = """
        <html><head><style>
          body { margin: 30px 0 0; }
          p { margin: 24px 0 0; font-size: 16px; line-height: 20px; }
        </style></head><body>\(paragraphs)</body></html>
        """
        let (pages, _) = try await BrowserLayoutTestSupport.layout(html, width: 300, height: 100)
        #expect(pages.count > 2)

        func topText(_ page: PageFragments) -> CGFloat? {
            page.fragments.compactMap { fragment -> CGFloat? in
                if case .text(let t) = fragment { return t.rect.minY }
                return nil
            }.min()
        }

        // Flow start keeps the leading margin (body 30pt collapsed with the
        // first paragraph's 24pt → 30pt).
        let first = try #require(topText(pages[0]))
        #expect(abs(first - 30) < 1.0, "flow-start margin not retained: \(first)")

        // No later page opens with a margin band.
        for page in pages.dropFirst() {
            guard let top = topText(page) else { continue }
            #expect(top < 1.0, "page \(page.index) opens with a \(top)pt margin band")
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
