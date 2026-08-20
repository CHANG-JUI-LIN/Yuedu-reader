import Foundation
import UIKit

/// Resumable, cancellable layout for ONE chapter.
///
/// The first `layoutNextPage()` builds the style tree + box tree once and
/// walks to the first page boundary — the first page is then ready WITHOUT
/// laying out the rest of the chapter. Subsequent calls walk one page at a
/// time; completed pages are never re-laid-out. Box continuation state lives
/// inside `PageWalker`'s explicit stack.
///
/// `generation` is a token owned by the caller: a session result must be
/// discarded (not committed) when the caller's generation has advanced.
@MainActor
final class BrowserLayoutSession {

    private let html: String
    private let cssTexts: [String]
    private let config: BrowserLayoutConfig
    private let imageLoader: (String) -> UIImage?
    /// Incremented by the CALLER to invalidate in-flight work.
    let generation: Int
    /// DEBUG-only: spine index for on-device diagnostics (set by the engine).
    var diagnosticSpine: Int = -1

    private var walker: PageWalker?
    private var pipeline: BrowserLayoutDocument.BrowserLayoutPipelineResult?
    private(set) var sourceText = ""
    private(set) var anchorOffsets: [String: Int] = [:]
    private(set) var completedPages: [PageFragments] = []
    private(set) var isFinished = false
    /// Lifecycle accounting: style-tree / box-tree sizes from the pipeline.
    private(set) var pipelineNodeCount = 0
    private(set) var pipelineBoxCount = 0
    /// 多看 popup footnotes found while parsing this chapter (`noteID → text`).
    /// The engine publishes them to `FootnoteStore`.
    private(set) var pipelineFootnotes: [String: String] = [:]
    /// nodeID → owning `<a href>` for this chapter (Phase 3A link interaction).
    private(set) var pipelineLinkAnchors: [Int: LinkAnchorInfo] = [:]

    init(
        html: String,
        cssTexts: [String],
        config: BrowserLayoutConfig,
        imageLoader: @escaping (String) -> UIImage?,
        generation: Int
    ) {
        self.html = html
        self.cssTexts = cssTexts
        self.config = config
        self.imageLoader = imageLoader
        self.generation = generation
    }

    // MARK: - Public API

    /// Builds the chapter pipeline WITHOUT laying out a page, and reports the
    /// authored root background-image source (nil when the chapter has none).
    ///
    /// A CSS background is paint-only: it never affects layout, so its bytes are
    /// not needed to build the box tree. Resolving the source from the COMPUTED
    /// root box — rather than re-scanning the stylesheets with a second parser —
    /// is what makes the fetched key and the painted key the same string by
    /// construction, instead of by two parsers agreeing.
    @discardableResult
    func prepare() throws -> String? {
        try ensureInitialized()
        guard let rootBox = pipeline?.rootBox else { return nil }
        return BrowserLayoutDocument.bodyBackground(rootBox: rootBox).image?.source
    }

    /// Builds the chapter pipeline and walks to the next page boundary.
    /// Returns the completed page, or nil when the chapter is exhausted.
    func layoutNextPage() async throws -> PageFragments? {
        try ensureInitialized()
        guard let page = walker?.layoutNextPage() else {
            isFinished = true
            walker = nil
            return nil
        }
        BrowserLayoutDeviceDiagnostic.summary("\(BrowserLayoutDeviceDiagnostic.prefix) layoutNextPageCompleted spine=\(diagnosticSpine) gen=\(generation) page=\(page.index) fragments=\(page.fragments.count)")
        #if DEBUG
        // Image placement diagnostics (画册 regression): every image fragment's
        // page-local rect + source on each page.
        var imageLog: [String] = []
        func walkImages(_ fragments: [Fragment]) {
            for fragment in fragments {
                switch fragment {
                case .image(let i):
                    imageLog.append("src=\(i.source) rect=\(BrowserLayoutDeviceDiagnostic.rect(i.rect.rawValue, space: "pageLocal"))")
                case .group(let children): walkImages(children)
                default: break
                }
            }
        }
        walkImages(page.fragments)
        if !imageLog.isEmpty {
            BrowserLayoutDeviceDiagnostic.summary("\(BrowserLayoutDeviceDiagnostic.prefix) pageImages spine=\(diagnosticSpine) page=\(page.index) \(imageLog.joined(separator: " | "))")
        }
        #endif
        // Inject the authored body background-image into EVERY page (same
        // path as `BrowserLayoutDocument.renderPagesAndMeasure` — one
        // implementation). The background covers the full canvas.
        let finalPage: PageFragments
        if let withBackground = injectBodyBackground(into: page) {
            finalPage = withBackground
        } else {
            finalPage = page
        }
        if page.index == 0 {
            Self.logFirstPageDiagnostics(
                page: finalPage,
                rootBox: pipeline?.rootBox,
                sourceText: sourceText,
                config: config,
                spine: diagnosticSpine,
                generation: generation
            )
        }
        Self.logK1Fragment(page: finalPage, spine: diagnosticSpine, generation: generation)
        completedPages.append(finalPage)
        return finalPage
    }

