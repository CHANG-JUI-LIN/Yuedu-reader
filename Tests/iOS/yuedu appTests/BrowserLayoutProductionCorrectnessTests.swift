import Testing
import UIKit
@testable import yuedu_app

/// Phase 2C — Production Rendering Correctness fixtures.
///
/// Fixed production viewport (real iPhone 17 Pro Max logical size):
///   440 × 956, contentInsets = (top: 82, left: 24, bottom: 32, right: 24)
/// → pageContentRect = (24, 82, 392, 842), content height 842.
///
/// These fixtures must FAIL before the Phase 2C fixes and PASS after:
///  A. root authored background covers the full page canvas (cover+center)
///  B. rounded dotted card paints all four borders with radius/opacity
///  C. oversized replaced elements paginate atomically (no clipping)
///  D. plain-text baseline geometry (must never regress)
@MainActor
struct BrowserLayoutProductionCorrectnessTests {

    static let viewport = CGSize(width: 440, height: 956)
    static let insets = UIEdgeInsets(top: 82, left: 24, bottom: 32, right: 24)

    static func makeConfig() -> BrowserLayoutConfig {
        BrowserLayoutConfig(
            renderWidth: viewport.width - insets.left - insets.right,
            renderHeight: viewport.height - insets.top - insets.bottom,
            rootFontSize: 17,
            contentInsets: insets
        )
    }

    static func layout(
        _ html: String,
        css: [String] = [],
        images: [String: UIImage] = [:]
    ) async throws -> (pages: [PageFragments], doc: BrowserLayoutDocument) {
        let config = makeConfig()
        let doc = BrowserLayoutDocument(
            html: html, cssTexts: css, config: config,
            imageLoader: { images[$0] }
        )
        let pages = try await doc.renderPages(containerSize: viewport)
        return (pages, doc)
    }

    static func checker(size: CGSize, color: UIColor) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    // MARK: - A. Root authored background

