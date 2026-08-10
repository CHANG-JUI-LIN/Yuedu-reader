import CoreText
import Testing
import SwiftSoup
import UIKit
@testable import yuedu_app

/// Real-EPUB regression suite for 《红楼梦+大观红楼》 (People's Literature
/// Publishing). The EPUB path comes from the environment variable
/// `YUEDU_HONGLOUMENG_EPUB_PATH`; when absent, every test skips EXPLICITLY
/// via `#require(…, .skip)` — never a silent pass, never a zero-test run.
///
/// Covers: chapter location via reading order, stylesheet + inline-style
/// cascade, cover-page box geometry (k1/k2), body background-image paint,
/// text/pagination source parity, and DOM-aware capability scanning.
///
/// No book content, images, or goldens are committed — diagnostics go to the
/// temp directory only.
@MainActor
struct BrowserLayoutRedChamberRegressionTests {

    // MARK: - Configuration

    /// Viewport used for every layout in this suite.
    static let viewport = CGSize(width: 390, height: 844)
    /// Fixed reader settings: explicit insets, fixed font size, horizontal mode.
    static let settings = ReaderRenderSettings(
        theme: "paper", textColor: .black, backgroundColor: .white,
        fontSize: 17, lineHeightMultiple: 1.4, lineSpacing: 0, paragraphSpacing: 6,
        letterSpacing: 0, marginH: 12, marginV: 12, footerHeight: 24,
        contentInsets: UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    )

    /// Content rect after insets.
    static var contentRect: CGRect {
        CGRect(x: Self.settings.contentInsets.left,
               y: Self.settings.contentInsets.top,
               width: Self.viewport.width - Self.settings.contentInsets.left - Self.settings.contentInsets.right,
               height: Self.viewport.height - Self.settings.contentInsets.top - Self.settings.contentInsets.bottom)
    }

    /// Non-isolated so the `.enabled(if:)` test traits (Sendable closures)
    /// can reference it directly.
    ///
    /// Resolution order: the environment variable wins; otherwise a known local
    /// path is used when present (CI/other machines simply skip). The EPUB is
    /// NEVER committed — only the path is referenced here.
    nonisolated static var epubPath: String? {
        if let env = ProcessInfo.processInfo.environment["YUEDU_HONGLOUMENG_EPUB_PATH"], !env.isEmpty {
            return env
        }
        let local = "/Users/zhangruilin/Desktop/Test document/EPUB Format/《红楼梦+大观红楼》人民文学出版.epub"
        return FileManager.default.fileExists(atPath: local) ? local : nil
    }

    /// Shared session opened once per test run (opening is expensive).
    private static var sharedSession: PublicationSession?

    static func session() async throws -> PublicationSession {
        if let sharedSession { return sharedSession }
        let path = try #require(epubPath, "YUEDU_HONGLOUMENG_EPUB_PATH not set (tests are .enabled(if:) gated)")
        let s = try await PublicationSession.open(sourceURL: URL(fileURLWithPath: path))
        sharedSession = s
        return s
    }

    // MARK: - Chapter location