    /// DEBUG-only: generic first-visible-line ancestry + page metrics for ANY
    /// chapter (works for plain body pages, not just the k1 cover).
    private static func logFirstPageDiagnostics(
        page: PageFragments,
        rootBox: BlockBox?,
        sourceText: String,
        config: BrowserLayoutConfig,
        spine: Int,
        generation: Int
    ) {
        #if DEBUG
        guard let rootBox else { return }
        let traceID = BrowserLayoutDeviceDiagnostic.traceID(for: spine, generation: generation)
        let firstText = Self.firstTextFragment(in: page)
        let canvasSize = CGSize(
            width: config.renderWidth + config.contentInsets.left + config.contentInsets.right,
            height: config.renderHeight + config.contentInsets.top + config.contentInsets.bottom
        )
        BrowserLayoutDeviceDiagnostic.logFirstVisibleLineAncestry(
            rootBox: rootBox,
            sourceText: sourceText,
            firstFragment: firstText,
            canvasSize: canvasSize,
            contentInsets: config.contentInsets,
            spine: spine,
            generation: generation,
            traceID: traceID
        )
        // SVG / replaced elements in this chapter (for unsupported-svg pages).
        var svgRects: [String] = []
        func walkSVG(_ box: BlockBox) {
            if box.debugTag == "svg" || box.debugTag == "img" {
                svgRects.append("\(box.debugTag) frame=\(BrowserLayoutDeviceDiagnostic.rect(box.frame.rawValue, space: "parentLocal")) content=\(box.contentSize) attachment=\(box.imageAttachment != nil)")
            }
            for child in box.children { walkSVG(child) }
        }
        walkSVG(rootBox)
        if !svgRects.isEmpty {
            BrowserLayoutDeviceDiagnostic.summary("\(BrowserLayoutDeviceDiagnostic.prefix) trace=\(traceID) replacedElements \(svgRects.joined(separator: " | "))")
        }
        #endif
    }

    private static func firstTextFragment(in page: PageFragments) -> TextFragment? {
        var result: TextFragment? = nil
        func walk(_ fragments: [Fragment]) {
            for fragment in fragments {
                switch fragment {
                case .text(let t):
                    if result == nil || t.sourceRange.location < result!.sourceRange.location {
                        result = t
                    }
                case .group(let children): walk(children)
                default: break
                }
            }
        }
        walk(page.fragments)
        return result
    }

    /// DEBUG-only: k1's page-local fragment rect (as the walker placed it).
    private static func logK1Fragment(page: PageFragments, spine: Int, generation: Int) {
        #if DEBUG
        var k1Fill: CGRect? = nil
        func walk(_ fragments: [Fragment]) {
            for fragment in fragments {
                switch fragment {
                case .fill(let f):
                    if f.rect.width > 200, f.rect.width < 320, f.rect.height > 20 { k1Fill = f.rect.rawValue }
                case .group(let children): walk(children)
                default: break
                }
            }
        }
        walk(page.fragments)
        let message: String
        if let rect = k1Fill {
            message = "stage=pageFragment node=k1 page=\(page.index) \(BrowserLayoutDeviceDiagnostic.rect(rect, space: "coordinate=pageLocal"))"
        } else {
            message = "stage=pageFragment node=k1 page=\(page.index) k1Fill=none"
        }
        BrowserLayoutDeviceDiagnostic.log(
            .k1Fragment(spine: spine, generation: generation),
            spine: spine, generation: generation, page: page.index,
            message: message
        )
        #endif
    }

