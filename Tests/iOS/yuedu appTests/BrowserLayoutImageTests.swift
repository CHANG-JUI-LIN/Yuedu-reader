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

    /// spine 0 of 红楼梦: the standard EPUB cover — an `<svg>` used purely to
    /// wrap one raster image. It rendered as FORCED UNSUPPORTED
    /// (`image-only-document / unsupported-svg`) because `<image xlink:href>`
    /// is not `<img src>`, so no box was built and the chapter produced zero
    /// pages. The capability scanner must accept this shape too, using the same
    /// predicate as the box tree.
    @Test func svgWrappedCoverRendersAsImageAndScannerAcceptsIt() async throws {
        let cover = BrowserLayoutTestSupport.makeImage(size: CGSize(width: 1000, height: 1333), color: .brown)
        let html = """
        <html><head><title>Cover</title></head><body>
        <h1 style="display:none" title="红楼梦"></h1>
        <div style="text-align: center; padding: 0pt; margin: 0pt;">
          <svg xmlns="http://www.w3.org/2000/svg" height="100%" preserveAspectRatio="xMidYMid meet"
               version="1.1" viewBox="0 0 1000 1333" width="100%"
               xmlns:xlink="http://www.w3.org/1999/xlink">
            <image width="1000" height="1333" xlink:href="../Images/cover.jpg"/>
          </svg>
        </div>
        </body></html>
        """
        let (pages, _) = try await BrowserLayoutTestSupport.layout(
            html, width: 366, height: 844,
            imageLoader: loader(["../Images/cover.jpg": cover])
        )
        let images = BrowserLayoutTestSupport.allImageFragments(pages)
        #expect(images.count == 1, "SVG-wrapped cover produced no image fragment")
        let coverFragment = try #require(images.first)
        // max-width: 100% — 1000pt wide clamps to the 366pt container, aspect kept.
        #expect(abs(coverFragment.rect.width - 366) < 0.5)
        #expect(abs(coverFragment.rect.height - 366 * 1333 / 1000) < 1.0)

        let scan = BrowserLayoutCapabilityScanner.scan(html: html, cssTexts: [])
        #expect(scan.supported, "scanner rejected an image-only SVG cover: \(scan.unsupportedFeatures.map(\.description))")

        // Real vector content stays unsupported — this is not general SVG support.
        let vector = "<html><body><svg viewBox=\"0 0 10 10\"><circle cx=\"5\" cy=\"5\" r=\"4\"/></svg></body></html>"
        let vectorScan = BrowserLayoutCapabilityScanner.scan(html: vector, cssTexts: [])
        #expect(!vectorScan.supported, "a real vector SVG must still be rejected")
    }

    /// spine 1/2/3 of 红楼梦 (and 36+ `qmp*` chapters): a full-screen page whose
    /// entire content is the body's background-image, with only `<p>&#160;</p>`
    /// in the flow. It reported `empty-renderable-content` because U+00A0 was
    /// collapsed away as whitespace, leaving zero runs → zero lines → zero
    /// pages, so the background had no page to paint on. NBSP is not
    /// collapsible white space (CSS Text §4.1).
    @Test func nbspOnlyBackgroundPageStillProducesAPage() async throws {
        let html = """
        <html><head><style>
        body.qmp0 { background-size: cover; background-repeat: no-repeat;
                    background-position: center; background-image: url('../Images/bg.jpg'); }
        </style></head>
        <body class="qmp0">
        <h2 style="display:none" title="制作说明"></h2>
        <p>&#160;</p>
        </body></html>
        """
        let bg = BrowserLayoutTestSupport.makeImage(size: CGSize(width: 750, height: 1334), color: .darkGray)
        let (pages, doc) = try await BrowserLayoutTestSupport.layout(
            html, width: 366, height: 844, imageLoader: { _ in bg }
        )
        #expect(!pages.isEmpty, "background-image-only chapter produced zero pages")
        // The NBSP survives collapsing, so the paragraph is real content.
        #expect(!BrowserLayoutTestSupport.allTextFragments(pages).isEmpty)
        #expect(BrowserLayoutTestSupport.visibleText(pages, sourceText: doc.lastSourceText).contains("\u{00A0}"))
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

    // MARK: - Background-image source fidelity

    /// A `url()` payload is a PATH, not a keyword: the style tree must hand the
    /// image loader the source exactly as authored. It used to fold the whole
    /// declaration value to lower case before parsing, so `../Images/Cover.JPG`
    /// became `../images/cover.jpg` and could never match the key the
    /// prefetcher stored — every authored body background painted nothing.
    /// The loader here answers ONE exact string on purpose.
    @Test func bodyBackgroundImageSourcePreservesCase() async throws {
        let img = BrowserLayoutTestSupport.makeImage(size: CGSize(width: 40, height: 40), color: .red)
        let authored = "../Images/Cover.JPG"
        let html = """
        <html><body style="background-image:url(\(authored))"><p>x</p></body></html>
        """
        let (pages, _) = try await BrowserLayoutTestSupport.layout(
            html, width: 300, height: 400, imageLoader: { $0 == authored ? img : nil }
        )
        let images = BrowserLayoutTestSupport.allImageFragments(pages)
        let background = try #require(
            images.first(where: { $0.source == authored }),
            "no background image fragment — the style tree asked for a different source than authored"
        )
        #expect(background.rect.width >= 300 * 0.99)
        #expect(background.rect.height >= 400 * 0.99)
    }

    /// Same invariant through the `background` SHORTHAND — 红楼梦's main
    /// stylesheet declares its page texture as `body { background: url(…) }`,
    /// and the shorthand branch parsed the folded value too.
    @Test func bodyBackgroundShorthandSourcePreservesCase() async throws {
        let img = BrowserLayoutTestSupport.makeImage(size: CGSize(width: 40, height: 40), color: .blue)
        let authored = "../Images/Texture.PNG"
        let html = """
        <html><body style="background:url(\(authored)) no-repeat center"><p>x</p></body></html>
        """
        let (pages, _) = try await BrowserLayoutTestSupport.layout(
            html, width: 300, height: 400, imageLoader: { $0 == authored ? img : nil }
        )
        let images = BrowserLayoutTestSupport.allImageFragments(pages)
        #expect(
            images.contains(where: { $0.source == authored }),
            "shorthand background source was not preserved as authored"
        )
    }

    /// A CSS background is paint, not content: it must never be a tap target.
    /// The injected canvas fragment is FIRST in the display list and covers the
    /// whole page, so once backgrounds started resolving it captured every tap —
    /// the reader's page-turn/menu zones went dead and the real `<img>` under it
    /// could not be opened.
    @MainActor
    @Test func cssBackgroundIsPaintedButNeverHitTested() async throws {
        let wallpaper = BrowserLayoutTestSupport.makeImage(size: CGSize(width: 40, height: 40), color: .gray)
        let photo = BrowserLayoutTestSupport.makeImage(size: CGSize(width: 60, height: 30), color: .red)
        let html = """
        <html><body style="background-image:url(bg.png)"><p><img src="photo.png"></p></body></html>
        """
        let (pages, doc) = try await BrowserLayoutTestSupport.layout(
            html, width: 300, height: 400,
            imageLoader: loader(["bg.png": wallpaper, "photo.png": photo])
        )
        let page = try #require(pages.first)
        let list = DisplayListBuilder.build(for: page, sourceText: doc.lastSourceText)

        // Both are PAINTED.
        let painted = list.items.compactMap { item -> DisplayImageItem? in
            if case .image(let i) = item { return i }
            return nil
        }
        #expect(painted.contains { $0.source == "bg.png" }, "background must still paint")
        #expect(painted.contains { $0.source == "photo.png" }, "the <img> must still paint")

        let view = BrowserLayoutPageView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
        view.displayList = list

        // A point over the <img> hits the <img>, never the wallpaper beneath it.
        let photoItem = try #require(painted.first { $0.source == "photo.png" })
        let insidePhoto = CGPoint(x: photoItem.rect.midX, y: photoItem.rect.midY)
        #expect(view.imageTarget(at: insidePhoto)?.source == "photo.png")

        // A point on bare background is NOT an image target at all, so the tap
        // falls through to the reader's zones.
        let bareSpot = CGPoint(x: 8, y: 390)
        #expect(view.imageTarget(at: bareSpot) == nil,
                "background paint must not be tappable — got \(view.imageTarget(at: bareSpot)?.source ?? "nil")")
    }

    /// CSS Backgrounds §2.11.2: the root element's background is propagated to
    /// the canvas, and the root box must NOT paint it a second time. It used to,
    /// so an opaque `body { background-color: #fff }` was laid back OVER the
    /// wallpaper as a content-column-wide band — the white stripe across
    /// 红楼梦's 回目 title pages.
    @MainActor
    @Test func rootBackgroundPaintsOnlyOnTheCanvas() async throws {
        let wallpaper = BrowserLayoutTestSupport.makeImage(size: CGSize(width: 40, height: 40), color: .gray)
        let html = """
        <html><body style="background-color:#ffffff; background-image:url(bg.png)">
        <div style="background-color:#ff0000">plate</div>
        </body></html>
        """
        let (pages, doc) = try await BrowserLayoutTestSupport.layout(
            html, width: 300, height: 400, imageLoader: loader(["bg.png": wallpaper])
        )
        let page = try #require(pages.first)
        let list = DisplayListBuilder.build(for: page, sourceText: doc.lastSourceText)

        let fills = list.items.compactMap { item -> DisplayFillItem? in
            if case .fill(let f) = item { return f }
            return nil
        }
        let wallpaperIndex = try #require(
            list.items.firstIndex { if case .image(let i) = $0 { return i.isBackgroundPaint } else { return false } },
            "no canvas wallpaper painted"
        )
        // Exactly ONE opaque-white fill, and it sits UNDER the wallpaper.
        func isOpaqueWhite(_ color: UIColor) -> Bool {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return false }
            return r > 0.99 && g > 0.99 && b > 0.99 && a > 0.99
        }
        let whiteIndices = list.items.indices.filter {
            if case .fill(let f) = list.items[$0] { return isOpaqueWhite(f.color) }
            return false
        }
        #expect(whiteIndices.count == 1,
                "root background painted \(whiteIndices.count) times; must be canvas-only")
        if let canvasFillIndex = whiteIndices.first {
            #expect(canvasFillIndex < wallpaperIndex, "the canvas fill must sit UNDER the wallpaper")
        }

        // A NON-root box still paints its own background normally.
        #expect(fills.contains { f in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            f.color.getRed(&r, green: &g, blue: &b, alpha: &a)
            return r > 0.99 && g < 0.01 && b < 0.01
        }, "a child box's own background must still paint")
    }

    /// Source ROUTING: `data:` and `http(s)` are not publication resources and
    /// go to `OnlineImageLoader` (the reader's one remote/inline image path);
    /// everything else is a publication-local href resolved against the
    /// chapter. Pins the predicate the EPUB adapter branches on.
    @Test func onlineLoaderOwnsDataAndRemoteSourcesOnly() async throws {
        let img = BrowserLayoutTestSupport.makeImage(size: CGSize(width: 4, height: 4), color: .red)
        let png = try #require(img.pngData())

        #expect(OnlineImageLoader.canLoad("data:image/png;base64,\(png.base64EncodedString())"))
        #expect(OnlineImageLoader.canLoad("data:image/svg+xml,%3Csvg%2F%3E"))
        #expect(OnlineImageLoader.canLoad("https://example.com/a.jpg"))
        #expect(OnlineImageLoader.canLoad("http://example.com/a.jpg"))

        // Publication-local sources must NOT be routed to the online loader.
        #expect(!OnlineImageLoader.canLoad("../Images/Cover.JPG"))
        #expect(!OnlineImageLoader.canLoad("OEBPS/Images/Cover.JPG"))
        #expect(!OnlineImageLoader.canLoad("reader-book://book-1/OEBPS/Images/Cover.JPG"))
    }

    /// base64 is case-sensitive, so a `data:` background is the sharpest probe
    /// for the style tree's case folding: fold the declaration value and the
    /// payload decodes to a different byte string (or nothing at all).
    @Test func dataURIBackgroundSourceSurvivesTheStyleTree() async throws {
        let img = BrowserLayoutTestSupport.makeImage(size: CGSize(width: 8, height: 8), color: .green)
        let png = try #require(img.pngData())
        let src = "data:image/png;base64,\(png.base64EncodedString())"
        let html = """
        <html><body style="background-image:url(\(src))"><p>x</p></body></html>
        """
        let (pages, _) = try await BrowserLayoutTestSupport.layout(
            html, width: 300, height: 400, imageLoader: { $0 == src ? img : nil }
        )
        let images = BrowserLayoutTestSupport.allImageFragments(pages)
        #expect(
            images.contains(where: { $0.source == src }),
            "the style tree handed back a different data URI than authored"
        )
    }
}