    /// Locates the first 第一回 chapter by reading order, matching the visible
    /// <title> or heading text. Never relies on spine index or file names.
    static func locateFirstChapter(session: PublicationSession) async throws -> Int {
        let targetPrefix = "第一回"
        var titlesSeen: [String] = []
        for index in session.chapters.indices {
            let html = try await session.chapterHTML(at: index)
            let title = Self.titleText(of: html)
            titlesSeen.append(title)
            if title.contains(targetPrefix),
               (title.contains("甄士隐") || title.contains("贾雨村")) {
                return index
            }
            // The first 回 always appears early in the reading order.
            if index > 40 { break }
        }
        Issue.record("first 回 chapter not found. Titles seen (first 10): \(titlesSeen.prefix(10))")
        throw NSError(domain: "RedChamber", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "first 回 chapter not found"])
    }

    /// Visible title from XHTML: <title> in head, else first h1/h2 text.
    static func titleText(of html: String) -> String {
        if let doc = try? SwiftSoup.parse(html) {
            let title = ((try? doc.title()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return title }
        }
        if let doc = try? SwiftSoup.parse(html),
           let h = try? doc.select("h1, h2, h3").first(),
           let text = try? h.text() {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    // MARK: - Chapter context

    /// Loads the chapter's CSS + HTML exactly as the reader pipeline does.
    static func chapterContext(session: PublicationSession, spine: Int) async -> (html: String, css: [String], adapter: EPUBBrowserLayoutResourceAdapter) {
        let adapter = EPUBBrowserLayoutResourceAdapter(session: session)
        let html = (try? await adapter.chapterHTML(at: spine)) ?? ""
        let css = await adapter.processedCSS(forChapter: spine)
        return (html, css, adapter)
    }

    static func makeConfig(adapter: EPUBBrowserLayoutResourceAdapter, images: [String: UIImage]) -> BrowserLayoutConfig {
        BrowserLayoutConfig(
            renderWidth: contentRect.width,
            renderHeight: contentRect.height,
            rootFontSize: settings.fontSize,
            fontFamilies: [],
            textColor: settings.textColor,
            backgroundColor: settings.backgroundColor,
            contentInsets: settings.contentInsets,
            lineHeight: settings.lineHeightMultiple,
            fontResolver: adapter.fontResolver()
        )
    }

    // MARK: - 1. Chapter location

    @Test("locates 第一回 via reading order", .enabled(if: epubPath != nil))
    func locateFirstChapterByReadingOrder() async throws {
        let session = try await Self.session()
        let spine = try await Self.locateFirstChapter(session: session)
        let title = session.chapters[spine].title
        #expect(!title.isEmpty)
        print("RedChamber: spine=\(spine) title=\(title)")
    }

    // MARK: - 2. Resources & cascade

    @Test("chapter loads linked stylesheets and body inline style", .enabled(if: epubPath != nil))
    func stylesheetsAndInlineCascade() async throws {
        let session = try await Self.session()
        let spine = try await Self.locateFirstChapter(session: session)
        let (html, css, _) = await Self.chapterContext(session: session, spine: spine)

        #expect(!css.isEmpty, "no processed CSS for the chapter")
        let allCSS = css.joined(separator: "\n")

        // Key rules from the shared stylesheet must survive processing.
        for fragment in ["div.k1", "div.k2", ".chapter", "background-image", "background-size", "border-radius"] {
            #expect(allCSS.contains(fragment), "missing CSS fragment: \(fragment)")
        }
        // The percentage margin must survive (vertical % margin vs width base).
        #expect(allCSS.contains("25%"), "expected percentage margin in CSS")

        // The body element must carry the inline style attributes.
        let doc = try SwiftSoup.parse(html)
        let body = try #require(doc.body(), "chapter HTML has no body")
        let inlineStyle = (try? body.attr("style")) ?? ""
        #expect(inlineStyle.contains("background-image"), "body inline background-image missing: \(inlineStyle.prefix(120))")
        #expect(inlineStyle.contains("background-size"), "body inline background-size missing")
        #expect(inlineStyle.contains("background-position"), "body inline background-position missing")
        #expect(inlineStyle.contains("background-attachment"), "body inline background-attachment missing")
    }

    // MARK: - 3. Box geometry (k1/k2)

    /// Builds the box tree via the shared pipeline (for geometry assertions).
    static func buildBoxTree(spine: Int) async throws -> (String, BlockBox) {
        let session = try await Self.session()
        let (html, css, adapter) = await Self.chapterContext(session: session, spine: spine)
        let config = Self.makeConfig(adapter: adapter, images: [:])
        let doc = BrowserLayoutDocument(html: html, cssTexts: css, config: config, imageLoader: { _ in nil })
        let result = try doc.makeLayout(containerSize: Self.viewport)
        return (result.sourceText, result.rootBox)
    }

    /// Finds the first box whose style carries the k1 signature: width 15em.
    static func findK1(in box: BlockBox) -> BlockBox? {
        if box.style.width == .em(15) { return box }
        for child in box.children {
            if let found = findK1(in: child) { return found }
        }
        return nil
    }

    /// Finds the first box whose style carries the k2 signature: padding 2.2em 0
    /// and a 1pt dotted border, inside the k1 subtree.
    static func findK2(in box: BlockBox) -> BlockBox? {
        if box.style.paddingTop == .em(2.2), box.style.borderTopWidth == 1 { return box }
        for child in box.children {
            if let found = findK2(in: child) { return found }
        }
        return nil
    }

    /// First-line geometry with the four concepts kept APART:
    /// - `lineBoxRect`: the line box (content box of the line) in page-local
    ///   UIKit coordinates — its top is NOT a baseline.
    /// - `baselineY`: the baseline origin the engine actually placed the line
    ///   at (TextFragment.baselineY, set by the walker from the line box's
    ///   baseline), in page-local UIKit coordinates. NOT lineBoxRect.minY.
    /// - `glyphInkBounds`: the glyph ink bounds from the REAL CTLine
    ///   (CTLineGetBoundsWithOptions(.useGlyphPathBounds)), converted from
    ///   CoreText baseline-relative coordinates to page-local UIKit.
    /// - `ascent`/`descent`/`leading`: typographic bounds from the REAL CTLine
    ///   (CTLineGetTypographicBounds). Ink bounds do NOT have to equal the
    ///   ascent/descent box — never assert ink == line box.
    struct LineGeometryDiagnostics {
        let lineBoxRect: CGRect
        let baselineY: CGFloat
        let glyphInkBounds: CGRect
        let ascent: CGFloat
        let descent: CGFloat
        let leading: CGFloat

        var summary: String {
            "lineBox=\(lineBoxRect) baselineY=\(baselineY) ink=\(glyphInkBounds) " +
            "ascent=\(ascent) descent=\(descent) leading=\(leading)"
        }
    }

    /// Extracts first-line diagnostics from the fragment's retained CTLine.
    /// Returns nil when the fragment carries no CTLine (unshaped fallback).
    static func lineDiagnostics(from fragment: TextFragment) -> LineGeometryDiagnostics? {
        guard let line = fragment.ctLine else { return nil }
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let ink = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        // CoreText ink bounds are relative to the line's baseline origin with
        // Y pointing UP; convert to page-local UIKit (Y down, origin = the
        // fragment's line-box left edge which is where the line content starts
        // for a left-aligned first line).
        let inkRect = CGRect(
            x: fragment.rect.minX + ink.minX,
            y: fragment.baselineY - ink.maxY,
            width: ink.width,
            height: ink.height
        )
        return LineGeometryDiagnostics(
            lineBoxRect: fragment.rect.rawValue,
            baselineY: fragment.baselineY,
            glyphInkBounds: inkRect,
            ascent: ascent,
            descent: descent,
            leading: leading
        )
    }

    /// The first text fragment of the cover chapter (smallest rect.minY).
    static func firstTextFragment(of rootBox: BlockBox) -> TextFragment? {
        BrowserLayoutTestSupport.allTextFragments(
            PageFragmentation.fragment(box: rootBox, pageSize: Self.contentRect.size)
        ).min(by: { $0.rect.minY < $1.rect.minY })
    }

    @Test("k1/k2 cover-page box geometry", .enabled(if: epubPath != nil))
    func coverPageBoxGeometry() async throws {
        let session = try await Self.session()
        let spine = try await Self.locateFirstChapter(session: session)
        let (_, rootBox) = try await Self.buildBoxTree(spine: spine)

        let k1 = try #require(Self.findK1(in: rootBox), "k1 box (width:15em) not found")
        let k2 = try #require(Self.findK2(in: rootBox), "k2 box (padding:2.2em,border:1pt) not found")
        // Diagnostic (spec: print on failure).
        print("DIAG k1 frame=\(k1.frame) margins=\(k1.margins) padding=\(k1.padding) borders=\(k1.borders) fontSize=\(k1.style.fontSize)")
        print("DIAG k2 frame=\(k2.frame) margins=\(k2.margins) padding=\(k2.padding) borders=\(k2.borders) fontSize=\(k2.style.fontSize)")
        print("DIAG root frame=\(rootBox.frame) content=\(rootBox.contentSize) margins=\(rootBox.margins)")
        print("DIAG k1 block=\(k1.logicalBlockOrigin) inline=\(k1.logicalInlineOrigin) k2 block=\(k2.logicalBlockOrigin) inline=\(k2.logicalInlineOrigin)")

        // k1 used margin-top ≈ containing-block width × 0.25. The containing
        // block is the BODY content box (358.68 = 366 − body margins), NOT the
        // viewport content rect — CSS vertical % margins resolve against the
        // containing block WIDTH, and body's own margins shrink it.
        let containingBlockWidth = rootBox.contentSize.width
        let expectedTopMargin = containingBlockWidth * 0.25
        #expect(abs(k1.margins.top - expectedTopMargin) <= 1.0,
                "k1 margin-top \(k1.margins.top) != \(expectedTopMargin) (25% of \(containingBlockWidth))")

        // k1 content width ≈ 15 × computed font size.
        let expectedWidth = 15 * k1.style.fontSize
        #expect(abs(k1.contentSize.width - expectedWidth) <= 1.0,
                "k1 content width \(k1.contentSize.width) != \(expectedWidth) (15em at \(k1.style.fontSize))")

        // k1 auto left/right margins equal → horizontally centered.
        #expect(abs(k1.margins.left - k1.margins.right) <= 0.5,
                "k1 auto margins unequal: left=\(k1.margins.left) right=\(k1.margins.right)")

        // k2 sits inside k1's content box. k2.logicalBlockOrigin is relative to
        // k1's CONTENT box (k2 is k1's child), so 0 means "at k1 content top".
        #expect(k2.logicalBlockOrigin >= -0.5, "k2 above k1 content top")
        let k2AbsoluteMin = k1.logicalBlockOrigin + k1.padding.top + k1.borders.top + k2.logicalBlockOrigin
        let k2AbsoluteMax = k2AbsoluteMin + k2.contentSize.height
        let k1ContentMax = k1.logicalBlockOrigin + k1.padding.top + k1.borders.top + k1.contentSize.height
        #expect(k2AbsoluteMax <= k1ContentMax + 0.5, "k2 below k1 content bottom")

        // k2 padding ≈ 2.2 × computed font size; border ≈ 1pt.
        let k2FontSize = k2.style.fontSize
        #expect(abs(k2.padding.top - 2.2 * k2FontSize) <= 1.0,
                "k2 padding-top \(k2.padding.top) != \(2.2 * k2FontSize)")
        #expect(abs(k2.padding.bottom - 2.2 * k2FontSize) <= 1.0,
                "k2 padding-bottom \(k2.padding.bottom) != \(2.2 * k2FontSize)")
        #expect(abs(k2.borders.top - 1) <= 0.5, "k2 border-top \(k2.borders.top) != 1pt")

        // First chapter-name text: its absolute y (the walker's fragment y)
        // must sit after k1 margin-top + padding + k2 border + k2 padding —
        // never at the page top. Derive it from the laid-out fragments.
        let fragment = BrowserLayoutTestSupport.allTextFragments(
            PageFragmentation.fragment(box: rootBox, pageSize: Self.contentRect.size)
        )
        let firstText = try #require(fragment.min(by: { $0.rect.minY < $1.rect.minY }), "no text fragments")
        let expectedFirstLineTop = rootBox.margins.top
            + k1.padding.top + k1.borders.top
            + k2.borders.top + k2.padding.top
        #expect(firstText.rect.minY >= expectedFirstLineTop - 1.0,
                "first text y \(firstText.rect.minY) < expected \(expectedFirstLineTop) (cover starts too high)")

        // Sanity: finite, non-negative, and the title box stays in viewport.
        for box in [k1, k2] {
            #expect(box.frame.width.isFinite && box.frame.height.isFinite, "non-finite box size")
            #expect(box.frame.width >= 0 && box.frame.height >= 0, "negative box size")
        }
        #expect(k1.frame.maxX <= Self.viewport.width + 0.5, "k1 box exceeds viewport")
    }

    /// First-line geometry on the cover chapter: distinguishes line-box top,
    /// baseline, typographic bounds and glyph ink bounds — never conflates them.
    ///
    /// Assertions:
    /// - lineBoxRect.minY == expectedContentTop (k1 margin-top + padding +
    ///   k2 border + padding) — the LINE BOX top, not a baseline.
    /// - browser-style half-leading baseline placement:
    ///   baselineY == lineBoxRect.minY + halfLeading + ascent.
    /// - basic containment: ink sits inside the line box; the baseline lies
    ///   below the ink top and within descent of the ink bottom.
    @Test("first-line geometry: line box / baseline / ink / metrics", .enabled(if: epubPath != nil))
    func firstLineGeometry() async throws {
        let session = try await Self.session()
        let spine = try await Self.locateFirstChapter(session: session)
        let (_, rootBox) = try await Self.buildBoxTree(spine: spine)

        let k1 = try #require(Self.findK1(in: rootBox), "k1 box (width:15em) not found")
        let k2 = try #require(Self.findK2(in: rootBox), "k2 box (padding:2.2em,border:1pt) not found")
        let firstText = try #require(Self.firstTextFragment(of: rootBox), "no text fragments on cover")
        let diag = try #require(Self.lineDiagnostics(from: firstText),
                                "first fragment lost its CTLine (unshaped fallback)")

        // Expected content top: k1 used margin-top + padding + k2 border + padding.
        let expectedContentTop = k1.margins.top
            + k1.padding.top
            + k2.borders.top
            + k2.padding.top
        #expect(abs(diag.lineBoxRect.minY - expectedContentTop) < 1.0,
                "line box top \(diag.lineBoxRect.minY) != \(expectedContentTop)")

        // Browser-style half-leading: extraLeading split above/below the
        // natural (ascent+descent) box, baseline sits at halfLeading + ascent
        // below the line box top.
        let naturalHeight = diag.ascent + diag.descent
        let computedLineHeight = diag.lineBoxRect.height
        let halfLeading = max(0, computedLineHeight - naturalHeight) / 2
        let expectedBaseline = diag.lineBoxRect.minY + halfLeading + diag.ascent
        #expect(abs(diag.baselineY - expectedBaseline) < 1.0,
                "baseline \(diag.baselineY) != half-leading expected \(expectedBaseline)")

        // Basic geometric relations (ink does NOT have to hug the line box).
        #expect(diag.lineBoxRect.contains(diag.glyphInkBounds),
                "ink \(diag.glyphInkBounds) outside line box \(diag.lineBoxRect)")
        #expect(diag.baselineY > diag.glyphInkBounds.minY,
                "baseline \(diag.baselineY) above ink top \(diag.glyphInkBounds.minY)")
        #expect(diag.baselineY < diag.glyphInkBounds.maxY + diag.descent + 1,
                "baseline \(diag.baselineY) not within descent of ink bottom \(diag.glyphInkBounds.maxY)")

        // Full four-group output for any future diagnosis (spec: never mix
        // line-box top / baseline / typographic bounds / glyph ink bounds).
        print("GEOM firstLineBox.minY=\(diag.lineBoxRect.minY) maxY=\(diag.lineBoxRect.maxY)")
        print("GEOM firstBaselineY=\(diag.baselineY)")
        print("GEOM firstGlyphInkBounds=\(diag.glyphInkBounds)")
        print("GEOM fontAscent=\(diag.ascent) fontDescent=\(diag.descent) fontLeading=\(diag.leading)")
        print("GEOM computedLineHeight=\(diag.lineBoxRect.height) halfLeading=\(halfLeading)")
        print("GEOM expectedContentTop=\(expectedContentTop) full=\(diag.summary)")
    }

    // MARK: - 4. Background image paint

    /// Generates a checkered image (synthetic; no book content).
    static func checkerImage(size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor.gray.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: size.width / 2, height: size.height / 2))
            ctx.fill(CGRect(x: size.width / 2, y: size.height / 2, width: size.width / 2, height: size.height / 2))
        }
    }

    @Test("body background-image renders as a DisplayList command", .enabled(if: epubPath != nil))
    func backgroundImagePaint() async throws {
        let session = try await Self.session()
        let spine = try await Self.locateFirstChapter(session: session)
        let (html, css, adapter) = await Self.chapterContext(session: session, spine: spine)

        // Resolve the body's inline background-image source via the adapter.
        var bgSource: String? = nil
        if let doc = try? SwiftSoup.parse(html), let body = doc.body() {
            let inline = (try? body.attr("style")) ?? ""
            let decl = CSSParser.parseDeclarationBlock(inline)
            bgSource = decl.normal["background-image"] ?? decl.important["background-image"]
        }
        let source = try #require(bgSource, "body inline background-image not found")

        let checker = Self.checkerImage(size: CGSize(width: 64, height: 64))
        let config = Self.makeConfig(adapter: adapter, images: [source: checker])
        // EXACT-KEYED loader. This used to be `{ _ in checker }` — a catch-all
        // that answered any source at all, which made the real defect
        // unobservable: the style tree was folding `url()` payloads to lower
        // case, so the source it asked for (`../images/…`) could never equal a
        // key the prefetcher stored (`../Images/…`), and every authored body
        // background silently painted nothing on device. A loader that only
        // answers the authored source is the whole point of this test.
        let authored = try #require(
            ComputedStylePropertyApplier.parseBackgroundImageSource(source),
            "could not parse url() out of the authored declaration"
        )
        let doc = BrowserLayoutDocument(html: html, cssTexts: css, config: config, imageLoader: { $0 == authored ? checker : nil })
        let pages = try await doc.renderPages(containerSize: Self.viewport)

        let page = try #require(pages.first, "no pages laid out")
        let list = DisplayListBuilder.build(for: page, sourceText: doc.lastSourceText)

        // The page's display list must contain a full-viewport background
        // image/fill command (not just the reader theme fill).
        var found: CGRect? = nil
        for item in list.items {
            switch item {
            case .fill(let f):
                if f.rect.width >= Self.contentRect.width * 0.99,
                   f.rect.height >= Self.contentRect.height * 0.99 {
                    found = f.rect.rawValue
                }
            case .image(let i):
                // The authored background source may resolve to a normalized
                // path; match any full-viewport image command.
                if i.rect.width >= Self.viewport.width * 0.99,
                   i.rect.height >= Self.viewport.height * 0.99 {
                    found = i.rect.rawValue
                }
            default: break
            }
        }
        let rect = try #require(found, "no background image/fill command in page 0 display list")
        // cover semantics: the resolved rect covers the viewport.
        #expect(rect.width >= Self.viewport.width * 0.99, "background rect too narrow: \(rect)")
        #expect(rect.height >= Self.viewport.height * 0.99, "background rect too short: \(rect)")
    }

    /// Spines carrying a body background, one per DECLARATION KIND — the two
    /// kinds travel different code paths and broke for different reasons:
    /// - inline `style="…background-image:url(../Images/x.jpg)…"` — a relative
    ///   href, killed by the style tree's case folding;
    /// - `<body class="qmp…">` matched by a stylesheet rule — already rewritten
    ///   to an absolute `reader-book://` URL, killed by the prefetcher feeding
    ///   that URL back through `resourceURL(for:)`.
    static func backgroundChapters(session: PublicationSession) async -> (inline: Int?, classBased: Int?) {
        var inline: Int? = nil
        var classBased: Int? = nil
        for index in session.chapters.indices.prefix(24) {
            guard let html = try? await session.chapterHTML(at: index),
                  let body = (try? SwiftSoup.parse(html))?.body() else { continue }
            let style = (try? body.attr("style")) ?? ""
            let classes = ((try? body.classNames().map { $0 }) ?? [])
            if inline == nil, style.contains("background") { inline = index }
            if classBased == nil, style.isEmpty, !classes.isEmpty { classBased = index }
            if inline != nil, classBased != nil { break }
        }
        return (inline, classBased)
    }

    @Test("every body background source the style tree resolves is loadable", .enabled(if: epubPath != nil))
    func bodyBackgroundSourcesAreAllLoadable() async throws {
        let session = try await Self.session()
        let candidates = await Self.backgroundChapters(session: session)
        let spines = [candidates.inline, candidates.classBased].compactMap { $0 }
        #expect(spines.count == 2, "expected an inline-style AND a class-based background chapter, got \(spines)")

        for spine in spines {
            let (html, css, adapter) = await Self.chapterContext(session: session, spine: spine)
            let images = await adapter.prefetchImages(forChapter: spine, html: html, renderWidth: Self.contentRect.width)
            let config = Self.makeConfig(adapter: adapter, images: images)
            let document = BrowserLayoutDocument(
                html: html, cssTexts: css, config: config, imageLoader: { images[$0] }
            )
            let result = try document.makeLayout(containerSize: Self.viewport)
            let background = BrowserLayoutDocument.bodyBackground(rootBox: result.rootBox)
            let source = try #require(
                background.image?.source,
                "spine \(spine): the style tree resolved no body background-image at all"
            )
            // THE invariant: whatever source the COMPUTED style tree asks the
            // image loader for must resolve to real bytes. Both declaration
            // kinds are covered — an inline relative href (killed by case
            // folding) and a stylesheet rule already rewritten to an absolute
            // `reader-book://` URL (killed by being re-wrapped as an href).
            // A failure here is the 白屏 chapter on device.
            let image = await adapter.loadImage(
                forChapter: spine, source: source, renderWidth: Self.contentRect.width
            )
            #expect(image != nil, "spine \(spine): unloadable body background source: \(source)")
        }
    }

    /// DIAGNOSTIC (prints, asserts almost nothing): what is actually PAINTED on
    /// the 回目 title page, in draw order.
    ///
    /// The white plate behind the title is `div.k1 { background-color:
    /// rgba(255,255,255,0.7) }` — authored, and meant to be translucent. Reading
    /// its size and alpha off a screenshot gave contradictory answers, so this
    /// dumps the real numbers: every fill's rect + RGBA, the background image's
    /// rect, and the k1/k2 box frames it should agree with.
    @Test("DIAG: title-page paint order, fill rects and alpha", .enabled(if: epubPath != nil))
    func diagnosticTitlePagePaint() async throws {
        let session = try await Self.session()
        let spine = try await Self.locateFirstChapter(session: session)
        let (html, css, adapter) = await Self.chapterContext(session: session, spine: spine)
        let images = await adapter.prefetchImages(
            forChapter: spine, html: html, renderWidth: Self.contentRect.width
        )
        // Two font sizes on purpose. `resolveSides` clamps an explicit width to
        // the container (`min(width, containerWidth)`), and k1 is `width: 15em`
        // — so at a large reader font size 15em EXCEEDS the 366pt content column
        // and the plate silently becomes full-width. At 17pt it does not. If the
        // white plate only misbehaves in the second block, that clamp is why.
        for fontSize in [CGFloat(17), CGFloat(26)] {
        let config = BrowserLayoutConfig(
            renderWidth: Self.contentRect.width,
            renderHeight: Self.contentRect.height,
            rootFontSize: fontSize,
            fontFamilies: [],
            textColor: Self.settings.textColor,
            backgroundColor: Self.settings.backgroundColor,
            contentInsets: Self.settings.contentInsets,
            lineHeight: Self.settings.lineHeightMultiple,
            fontResolver: adapter.fontResolver()
        )
        let document = BrowserLayoutDocument(
            html: html, cssTexts: css, config: config, imageLoader: { images[$0] }
        )
        let result = try document.makeLayout(containerSize: Self.viewport)

        print("DIAG ======== rootFontSize=\(fontSize) 15em=\(15 * fontSize) contentWidth=\(Self.contentRect.width)")
        if let k1 = Self.findK1(in: result.rootBox) {
            print("DIAG k1 frame=\(k1.frame.rawValue) content=\(k1.contentSize) padding=\(k1.padding) borders=\(k1.borders) margins=\(k1.margins) fontSize=\(k1.style.fontSize)")
            print("DIAG k1 background=\(Self.describe(k1.style.backgroundColor)) radius=\(k1.style.borderRadius)")
        } else {
            print("DIAG k1 NOT FOUND")
        }
        if let k2 = Self.findK2(in: result.rootBox) {
            print("DIAG k2 frame=\(k2.frame.rawValue) content=\(k2.contentSize) padding=\(k2.padding) borders=\(k2.borders) fontSize=\(k2.style.fontSize)")
        } else {
            print("DIAG k2 NOT FOUND")
        }

        let pages = try await document.renderPages(containerSize: Self.viewport)
        let page = try #require(pages.first, "no pages")
        let list = DisplayListBuilder.build(for: page, sourceText: document.lastSourceText)
        print("DIAG ---- page 0 draw order (\(list.items.count) items)")
        for (i, item) in list.items.enumerated() {
            switch item {
            case .fill(let f):
                print("DIAG [\(i)] FILL   rect=\(f.rect.rawValue) color=\(Self.describe(f.color)) radius=\(f.cornerRadius) borderTop=\(f.borderTop.width)/\(f.borderTop.style)")
            case .image(let im):
                print("DIAG [\(i)] IMAGE  rect=\(im.rect.rawValue) bgPaint=\(im.isBackgroundPaint) size=\(im.image?.size ?? .zero) src=\(im.source.suffix(28))")
            case .text(let t):
                print("DIAG [\(i)] TEXT   rect=\(t.rect.rawValue) \"\(t.text.prefix(12))\"")
            }
        }
        // The only hard assertion: nothing paints wider than the page.
        for case .fill(let f) in list.items where f.color != .clear {
            #expect(f.rect.width <= Self.viewport.width + 0.5,
                    "a fill is wider than the page: \(f.rect.rawValue)")
        }
        }
    }

    /// "r,g,b,a" for a UIColor, or "nil".
    static func describe(_ color: UIColor?) -> String {
        guard let color else { return "nil" }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return "\(color)" }
        return String(format: "rgba(%.0f,%.0f,%.0f,%.3f)", r * 255, g * 255, b * 255, a)
    }

    @Test("duokan popup footnotes are indexed for the browser engine", .enabled(if: epubPath != nil))
    func duokanFootnotesAreIndexed() async throws {
        let session = try await Self.session()
        // The 回目 title pages carry the footnote payload; scan a bounded range.
        var found: (spine: Int, id: String)? = nil
        for spine in session.chapters.indices.prefix(24) {
            guard let html = try? await session.chapterHTML(at: spine),
                  let doc = try? SwiftSoup.parse(html) else { continue }
            for item in (try? doc.select("li[id]").array()) ?? [] {
                let classes = ((try? item.classNames().map { $0 }) ?? [])
                guard classes.contains(where: { $0.contains("footnote") }) else { continue }
                let id = (try? item.attr("id")) ?? ""
                if !id.isEmpty { found = (spine, id); break }
            }
            if found != nil { break }
        }
        let target = try #require(found, "no duokan footnote item in the first 24 chapters")
        let (html, css, adapter) = await Self.chapterContext(session: session, spine: target.spine)
        let config = Self.makeConfig(adapter: adapter, images: [:])
        let document = BrowserLayoutDocument(html: html, cssTexts: css, config: config, imageLoader: { _ in nil })
        let result = try document.makeLayout(containerSize: Self.viewport)
        let note = try #require(
            result.footnotes[target.id],
            "footnote \(target.id) was not collected by the layout pipeline"
        )
        #expect(!note.isEmpty)

        // Published to the SAME store the legacy engine and the reader use, and
        // reachable by the href form a marker tap delivers.
        FootnoteStore.index(notes: result.footnotes, spineIndex: target.spine)
        #expect(FootnoteStore.text(spineIndex: target.spine, href: "#\(target.id)") == note)
    }

    // MARK: - 5. Text & pagination

    @Test("first-chapter visible text matches expected string", .enabled(if: epubPath != nil))
    func visibleTextParity() async throws {
        let session = try await Self.session()
        let spine = try await Self.locateFirstChapter(session: session)
        let (pages, doc, _, _) = try await Self.layoutChapter(spine: spine)

        let visible = BrowserLayoutTestSupport.visibleText(pages, sourceText: doc.lastSourceText)
        let normalized = visible
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
        let expected = "第一回甄士隐梦幻识通灵贾雨村风尘怀闺秀"
        #expect(normalized.contains(expected),
                "visible text missing title: got prefix \(normalized.prefix(60))")
        #expect(BrowserLayoutTestSupport.rangesAreOrdered(pages), "fragment source ranges not ordered")
    }

    static func layoutChapter(spine: Int, images: [String: UIImage] = [:]) async throws -> (pages: [PageFragments], doc: BrowserLayoutDocument, html: String, css: [String]) {
        let session = try await Self.session()
        let (html, css, adapter) = await Self.chapterContext(session: session, spine: spine)
        let config = Self.makeConfig(adapter: adapter, images: images)
        let doc = BrowserLayoutDocument(html: html, cssTexts: css, config: config, imageLoader: { images[$0] })
        let pages = try await doc.renderPages(containerSize: Self.viewport)
        return (pages, doc, html, css)
    }

    @Test("incremental first page equals batch first page", .enabled(if: epubPath != nil))
    func incrementalBatchFirstPageParity() async throws {
        let session = try await Self.session()
        let spine = try await Self.locateFirstChapter(session: session)
        let (html, css, adapter) = await Self.chapterContext(session: session, spine: spine)
        let config = Self.makeConfig(adapter: adapter, images: [:])

        let doc = BrowserLayoutDocument(html: html, cssTexts: css, config: config, imageLoader: { _ in nil })
        // Batch path: the SAME canvas contract as the session (full viewport +
        // content insets + background injection).
        let batch = try await doc.renderPages(containerSize: Self.viewport)
        let batchFirst = try #require(batch.first)

        // The session builds its own pipeline; a fresh adapter avoids any
        // shared font-registration state between the two paths.
        let freshAdapter = EPUBBrowserLayoutResourceAdapter(session: session)
        let freshCSS = await freshAdapter.processedCSS(forChapter: spine)
        let session2 = BrowserLayoutSession(
            html: html, cssTexts: freshCSS, config: config, imageLoader: { _ in nil }, generation: 1
        )
        let incrementalFirst = try await session2.layoutNextPage()
        let incr = try #require(incrementalFirst)

        #expect(incr.index == batchFirst.index)
        #expect(Self.fragmentSignature(incr.fragments) == Self.fragmentSignature(batchFirst.fragments),
                "incremental first page differs from batch first page")
    }

    static func fragmentSignature(_ fragments: [Fragment]) -> String {
        var out: [String] = []
        func walk(_ frags: [Fragment]) {
            for f in frags {
                switch f {
                case .text(let t):
                    out.append("t\(t.sourceRange.location),\(t.sourceRange.length)@\(t.rect.minX),\(t.rect.minY),\(t.rect.width),\(t.rect.height)")
                case .fill(let f2):
                    out.append("f\(f2.rect.minX),\(f2.rect.minY),\(f2.rect.width),\(f2.rect.height)")
                case .image(let i):
                    out.append("i\(i.source)@\(i.rect.minX),\(i.rect.minY),\(i.rect.width),\(i.rect.height)")
                case .group(let children): walk(children)
                }
            }
        }
        walk(fragments)
        return out.joined(separator: "|")
    }

    // MARK: - 6. Capability scanner

    @Test("scanner accepts the cover chapter (DOM-aware, not whole-CSS text)", .enabled(if: epubPath != nil))
    func scannerAcceptsCoverChapter() async throws {
        let session = try await Self.session()
        let spine = try await Self.locateFirstChapter(session: session)
        let (html, css, _) = await Self.chapterContext(session: session, spine: spine)

        // The chapter DOM is body/div/h2/span/br only — the shared stylesheet
        // may contain float/ruby/calc for OTHER chapters; the scanner must NOT
        // reject this chapter because of unmatched rules.
        let scan = BrowserLayoutCapabilityScanner.scan(html: html, cssTexts: css)
        if !scan.supported {
            var reasons = scan.unsupportedFeatures.map(\.description)
            if let doc = try? SwiftSoup.parse(html) {
                let tags = ((try? doc.select("body, div, h2, span, br, p, a").array().map { (try? $0.tagName()) ?? "" }) ?? [])
                reasons.append("dom=\(Set(tags).sorted())")
            }
            Issue.record("scanner rejected cover chapter: \(reasons)")
        }
        #expect(scan.supported, "scanner must accept the cover chapter")
    }

    // MARK: - 7. Synthetic fixture (committed)

    /// The synthetic cover fixture (no book content) + its CSS.
    static let fixtureCSS = """
    body { margin: 0; }
    .k1 {
      margin: 25% auto 0;
      padding: 0.4em;
      width: 15em;
      background-color: rgba(255,255,255,0.7);
      border-radius: 12px;
    }
    .k2 {
      padding: 2.2em 0;
      border: dotted 1px #3a4431;
    }
    .chapter {
      margin: 0 auto;
      padding: 0;
      font-size: 135%;
      line-height: 145%;
      text-align: center;
    }
    """

    static let fixtureHTML = """
    <html><head><style>\(fixtureCSS)</style></head>
    <body class="test-cover" style="background-image: url(placeholder.png); background-size: cover; background-position: center center; background-repeat: no-repeat; background-attachment: fixed;">
      <div class="k1">
        <div class="k2">
          <h2 class="chapter">
            <span class="small">第一章</span><br/>
            測試標題第一行<br/>
            測試標題第二行
          </h2>
        </div>
      </div>
    </body></html>
    """

    @Test("synthetic cover fixture: k1/k2 geometry + background cover")
    func syntheticFixtureGeometry() async throws {
        let checker = Self.checkerImage(size: CGSize(width: 64, height: 64))
        let config = BrowserLayoutConfig(
            renderWidth: Self.contentRect.width, renderHeight: Self.contentRect.height,
            rootFontSize: Self.settings.fontSize,
            fontFamilies: ["PingFangSC-Regular"], textColor: .black, backgroundColor: .white,
            contentInsets: Self.settings.contentInsets, lineHeight: Self.settings.lineHeightMultiple
        )
        let doc = BrowserLayoutDocument(
            html: Self.fixtureHTML, cssTexts: [], config: config,
            imageLoader: { $0 == "placeholder.png" ? checker : nil }
        )
        let pages = try await doc.renderPages(containerSize: Self.viewport)
        let page = try #require(pages.first)
        let list = DisplayListBuilder.build(for: page, sourceText: doc.lastSourceText)

        // Box geometry via the box tree.
        let result = try doc.makeLayout(containerSize: Self.viewport)
        let k1 = try #require(Self.findK1(in: result.rootBox), "fixture k1 not found")
        let k2 = try #require(Self.findK2(in: result.rootBox), "fixture k2 not found")

        let expectedTopMargin = Self.contentRect.width * 0.25
        #expect(abs(k1.margins.top - expectedTopMargin) <= 1.0,
                "fixture k1 margin-top \(k1.margins.top) != \(expectedTopMargin)")
        let expectedWidth = 15 * k1.style.fontSize
        #expect(abs(k1.contentSize.width - expectedWidth) <= 1.0,
                "fixture k1 width \(k1.contentSize.width) != \(expectedWidth)")
        #expect(abs(k1.margins.left - k1.margins.right) <= 0.5, "fixture k1 not centered")

        let k2FontSize = k2.style.fontSize
        #expect(abs(k2.padding.top - 2.2 * k2FontSize) <= 1.0, "fixture k2 padding-top wrong")
        #expect(abs(k2.borders.top - 1) <= 0.5, "fixture k2 border wrong")

        let firstText = BrowserLayoutTestSupport.allTextFragments(
            PageFragmentation.fragment(box: result.rootBox, pageSize: Self.contentRect.size)
        ).min(by: { $0.rect.minY < $1.rect.minY })
        let firstTextFrag = try #require(firstText, "fixture has no text fragments")
        let expectedLineTop = result.rootBox.margins.top + k1.padding.top + k1.borders.top
            + k2.borders.top + k2.padding.top
        #expect(firstTextFrag.rect.minY >= expectedLineTop - 1.0,
                "fixture first text y \(firstTextFrag.rect.minY) < expected \(expectedLineTop)")

        // Background cover command present.
        var foundBackground = false
        for item in list.items {
            switch item {
            case .image(let i):
                if i.source == "placeholder.png" {
                    foundBackground = true
                    #expect(i.rect.width >= Self.viewport.width * 0.99, "fixture bg not covering width")
                    #expect(i.rect.height >= Self.viewport.height * 0.99, "fixture bg not covering height")
                }
            case .fill(let f):
                if f.rect.width >= Self.contentRect.width * 0.99, f.rect.height >= Self.contentRect.height * 0.99 {
                    foundBackground = true
                }
            default: break
            }
        }
        #expect(foundBackground, "fixture background command missing")
    }
}