    /// Prepends the root box's background (color + image) as FULL-CANVAS
    /// fragments at the front of EVERY page (Phase 2C: the canvas is the
    /// actual page viewport, never the content bounds).
    private func injectBodyBackground(into page: PageFragments) -> PageFragments? {
        guard let rootBox = pipeline?.rootBox else { return nil }
        let background = BrowserLayoutDocument.bodyBackground(rootBox: rootBox)
        guard background.color != nil || background.image != nil else { return nil }

        let canvasSize = CGSize(
            width: config.renderWidth + config.contentInsets.left + config.contentInsets.right,
            height: config.renderHeight + config.contentInsets.top + config.contentInsets.bottom
        )
        let canvas = PageLocalRect(rawValue: CGRect(origin: .zero, size: canvasSize))
        let backgroundColor = background.color ?? config.backgroundColor

        var fragments: [Fragment] = []
        fragments.append(.fill(FillFragment(
            rect: canvas,
            documentRect: DocumentRect(rawValue: CGRect(origin: .zero, size: canvasSize)),
            color: backgroundColor,
            cornerRadius: 0,
            borderTop: .zero, borderBottom: .zero, borderLeft: .zero, borderRight: .zero,
            nodeID: -1,
            writingMode: config.writingMode
        )))
        if let bg = background.image, let image = imageLoader(bg.source) {
            let rect = BrowserLayoutDocument.coverRect(
                for: image.size,
                container: canvasSize,
                positionX: bg.positionX,
                positionY: bg.positionY
            )
            fragments.append(.image(ImageFragment(
                source: bg.source,
                image: image,
                sourceRange: NSRange(location: 0, length: 0),
                nodeID: -1,
                linkTarget: nil,
                writingMode: config.writingMode,
                rect: PageLocalRect(rawValue: rect),
                documentRect: DocumentRect(rawValue: rect),
                alt: nil,
                isBackgroundPaint: true
            )))
        }
        fragments.append(contentsOf: page.fragments)
        return PageFragments(index: page.index, pageRect: page.pageRect, fragments: fragments)
    }

    /// Lays out pages until the page CONTAINING `sourceOffset` (in the
    /// chapter's collapsed sourceText) is complete. No-op when already past.
    func layout(untilSourceOffset offset: Int) async throws {
        while let page = try await layoutNextPage() {
            guard let walker else { break }
            let range = walker.sourceRange(ofPage: page, sourceText: sourceText)
            if range.length > 0, range.location + range.length > offset {
                return
            }
        }
    }

    /// Lays out every remaining page.
    func finish() async throws {
        while try await layoutNextPage() != nil {}
        isFinished = true
        walker = nil
    }

    func pageCountSoFar() -> Int {
        completedPages.count
    }

    /// Source range of the last completed page (empty when none).
    func lastCompletedSourceRange() -> NSRange {
        guard let page = completedPages.last, let walker else {
            return NSRange(location: 0, length: 0)
        }
        return walker.sourceRange(ofPage: page, sourceText: sourceText)
    }

    // MARK: - Internals

    private func ensureInitialized() throws {
        guard walker == nil, pipeline == nil else { return }
        let document = BrowserLayoutDocument(
            html: html, cssTexts: cssTexts, config: config, imageLoader: imageLoader
        )
        // The page canvas IS the full viewport (render area + content insets).
        let canvasSize = CGSize(
            width: config.renderWidth + config.contentInsets.left + config.contentInsets.right,
            height: config.renderHeight + config.contentInsets.top + config.contentInsets.bottom
        )
        #if DEBUG
        BrowserLayoutDeviceDiagnostic.summary("🔬 BROWSER_DEVICE sessionEnsure start spine=\(diagnosticSpine) htmlLen=\(html.count) cssCount=\(cssTexts.count)")
        #endif
        let result = try document.makeLayout(
            containerSize: canvasSize,
            fragmentHeight: config.renderHeight
        )
        #if DEBUG
        BrowserLayoutDeviceDiagnostic.summary("🔬 BROWSER_DEVICE sessionEnsure makeLayoutDone spine=\(diagnosticSpine) boxes=\(result.boxCount) content=\(result.contentSize)")
        #endif
        sourceText = result.sourceText
        anchorOffsets = result.anchorOffsets
        pipelineNodeCount = result.nodeCount
        pipelineBoxCount = result.boxCount
        pipelineFootnotes = result.footnotes
        pipelineLinkAnchors = result.linkAnchors
        pipeline = result
        walker = PageWalker(
            box: result.rootBox,
            pageSize: canvasSize,
            contentInsets: config.contentInsets
        )
        #if DEBUG
        BrowserLayoutDeviceDiagnostic.summary("🔬 BROWSER_DEVICE sessionEnsure walkerCreated spine=\(diagnosticSpine) pageSize=\(canvasSize) rootLines=\(result.rootBox.lines.count) rootChildren=\(result.rootBox.children.count)")
        #endif
        Self.logK1K2Layout(rootBox: result.rootBox, config: config, spine: diagnosticSpine, generation: generation)
        #if DEBUG
        BrowserLayoutDeviceDiagnostic.summary("🔬 BROWSER_DEVICE sessionEnsure complete spine=\(diagnosticSpine)")
        #endif
    }

