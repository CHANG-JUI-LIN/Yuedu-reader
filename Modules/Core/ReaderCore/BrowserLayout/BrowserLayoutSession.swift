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

    /// Builds the chapter pipeline and walks to the next page boundary.
    /// Returns the completed page, or nil when the chapter is exhausted.
    func layoutNextPage() async throws -> PageFragments? {
        try ensureInitialized()
        guard let page = walker?.layoutNextPage() else {
            isFinished = true
            walker = nil
            return nil
        }
        // Inject the authored body background-image into page 0 (same path as
        // `BrowserLayoutDocument.renderPagesAndMeasure` — one implementation).
        if page.index == 0, let withBackground = injectBodyBackground(into: page) {
            Self.logK1Fragment(page: withBackground, spine: diagnosticSpine, generation: generation)
            completedPages.append(withBackground)
            return withBackground
        }
        Self.logK1Fragment(page: page, spine: diagnosticSpine, generation: generation)
        completedPages.append(page)
        return page
    }

    /// DEBUG-only: k1's page-local fragment rect (as the walker placed it).
    private static func logK1Fragment(page: PageFragments, spine: Int, generation: Int) {
        #if DEBUG
        var k1Fill: CGRect? = nil
        func walk(_ fragments: [Fragment]) {
            for fragment in fragments {
                switch fragment {
                case .fill(let f):
                    if f.rect.width > 200, f.rect.width < 320, f.rect.height > 20 { k1Fill = f.rect }
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

    /// Prepends the root box's background-image fragment to page 0 when the
    /// chapter declares one (cover/center resolved against the content rect).
    private func injectBodyBackground(into page: PageFragments) -> PageFragments? {
        guard let rootBox = pipeline?.rootBox,
              let background = BrowserLayoutDocument.bodyBackgroundImage(rootBox: rootBox),
              let image = imageLoader(background.source) else { return nil }
        let rect = BrowserLayoutDocument.coverRect(
            for: image.size,
            container: CGSize(width: config.renderWidth + config.contentInsets.left + config.contentInsets.right,
                              height: config.renderHeight + config.contentInsets.top + config.contentInsets.bottom),
            positionX: background.positionX,
            positionY: background.positionY
        )
        var fragments = page.fragments
        fragments.insert(.image(ImageFragment(
            source: background.source,
            image: image,
            sourceRange: NSRange(location: 0, length: 0),
            nodeID: -1,
            linkTarget: nil,
            writingMode: config.writingMode,
            rect: rect,
            alt: nil
        )), at: 0)
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
        // containerSize mirrors the config's render area (the caller keeps
        // contentInsets in config).
        let result = try document.makeLayout(containerSize: CGSize(
            width: config.renderWidth + config.contentInsets.left + config.contentInsets.right,
            height: config.renderHeight + config.contentInsets.top + config.contentInsets.bottom
        ))
        sourceText = result.sourceText
        anchorOffsets = result.anchorOffsets
        pipelineNodeCount = result.nodeCount
        pipelineBoxCount = result.boxCount
        pipeline = result
        walker = PageWalker(box: result.rootBox, pageSize: result.contentSize)
        Self.logK1K2Layout(rootBox: result.rootBox, config: config, spine: diagnosticSpine, generation: generation)
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
            CGRect(x: box.frame.minX - box.margins.left,
                   y: box.frame.minY - box.margins.top,
                   width: box.frame.width + box.margins.left + box.margins.right,
                   height: box.frame.height + box.margins.top + box.margins.bottom)
        }
        func paddingRect(_ box: BlockBox) -> CGRect {
            CGRect(x: box.frame.minX + box.borders.left,
                   y: box.frame.minY + box.borders.top,
                   width: box.frame.width - box.borders.horizontal,
                   height: box.frame.height - box.borders.vertical)
        }
        func contentRect(_ box: BlockBox) -> CGRect {
            CGRect(x: box.frame.minX + box.borders.left + box.padding.left,
                   y: box.frame.minY + box.borders.top + box.padding.top,
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
            + "borderRect=\(BrowserLayoutDeviceDiagnostic.rect(k1.frame, space: D)) "
            + "paddingRect=\(BrowserLayoutDeviceDiagnostic.rect(paddingRect(k1), space: D)) "
            + "contentRect=\(BrowserLayoutDeviceDiagnostic.rect(contentRect(k1), space: D))"
        let k2Rects = "k2 borderRect=\(BrowserLayoutDeviceDiagnostic.rect(k2.frame, space: D)) "
            + "contentRect=\(BrowserLayoutDeviceDiagnostic.rect(contentRect(k2), space: D)) "
            + "specified padding=\(k2.style.paddingTop) border=\(k2.style.borderTopWidth)"
        let lineInfo: String
        if let line = firstTextLine(rootBox) {
            lineInfo = "firstLineBox top=\(String(format: "%.2f", line.top)) baseline=\(String(format: "%.2f", line.baseline)) height=\(String(format: "%.2f", line.height)) \(D)"
        } else {
            lineInfo = "firstLineBox=none"
        }
        BrowserLayoutDeviceDiagnostic.log(
            key, spine: spine, generation: generation, page: -1,
            message: "k1k2Layout \(k1CSS) | \(k1Resolved) | \(k1Rects) | \(k2Rects) | \(lineInfo)")
        #endif
    }
}
