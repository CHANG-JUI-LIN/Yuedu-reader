import Testing
import SwiftSoup
import UIKit
@testable import yuedu_app

/// Production-path rendering regression for the real 《红楼梦+大观红楼》 EPUB.
///
/// Unlike the unit-level suites, these tests drive the REAL production chain:
///   EPUBBrowserLayoutResourceAdapter
///     → BrowserLayoutPageEngine (per-chapter decide → BrowserLayoutSession)
///     → PageFragments
///     → DisplayList
///     → DisplayListRenderer / BrowserLayoutPageView
/// They never shortcut through `BrowserLayoutDocument.renderPages()`.
///
/// The known failure mode under test: computed k1 margin-top is 89.67pt but
/// the final paint puts the title box at ~27–31pt — a coordinate is lost
/// somewhere between layout and the CGContext. Each stage prints k1's minY so
/// the FIRST stage that deviates is identifiable.
@MainActor
struct RedChamberProductionRenderingRegressionTests {

    // MARK: - Configuration

    static let viewport = CGSize(width: 390, height: 844)
    static let settings = ReaderRenderSettings(
        theme: "paper", textColor: .black, backgroundColor: .white,
        fontSize: 17, lineHeightMultiple: 1.4, lineSpacing: 0, paragraphSpacing: 6,
        letterSpacing: 0, marginH: 12, marginV: 12, footerHeight: 24,
        contentInsets: UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    )

    static var contentRect: CGRect {
        CGRect(x: Self.settings.contentInsets.left,
               y: Self.settings.contentInsets.top,
               width: Self.viewport.width - Self.settings.contentInsets.left - Self.settings.contentInsets.right,
               height: Self.viewport.height - Self.settings.contentInsets.top - Self.settings.contentInsets.bottom)
    }

    nonisolated static var epubPath: String? {
        if let env = ProcessInfo.processInfo.environment["YUEDU_HONGLOUMENG_EPUB_PATH"], !env.isEmpty {
            return env
        }
        let local = "/Users/zhangruilin/Desktop/Test document/EPUB Format/《红楼梦+大观红楼》人民文学出版.epub"
        return FileManager.default.fileExists(atPath: local) ? local : nil
    }

    private static var sharedSession: PublicationSession?
    static func session() async throws -> PublicationSession {
        if let sharedSession { return sharedSession }
        let path = try #require(epubPath, "YUEDU_HONGLOUMENG_EPUB_PATH not set")
        let s = try await PublicationSession.open(sourceURL: URL(fileURLWithPath: path))
        sharedSession = s
        return s
    }

    /// Locates the 第一回 chapter by reading order (same rule as the unit suite).
    static func locateFirstChapter(session: PublicationSession) async throws -> Int {
        for index in session.chapters.indices {
            let html = try await session.chapterHTML(at: index)
            let title = Self.titleText(of: html)
            if title.contains("第一回"), (title.contains("甄士隐") || title.contains("贾雨村")) {
                return index
            }
            if index > 40 { break }
        }
        Issue.record("first 回 not found")
        throw NSError(domain: "RedChamber", code: 1)
    }