    /// DEBUG-only dump of the k1/k2 cover boxes' geometry in DOCUMENT
    /// coordinates (relative to the root box's content origin — before any
    /// page-local or UIKit conversion). Rate-limited per spine+generation.
    private static func logK1K2Layout(
        rootBox: BlockBox,
        config: BrowserLayoutConfig,
        spine: Int,
        generation: Int
    ) {
        #if DEBUG
        func findK1(_ box: BlockBox) -> BlockBox? {
            if box.style.width == .em(15) { return box }
            for child in box.children { if let found = findK1(child) { return found } }
            return nil
        }
        func findK2(_ box: BlockBox) -> BlockBox? {
            if box.style.paddingTop == .em(2.2), box.style.borderTopWidth == 1 { return box }
            for child in box.children { if let found = findK2(child) { return found } }
            return nil
        }
        func firstTextLine(_ box: BlockBox) -> (top: CGFloat, baseline: CGFloat, height: CGFloat)? {
            if let line = box.lines.first(where: { !$0.runs.isEmpty }) {
                return (line.top, line.baseline, line.height)
            }
            for child in box.children { if let found = firstTextLine(child) { return found } }
            return nil
        }
        let key = BrowserLayoutDeviceDiagnostic.DiagnosticKey.k1k2Layout(spine: spine, generation: generation)
        guard let k1 = findK1(rootBox), let k2 = findK2(rootBox) else {
            BrowserLayoutDeviceDiagnostic.log(
                key, spine: spine, generation: generation, page: -1,
                message: "k1k2Layout NOT FOUND (k1=\(findK1(rootBox) != nil) k2=\(findK2(rootBox) != nil))")
            return
        }
        // Document-coordinate boxes (relative to root content origin).
        func marginRect(_ box: BlockBox) -> CGRect {
            let f = box.frame.rawValue
            return CGRect(x: f.minX - box.margins.left,
                          y: f.minY - box.margins.top,
                          width: f.width + box.margins.left + box.margins.right,
                          height: f.height + box.margins.top + box.margins.bottom)
        }
        func paddingRect(_ box: BlockBox) -> CGRect {
            let f = box.frame.rawValue
            return CGRect(x: f.minX + box.borders.left,
                          y: f.minY + box.borders.top,
                          width: f.width - box.borders.horizontal,
                          height: f.height - box.borders.vertical)
        }
        func contentRect(_ box: BlockBox) -> CGRect {
            let f = box.frame.rawValue
            return CGRect(x: f.minX + box.borders.left + box.padding.left,
                          y: f.minY + box.borders.top + box.padding.top,
                          width: box.contentSize.width,
                          height: box.contentSize.height)
        }
        let D = "coordinate=document"
        let k1CSS = "k1 specified margin-top=\(k1.style.marginTop) left=\(k1.style.marginLeft) right=\(k1.style.marginRight) "
            + "width=\(k1.style.width) fontSize=\(k1.style.fontSize)"
        let k1Resolved = "k1 resolved marginTop=\(String(format: "%.2f", k1.margins.top)) "
            + "contentWidth=\(String(format: "%.2f", k1.contentSize.width)) "
            + "rootFontSize=\(config.rootFontSize) bodyContentRect=\(BrowserLayoutDeviceDiagnostic.rect(CGRect(origin: .zero, size: rootBox.contentSize), space: D))"
        let k1Rects = "k1 marginRect=\(BrowserLayoutDeviceDiagnostic.rect(marginRect(k1), space: D)) "
            + "borderRect=\(BrowserLayoutDeviceDiagnostic.rect(k1.frame.rawValue, space: D)) "
            + "paddingRect=\(BrowserLayoutDeviceDiagnostic.rect(paddingRect(k1), space: D)) "
            + "contentRect=\(BrowserLayoutDeviceDiagnostic.rect(contentRect(k1), space: D))"
        let k2Rects = "k2 borderRect=\(BrowserLayoutDeviceDiagnostic.rect(k2.frame.rawValue, space: D)) "
            + "contentRect=\(BrowserLayoutDeviceDiagnostic.rect(contentRect(k2), space: D)) "
            + "specified padding=\(k2.style.paddingTop) border=\(k2.style.borderTopWidth)"
        let lineInfo: String
        if let line = firstTextLine(rootBox) {
            lineInfo = "firstLineBox top=\(String(format: "%.2f", line.top)) baseline=\(String(format: "%.2f", line.baseline)) height=\(String(format: "%.2f", line.height)) coordinate=boxContentLocal"
        } else {
            lineInfo = "firstLineBox=none"
        }
        BrowserLayoutDeviceDiagnostic.log(
            key, spine: spine, generation: generation, page: -1,
            message: "k1k2Layout \(k1CSS) | \(k1Resolved) | \(k1Rects) | \(k2Rects) | \(lineInfo)")
        #endif
    }
}
