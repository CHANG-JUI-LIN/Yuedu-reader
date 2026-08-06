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
            completedPages.append(withBackground)
            return withBackground
        }
        completedPages.append(page)
        return page
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
    }
}