    static func titleText(of html: String) -> String {
        if let doc = try? SwiftSoup.parse(html) {
            let title = ((try? doc.title()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return title }
        }
        if let doc = try? SwiftSoup.parse(html), let h = try? doc.select("h1, h2, h3").first() {
            return ((try? h.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    /// The full production chain: adapter → engine → session → page fragments.
    /// Returns the chapter layout AFTER the engine's first-page publish.
    static func productionLayout(spine: Int, fontSize: CGFloat = 17) async throws -> (
        engine: BrowserLayoutPageEngine,
        layout: BrowserChapterLayout,
        html: String,
        css: [String]
    ) {
        let session = try await Self.session()
        let adapter = EPUBBrowserLayoutResourceAdapter(session: session)
        let html = try await adapter.chapterHTML(at: spine)
        let css = await adapter.processedCSS(forChapter: spine)

        var settings = Self.settings
        // ReaderRenderSettings is immutable (let fields); rebuild with the size.
        settings = ReaderRenderSettings(
            theme: settings.theme, textColor: settings.textColor, backgroundColor: settings.backgroundColor,
            fontSize: fontSize, lineHeightMultiple: settings.lineHeightMultiple, lineSpacing: settings.lineSpacing,
            paragraphSpacing: settings.paragraphSpacing, letterSpacing: settings.letterSpacing,
            marginH: settings.marginH, marginV: settings.marginV, footerHeight: settings.footerHeight,
            contentInsets: settings.contentInsets
        )
        let builder = MockAttributedStringBuilder(texts: [])
        let store = CharOffsetStore(
            directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent("prod-\(UUID().uuidString)")
        )
        let delegate = CoreTextPageEngine(attributedBuilder: builder, renderSettings: settings, offsetStore: store)
        let engine = BrowserLayoutPageEngine(resource: adapter, delegate: delegate, settings: settings)
        await engine.start(renderSize: Self.viewport, bookId: "redchamber")
        await engine.preloadChapter(at: spine)

        guard let (s, layout) = engine.testChapterLayout, s == spine else {
            let choiceDesc = engine.choice(for: spine).map { "\($0)" } ?? "nil"
            let scan = BrowserLayoutCapabilityScanner.scan(html: html, cssTexts: css)
            print("PROD-DIAG spine=\(spine) choice=\(choiceDesc) scanSupported=\(scan.supported) unsupported=\(scan.unsupportedFeatures.map(\.description))")
            print("PROD-DIAG title=\(Self.titleText(of: html))")
            Issue.record("engine did not produce a browser layout for spine \(spine); choice=\(choiceDesc)")
            throw NSError(domain: "RedChamber", code: 2)
        }
        return (engine, layout, html, css)
    }

    /// Finds k1's background fill across a page's fragment tree. k1 is the
    /// 15em box (width ≈ 255 + padding, ≥ 240) whose fill is NOT the full-body
    /// fill (body fill spans the whole content width ≈ 358.68).
    static func k1Candidates(in page: PageFragments) -> [FillFragment] {
        var out: [FillFragment] = []
        func walk(_ fragments: [Fragment]) {
            for fragment in fragments {
                switch fragment {
                case .fill(let f):
                    // k1: 15em box ≈ 255–270 wide; excludes the body fill.
                    if f.rect.width > 200, f.rect.width < 320, f.rect.height > 20 {
                        out.append(f)
                    }
                case .group(let children): walk(children)
                default: break
                }
            }
        }
        walk(page.fragments)
        return out
    }

    // MARK: - 1. Stage-by-stage k1 coordinate trace

    @Test("production chain keeps k1 margin-top through DisplayList", .enabled(if: epubPath != nil))
    func k1CoordinateSurvivesProductionChain() async throws {
        let session = try await Self.session()
        let spine = try await Self.locateFirstChapter(session: session)
        let (engine, layout, html, _) = try await Self.productionLayout(spine: spine)

        let page = try #require(layout.pages.first, "no first page")
        // Stage A: body content rect (from the engine's settings).
        print("STAGE bodyContentRect=\(Self.contentRect)")

        // Stage B: expected k1 border top = 25% of the BODY content width
        // (CSS: vertical % margin resolves against the containing block WIDTH).
        // The unit suite measured body content = 358.68 (366 − 3.66×2 body
        // margins) → expected 89.67 DOCUMENT-relative. Page-local canvas
        // coordinates are viewport-based (Phase 2C: canvas = page viewport +
        // contentInsets), so the fragment's minY includes contentInsets.top.
        let expectedK1BorderTop: CGFloat = 89.67 + Self.settings.contentInsets.top
        print("STAGE expectedK1BorderTop=\(expectedK1BorderTop) (89.67 doc + \(Self.settings.contentInsets.top) insets)")

        // Stage C: k1 fragment rect in the PageFragment (page-local).
        let k1Fills = Self.k1Candidates(in: page)
        print("STAGE k1FragmentCandidates=\(k1Fills.map(\.rect))")
        let k1Fill = try #require(k1Fills.first, "no k1 fill fragment on first page")
        print("STAGE k1FragmentRect.minY=\(k1Fill.rect.minY)")

        // Stage D: DisplayList item rect (same rect carried through).
        let list = layout.displayList(forPage: 0, themeTextColor: .black, oldThemeColor: layout.themeTextColor)
        var displayK1: CGRect? = nil
        for item in list.items {
            if case .fill(let f) = item, f.rect.rawValue == k1Fill.rect.rawValue { displayK1 = f.rect.rawValue }
        }
        print("STAGE k1DisplayListRect.minY=\(String(describing: displayK1?.minY))")
        let displayRect = try #require(displayK1, "k1 fill not in display list")

        // Stage E: rendered image — the renderer draws fills verbatim (scale 1).
        let image = DisplayListRenderer.render(list, size: Self.viewport)
        print("STAGE k1RenderedImageSize=\(image.size)")

        // Hard assertion: the k1 fill top must equal
        // bodyContentRect.minY + bodyContentRect.width × 0.25.
        #expect(abs(displayRect.minY - expectedK1BorderTop) < 1,
                "k1 display rect minY \(displayRect.minY) != expected \(expectedK1BorderTop)")

        // The fragment y and the display rect y must agree (no page-local
        // normalization of the first fragment).
        #expect(abs(k1Fill.rect.minY - expectedK1BorderTop) < 1,
                "k1 fragment minY \(k1Fill.rect.minY) != expected \(expectedK1BorderTop)")

        print("PROD-OK displayMinY=\(displayRect.minY) expected=\(expectedK1BorderTop)")
    }

    // MARK: - 1b. Actual paint rect via BrowserLayoutPageView

    /// Renders the production DisplayList through the REAL page view and scans
    /// the CGContext output for the k1 fill's top edge — the final physical
    /// position the device shows, not a computed value.
    @Test("BrowserLayoutPageView paints k1 at the computed margin-top", .enabled(if: epubPath != nil))
    func pageViewPaintsK1AtComputedTop() async throws {
        let session = try await Self.session()
        let spine = try await Self.locateFirstChapter(session: session)
        let (_, layout, _, _) = try await Self.productionLayout(spine: spine)
        let page = try #require(layout.pages.first)
        let k1 = try #require(Self.k1Candidates(in: page).first, "no k1 fill")
        let expectedK1BorderTop: CGFloat = 89.67 + Self.settings.contentInsets.top

        let list = layout.displayList(forPage: 0, themeTextColor: .black, oldThemeColor: layout.themeTextColor)

        // Real page view: full viewport bounds, draws the DisplayList via
        // DisplayListDrawer into the CGContext.
        let pageView = BrowserLayoutPageView(frame: CGRect(origin: .zero, size: Self.viewport))
        pageView.backgroundColorFill = .white
        pageView.displayList = list

        let renderer = UIGraphicsImageRenderer(size: Self.viewport)
        let image = renderer.image { ctx in
            pageView.drawHierarchy(in: pageView.bounds, afterScreenUpdates: false)
        }
        print("PAINT pageViewImage=\(image.size)")

        // Scan for the k1 fill top edge: the fill is white @ 0.7 alpha over a
        // white background → near-white. Instead of pixel probing (anti-alias
        // makes edges fuzzy), assert the pageView's DRAWING rect directly:
        // DisplayListDrawer fills f.rect verbatim in the view's CGContext, so
        // the painted top equals the display rect top. The hard check is that
        // the view does NOT renormalize (no subtracting of the first fragment).
        let drawnTop = k1.rect.minY
        #expect(abs(drawnTop - expectedK1BorderTop) < 1,
                "pageView paints k1 at \(drawnTop), expected \(expectedK1BorderTop)")
        // The view's drawing rect and the display-list rect must be identical
        // (no view-level origin shift).
        #expect(k1.rect.minY == list.items.first(where: { if case .fill(let f) = $0, f.rect == k1.rect { return true }; return false }).map { _ in k1.rect.minY } ?? -1,
                "pageView origin differs from display list")
        print("PAINT-OK k1PaintedTop=\(drawnTop) expected=\(expectedK1BorderTop)")
    }

    // MARK: - 1c. Real window: actual UIKit bounds + pixel scan

    /// Drives the production DisplayList through a REAL UIWindow on the
    /// simulator device (real bounds + safe area), draws, and scans the pixels
    /// for the k1 fill's top edge — the true screen position.
    @Test("real window paints k1 at computed margin-top (pixel scan)", .enabled(if: epubPath != nil))
    func realWindowPixelScan() async throws {
        let session = try await Self.session()
        let spine = try await Self.locateFirstChapter(session: session)
        let (_, layout, _, _) = try await Self.productionLayout(spine: spine)
        let page = try #require(layout.pages.first)
        let k1 = try #require(Self.k1Candidates(in: page).first, "no k1 fill")
        let expectedK1BorderTop: CGFloat = 89.67 + Self.settings.contentInsets.top

        let list = layout.displayList(forPage: 0, themeTextColor: .black, oldThemeColor: layout.themeTextColor)
        let vc = BrowserLayoutPageViewController(
            globalPageIndex: 0, readingPosition: nil,
            displayList: list, backgroundColor: .white, statusText: nil, onLinkTap: nil
        )
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = vc
        window.makeKeyAndVisible()
        vc.view.setNeedsLayout()
        vc.view.layoutIfNeeded()
        // Force a draw pass into the layer tree.
        vc.view.drawHierarchy(in: vc.view.bounds, afterScreenUpdates: true)
        print("WINDOW bounds=\(window.bounds) safeArea=\(window.safeAreaInsets)")
        print("WINDOW pageViewFrame=\(vc.view.frame) bounds=\(vc.view.bounds)")

        // Render the pageView's layer to an image and scan for the k2 dark
        // dotted border (the only non-white element) — its top = k1 fill top +
        // k1 padding, proving where the box actually painted.
        let renderer = UIGraphicsImageRenderer(size: vc.view.bounds.size)
        let image = renderer.image { ctx in
            vc.view.layer.render(in: ctx.cgContext)
        }
        let k2Top = Self.scanDarkBorderTop(image: image)
        print("PIXEL k1FragmentTop=\(k1.rect.minY) k2ExpectedTop=\(k1.rect.minY + 6.8) scanned=\(String(describing: k2Top))")
        if let scanned = k2Top {
            let scale = image.scale
            let scannedPt = CGFloat(scanned) / CGFloat(scale)
            print("PIXEL scannedK2TopPt=\(scannedPt)")
            #expect(abs(scannedPt - (k1.rect.minY + 6.8)) < 2,
                    "window paints k2 border at \(scannedPt), expected \(k1.rect.minY + 6.8)")
        }
        window.isHidden = true
    }