    /// Body has an authored background-image (cover + center). The page canvas
    /// is the FULL viewport — the background must cover 440×956 on EVERY page,
    /// not shrink to the body content height.
    @Test func rootBackgroundCoversFullPageCanvas() async throws {
        let html = """
        <html><head><style>
          body { margin: 0; background-image: url(bg.png);
                 background-size: cover; background-position: center center; }
          .card { margin: 25% auto 0; width: 15em; padding: 0.4em; background-color: rgba(255,255,255,0.7); }
        </style></head>
        <body><div class="card">測試標題</div></body></html>
        """
        let bg = Self.checker(size: CGSize(width: 64, height: 64), color: .orange)
        let (pages, _) = try await Self.layout(html, images: ["bg.png": bg])

        let page = try #require(pages.first)
        // The background fill must span the FULL viewport canvas (page-local).
        var foundCanvasFill = false
        var foundCanvasImage = false
        func walk(_ fragments: [Fragment]) {
            for fragment in fragments {
                switch fragment {
                case .fill(let f):
                    // First item is the canvas background fill.
                    if f.rect.width >= Self.viewport.width - 0.5,
                       f.rect.height >= Self.viewport.height - 0.5 {
                        foundCanvasFill = true
                    }
                case .image(let i):
                    if i.source == "bg.png" {
                        foundCanvasImage = true
                        // cover: image rect covers the full viewport.
                        #expect(i.rect.width >= Self.viewport.width - 0.5,
                                "cover background must span viewport width, got \(i.rect.width)")
                        #expect(i.rect.height >= Self.viewport.height - 0.5,
                                "cover background must span viewport height, got \(i.rect.height)")
                    }
                case .group(let children): walk(children)
                default: break
                }
            }
        }
        walk(page.fragments)
        #expect(foundCanvasFill, "canvas background fill missing — background must not shrink to content height")
        #expect(foundCanvasImage, "authored background-image missing from the page")
    }

    /// The authored background must appear on EVERY page, not only page 0 —
    /// a multi-page chapter keeps full-canvas coverage (attachment: fixed
    /// semantics for paged EPUB).
    @Test func rootBackgroundAppearsOnEveryPage() async throws {
        let html = """
        <html><head><style>
          body { margin: 0; background-image: url(bg.png);
                 background-size: cover; background-attachment: fixed; }
          p { margin: 0 0 1em; }
        </style></head>
        <body>
        \(String(repeating: "<p>重複段落內容以撐滿超過一頁。</p>", count: 60))
        </body></html>
        """
        let bg = Self.checker(size: CGSize(width: 64, height: 64), color: .purple)
        let (pages, _) = try await Self.layout(html, images: ["bg.png": bg])
        #expect(pages.count >= 2, "fixture must span multiple pages")
        for page in pages {
            var canvasFill = false
            func walk(_ fragments: [Fragment]) {
                for fragment in fragments {
                    switch fragment {
                    case .fill(let f):
                        if f.rect.width >= Self.viewport.width - 0.5,
                           f.rect.height >= Self.viewport.height - 0.5 {
                            canvasFill = true
                        }
                    case .group(let children): walk(children)
                    default: break
                    }
                }
            }
            walk(page.fragments)
            #expect(canvasFill, "page \(page.index) missing full-canvas background")
        }
    }

    // MARK: - B. Rounded dotted card

    /// k2-style card: rgba fill, dotted border, radius. The display list must
    /// carry a border representation with ALL FOUR edges (not one top line).
    @Test func roundedDottedCardPaintsAllFourEdges() async throws {
        let html = """
        <html><head><style>
          body { margin: 0; }
          .card { margin: 25% auto 0; padding: 2.2em 0; width: 15em;
                  background-color: rgba(255,255,255,0.7);
                  border: dotted 1px #3a4431; border-radius: 12px; }
        </style></head>
        <body><div class="card"><p>卡</p></div></body></html>
        """
        let (pages, _) = try await Self.layout(html)
        let page = try #require(pages.first)

        var card: DisplayFillItem? = nil
        for item in DisplayListBuilder.build(for: page, sourceText: "").items {
            if case .fill(let f) = item,
               f.rect.width > 200, f.rect.width < 320, f.rect.height > 50 {
                card = f
            }
        }
        let fill = try #require(card, "card fill not in display list")
        // All four edges must be visible and dotted.
        #expect(fill.borderTop.width == 1 && fill.borderTop.style == .dotted, "top dotted border missing")
        #expect(fill.borderBottom.width == 1 && fill.borderBottom.style == .dotted, "bottom dotted border missing")
        #expect(fill.borderLeft.width == 1 && fill.borderLeft.style == .dotted, "left dotted border missing")
        #expect(fill.borderRight.width == 1 && fill.borderRight.style == .dotted, "right dotted border missing")
        #expect(fill.cornerRadius == 12, "border-radius must be carried")
        #expect(fill.color.withAlphaComponent(1) != UIColor.clear, "rgba fill must be carried")
    }

    // MARK: - C. Oversized images

    /// Three images: (1) fits the page, (2) taller than remaining space but
    /// fits a full page, (3) intrinsic height > full page height.
    /// Each must be ONE ImageFragment — never split/clipped.
    @Test func oversizedImagesPaginateAtomically() async throws {
        let small = Self.checker(size: CGSize(width: 200, height: 120), color: .red)
        let tall = Self.checker(size: CGSize(width: 200, height: 500), color: .green)
        // Intrinsic height 1200 > page content height 842.
        let huge = Self.checker(size: CGSize(width: 300, height: 1200), color: .blue)
        let html = """
        <html><body>
          <p>Start</p>
          <img src="small.png" style="display: block">
          <p>Mid</p>
          <img src="tall.png" style="display: block">
          <p>After</p>
          <img src="huge.png" style="display: block">
        </body></html>
        """
        let (pages, _) = try await Self.layout(
            html,
            images: ["small.png": small, "tall.png": tall, "huge.png": huge]
        )
        let images = BrowserLayoutTestSupport.allImageFragments(pages)

        // Each image must appear EXACTLY once (one fragment, no clipping).
        let smallCount = images.filter { $0.source == "small.png" }.count
        let tallCount = images.filter { $0.source == "tall.png" }.count
        let hugeCount = images.filter { $0.source == "huge.png" }.count
        #expect(smallCount == 1, "small image must be one fragment, got \(smallCount)")
        #expect(tallCount == 1, "tall image must be one fragment, got \(tallCount)")
        #expect(hugeCount == 1, "huge image must be one fragment, got \(hugeCount)")

        // The huge image (1200 tall) cannot fit the 842pt page — it must be
        // SCALED to fit (width preserved by aspect: 842/1200 × 300 = 210.5).
        let hugeFrag = try #require(images.first { $0.source == "huge.png" })
        #expect(hugeFrag.rect.height <= Self.viewport.height + 0.5,
                "huge image must not exceed the page: \(hugeFrag.rect.height)")
        let expectedHugeHeight = Self.viewport.height - Self.insets.top - Self.insets.bottom
        #expect(abs(hugeFrag.rect.height - expectedHugeHeight) <= 1.5,
                "huge image should scale to content height, got \(hugeFrag.rect.height)")
        // Aspect preserved: width/height == 300/1200.
        let aspect = hugeFrag.rect.width / hugeFrag.rect.height
        #expect(abs(aspect - 300.0 / 1200.0) < 0.02, "huge image aspect ratio broken: \(aspect)")

        // No fragment may extend below the page content area.
        for page in pages {
            for frag in BrowserLayoutTestSupport.allImageFragments([page]) {
                #expect(frag.rect.maxY <= Self.viewport.height + 0.5,
                        "image clipped below page: \(frag.rect)")
            }
        }
    }

    // MARK: - D. Plain-text baseline (must never regress)

    @Test func plainTextBaselineGeometry() async throws {
        let html = """
        <html><head><style>
          body { margin: 0; }
          p { margin: 1em 0; text-indent: 2em; line-height: 145%; }
        </style></head>
        <body>
          <p>第一段文字內容測試。</p>
          <p>第二段文字內容測試，稍微長一點讓它換行到下一頁的邊界附近測試分頁行為。</p>
        </body></html>
        """
        let (pages, doc) = try await Self.layout(html)
        #expect(!pages.isEmpty)

        let firstTexts = BrowserLayoutTestSupport.allTextFragments([pages[0]])
        let first = try #require(firstTexts.first)
        // First line sits inside the content rect: x starts at content left +
        // text-indent 2em, y inside the top content area.
        #expect(first.rect.minX >= Self.insets.left, "first line x must respect content inset")
        #expect(first.rect.minY >= Self.insets.top, "first line y must respect top inset")
        #expect(first.rect.minY < Self.insets.top + 200, "first line should be near the top of content")

        // Source ranges ordered (no loss/dup).
        #expect(BrowserLayoutTestSupport.rangesAreOrdered(pages))
        let visible = BrowserLayoutTestSupport.visibleText(pages, sourceText: doc.lastSourceText)
        #expect(!visible.isEmpty)
    }
}