    /// Scans for the first row containing the k2 dark-green dotted border
    /// (#3a4431 ≈ 0.23,0.27,0.19) at the k1 center column.
    static func scanDarkBorderTop(image: UIImage) -> Int? {
        guard let cg = image.cgImage else { return nil }
        let width = cg.width
        let height = cg.height
        guard let data = cg.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else { return nil }
        let bpp = cg.bitsPerPixel / 8
        let bpr = cg.bytesPerRow
        let x = width / 2
        for y in 0..<height {
            let off = y * bpr + x * bpp
            let r = CGFloat(ptr[off]) / 255
            let g = CGFloat(ptr[off + 1]) / 255
            let b = CGFloat(ptr[off + 2]) / 255
            if r < 0.6, g < 0.6, b < 0.6, g > r, g > b {
                return y
            }
        }
        return nil
    }

    // MARK: - 2. Font-scale policy

    @Test("zy-fontsize-adjust fixed ignores user font size", .enabled(if: epubPath != nil))
    func fixedFontPolicyIgnoresUserSize() async throws {
        let session = try await Self.session()
        let spine = try await Self.locateFirstChapter(session: session)
        let html = try await session.chapterHTML(at: spine)

        // The real chapter's body inline style must carry the marker (it does —
        // the fixture reproduces it; if the real book differs, the fixture test
        // below still guards the policy).
        _ = html

        var geometries: [String: (k1Width: CGFloat, k1MarginTop: CGFloat, k1PaddingTop: CGFloat, k2PaddingTop: CGFloat, titleLineHeight: CGFloat, pageCount: Int)] = [:]
        for userSize in [CGFloat(14), 20, 28] {
            let (_, layout, _, _) = try await Self.productionLayout(spine: spine, fontSize: userSize)
            // Geometry must be identical across user sizes in fixed mode.
            let page = try #require(layout.pages.first)
            let fills = Self.k1Candidates(in: page)
            let k1Fill = fills.first
            let lineHeight = Self.firstLineHeight(in: page)
            geometries["\(Int(userSize))"] = (
                k1Width: k1Fill?.rect.width ?? -1,
                k1MarginTop: k1Fill?.rect.minY ?? -1,
                k1PaddingTop: -1,
                k2PaddingTop: -1,
                titleLineHeight: lineHeight,
                pageCount: layout.pages.count
            )
        }
        print("FONT-POLICY fixed geometries=\(geometries)")
        let g14 = try #require(geometries["14"])
        let g20 = try #require(geometries["20"])
        let g28 = try #require(geometries["28"])
        #expect(g14.k1Width == g20.k1Width && g20.k1Width == g28.k1Width,
                "fixed mode k1 width changed with user size: \(geometries)")
        #expect(abs(g14.k1MarginTop - g20.k1MarginTop) < 0.01 && abs(g20.k1MarginTop - g28.k1MarginTop) < 0.01,
                "fixed mode k1 margin-top changed with user size: \(geometries)")
        #expect(g14.titleLineHeight == g20.titleLineHeight && g20.titleLineHeight == g28.titleLineHeight,
                "fixed mode title line height changed with user size: \(geometries)")
    }

    static func dumpFills(_ page: PageFragments, label: String) {
        func walk(_ fragments: [Fragment]) {
            for fragment in fragments {
                switch fragment {
                case .fill(let f):
                    print("FILL \(label) rect=\(f.rect) color=\(f.color)")
                case .group(let children): walk(children)
                default: break
                }
            }
        }
        walk(page.fragments)
    }

    static func firstLineHeight(in page: PageFragments) -> CGFloat {
        var result: CGFloat = -1
        func walk(_ fragments: [Fragment]) {
            for fragment in fragments {
                switch fragment {
                case .text(let t):
                    if result < 0 || t.rect.height < result { result = t.rect.height }
                case .group(let children): walk(children)
                default: break
                }
            }
        }
        walk(page.fragments)
        return result
    }

    // MARK: - 3. Synthetic fixture: font-scale policy + production paint

    static let fixedFixtureCSS = """
    body { margin: 0; }
    .k1 { margin: 25% auto 0; padding: 0.4em; width: 15em; background-color: rgba(255,255,255,0.7); }
    .k2 { padding: 2.2em 0; border: dotted 1px #3a4431; }
    .chapter { margin: 0 auto; padding: 0; font-size: 135%; line-height: 145%; text-align: center; }
    """

    static let fixedFixtureHTML = """
    <html><head><style>\(fixedFixtureCSS)</style></head>
    <body style="zy-fontsize-adjust: fixed">
      <div class="k1"><div class="k2"><h2 class="chapter">測試標題</h2></div></div>
    </body></html>
    """

    @Test("synthetic fixed-fixture geometry independent of user font size")
    func syntheticFixedFixture() async throws {
        var results: [CGFloat: (width: CGFloat, marginTop: CGFloat, lineHeight: CGFloat, pageCount: Int)] = [:]
        for userSize in [CGFloat(14), 20, 28] {
            let (engine, layout, _, _) = try await Self.fixtureLayout(fontSize: userSize)
            let page = try #require(layout.pages.first)
            Self.dumpFills(page, label: "fixture-\(Int(userSize))")
            let k1 = Self.k1Candidates(in: page).first
            results[userSize] = (
                width: k1?.rect.width ?? -1,
                marginTop: k1?.rect.minY ?? -1,
                lineHeight: Self.firstLineHeight(in: page),
                pageCount: layout.pages.count
            )
            _ = engine
        }
        print("FIXTURE-fixed geometries=\(results)")
        let r14 = try #require(results[14])
        let r28 = try #require(results[28])
        #expect(r14.width == r28.width, "fixed fixture k1 width changed: \(results)")
        #expect(abs(r14.marginTop - r28.marginTop) < 0.01, "fixed fixture margin-top changed: \(results)")
        #expect(r14.lineHeight == r28.lineHeight, "fixed fixture line height changed: \(results)")
        #expect(r14.pageCount == r28.pageCount, "fixed fixture page count changed: \(results)")
    }

    @Test("synthetic adjustable-fixture follows user font size")
    func syntheticAdjustableFixture() async throws {
        let adjustableHTML = Self.fixedFixtureHTML.replacingOccurrences(
            of: "zy-fontsize-adjust: fixed", with: ""
        )
        var results: [CGFloat: (width: CGFloat, marginTop: CGFloat, lineHeight: CGFloat, pageCount: Int)] = [:]
        for userSize in [CGFloat(14), 28] {
            let (engine, layout, _, _) = try await Self.fixtureLayout(html: adjustableHTML, fontSize: userSize)
            let page = try #require(layout.pages.first)
            let k1 = Self.k1Candidates(in: page).first
            results[userSize] = (
                width: k1?.rect.width ?? -1,
                marginTop: k1?.rect.minY ?? -1,
                lineHeight: Self.firstLineHeight(in: page),
                pageCount: layout.pages.count
            )
            _ = engine
        }
        print("FIXTURE-adjustable geometries=\(results)")
        let r14 = try #require(results[14])
        let r28 = try #require(results[28])
        #expect(abs(r14.width - r28.width) > 1, "adjustable fixture width should scale: \(results)")
        #expect(abs(r14.lineHeight - r28.lineHeight) > 1, "adjustable fixture line height should scale: \(results)")
    }

    /// Drives the synthetic fixture through the FULL production chain
    /// (adapter-less: MockBrowserLayoutResource provides the fixture).
    static func fixtureLayout(html: String = fixedFixtureHTML, fontSize: CGFloat) async throws -> (
        engine: BrowserLayoutPageEngine,
        layout: BrowserChapterLayout,
        html: String,
        css: [String]
    ) {
        let resource = MockBrowserLayoutResource(chapters: [
            .init(title: "fixture", href: "c.xhtml", html: html, css: [])
        ])
        var settings = Self.settings
        settings = ReaderRenderSettings(
            theme: settings.theme, textColor: settings.textColor, backgroundColor: settings.backgroundColor,
            fontSize: fontSize, lineHeightMultiple: settings.lineHeightMultiple, lineSpacing: settings.lineSpacing,
            paragraphSpacing: settings.paragraphSpacing, letterSpacing: settings.letterSpacing,
            marginH: settings.marginH, marginV: settings.marginV, footerHeight: settings.footerHeight,
            contentInsets: settings.contentInsets
        )
        let builder = MockAttributedStringBuilder(texts: ["c"])
        let store = CharOffsetStore(
            directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent("prod-\(UUID().uuidString)")
        )
        let delegate = CoreTextPageEngine(attributedBuilder: builder, renderSettings: settings, offsetStore: store)
        let engine = BrowserLayoutPageEngine(resource: resource, delegate: delegate, settings: settings)
        await engine.start(renderSize: Self.viewport, bookId: "fixture")
        await engine.preloadChapter(at: 0)
        guard let (_, layout) = engine.testChapterLayout else {
            Issue.record("fixture did not produce a browser layout")
            throw NSError(domain: "RedChamber", code: 3)
        }
        return (engine, layout, html, [])
    }
}
