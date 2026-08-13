import Foundation
import SwiftSoup
import UIKit

/// Per-stage pipeline timings + peak memory footprint delta (phys_footprint).
struct LayoutMetrics {
    var stages: [String: TimeInterval] = [:]
    var peakFootprintDelta: Int64 = 0

    mutating func time<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        let start = CACurrentMediaTime()
        let value = try body()
        stages[name] = (stages[name] ?? 0) + (CACurrentMediaTime() - start)
        return value
    }

    var total: TimeInterval {
        stages.values.reduce(0, +)
    }
}

/// Public entry point. `html` is the chapter's XHTML (inline `<style>` blocks are
/// extracted automatically); `cssTexts` is external stylesheet text the caller
/// already loaded (EPUB resource loading stays on the caller side, reusing
/// EPUBStyleResolver later — one data path, no parallel cache).
///
/// Phase 1.5: builds `sourceText` (collapsed, document-ordered) alongside the
/// box tree; every fragment carries a `sourceRange` into it. `imageLoader`
/// resolves `<img>` sources (tests use local files; no network).
final class BrowserLayoutDocument {

    private let html: String
    private let cssTexts: [String]
    private let config: BrowserLayoutConfig
    private let imageLoader: (String) -> UIImage?

    /// The collapsed source text of the last `renderPages` run.
    private(set) var lastSourceText = ""
    /// Element id → char offset of its first text in `lastSourceText`.
    private(set) var lastAnchorOffsets: [String: Int] = [:]
    /// nodeID → owning `<a href>` of the last `renderPages` run (Phase 3A).
    private(set) var lastLinkAnchors: [Int: LinkAnchorInfo] = [:]
    /// Metrics of the last `renderPages` run.
    private(set) var lastMetrics = LayoutMetrics()

    init(
        html: String,
        cssTexts: [String],
        config: BrowserLayoutConfig,
        imageLoader: ((String) -> UIImage?)? = nil
    ) {
        self.html = html
        self.cssTexts = cssTexts
        self.config = config
        self.imageLoader = imageLoader ?? { _ in nil }
    }

    func renderPages(containerSize: CGSize) async throws -> [PageFragments] {
        let (pages, _) = try await renderPagesAndMeasure(containerSize: containerSize)
        return pages
    }

    /// The shared pipeline: CSS → style tree → box tree → block layout.
    /// Both batch pagination and `BrowserLayoutSession` consume this — one
    /// implementation, no parallel paths.
    func makeLayout(containerSize: CGSize) throws -> BrowserLayoutPipelineResult {
        var discarded = LayoutMetrics()
        return try makeLayout(containerSize: containerSize, metrics: &discarded)
    }

    /// Per-stage timings go into `metrics`. The stage names are a contract:
    /// `BrowserLayoutPerfTests` asserts each one is present, so that "the new
    /// engine is slower" can be answered with a breakdown instead of a guess.
    /// Do not collapse these back into one span — that is what made the
    /// breakdown disappear once already.
    func makeLayout(
        containerSize: CGSize,
        metrics: inout LayoutMetrics
    ) throws -> BrowserLayoutPipelineResult {
        let fullCSS = metrics.time("cssCollect") { cssTexts + extractInlineStyles(html) }
        let document = try metrics.time("htmlParse") { try SwiftSoup.parse(html) }
        guard let body = document.body() else {
            throw BrowserLayoutError.emptyBody
        }
        let rules = metrics.time("cssParse") {
            fullCSS.flatMap { CSSParser.parse(css: $0, orderOffset: 0) }
        }
        let builder = ComputedStyleTreeBuilder(rules: rules, config: config)
        var linkAnchors: [Int: LinkAnchorInfo] = [:]
        let rootNode = metrics.time("styleTree") {
            let tree = builder.buildTree(body: body)
            // Link identity/semantics belong to the style tree stage: they are
            // DOM facts, resolved once, and every later stage only carries them.
            linkAnchors = ComputedStyleTreeBuilder.collectLinkAnchors(tree)
            return tree
        }
        var sourceText = SourceTextBuilder()
        var anchors: [String: Int] = [:]
        let rootBox = metrics.time("boxTree") {
            BoxTreeBuilder.buildBlock(
                for: rootNode, config: config,
                sourceText: &sourceText, anchors: &anchors,
                imageLoader: imageLoader
            )
        }
        let contentWidth = max(1, containerSize.width - config.contentInsets.left - config.contentInsets.right)
        let contentHeight = max(1, containerSize.height - config.contentInsets.top - config.contentInsets.bottom)
        metrics.time("layout") {
            _ = BlockLayout.layOut(
                root: rootBox,
                containerWidth: contentWidth,
                rootFontSize: config.rootFontSize,
                writingMode: config.writingMode
            )
        }
        return BrowserLayoutPipelineResult(
            rootBox: rootBox,
            sourceText: sourceText.text,
            anchorOffsets: anchors,
            contentSize: CGSize(width: contentWidth, height: contentHeight),
            nodeCount: rootNode.nodeID,
            boxCount: BoxTreeBuilder.countBoxes(in: rootBox),
            footnotes: Self.collectFootnotes(in: document),
            linkAnchors: linkAnchors
        )
    }

    struct BrowserLayoutPipelineResult {
        let rootBox: BlockBox
        let sourceText: String
        let anchorOffsets: [String: Int]
        let contentSize: CGSize
        /// Style-tree node count (lifecycle accounting).
        let nodeCount: Int
        /// Block-box count (lifecycle accounting).
        let boxCount: Int
        /// 多看 popup footnotes found in the chapter (`noteID → text`).
        /// Collected here because this is the one place the chapter DOM is
        /// parsed; the ENGINE owns publishing them to `FootnoteStore`, so the
        /// layout layer stays free of reader state.
        let footnotes: [String: String]
        /// nodeID → owning `<a href>` (identity + EPUB semantics), for every
        /// node inside a link. Consumed by `LinkInteractionRegionSet`.
        let linkAnchors: [Int: LinkAnchorInfo]
    }

    enum BrowserLayoutError: Error {
        case emptyBody
    }

    /// 多看 popup-footnote payload: `<ol class="duokan-footnote-content">
    /// <li class="duokan-footnote-item" id="m1">…</li></ol>` at the chapter tail.
    /// Same shape `FootnoteStore` documents for the legacy path — an `li` with
    /// an id and a class containing "footnote".
    ///
    /// The block itself is NOT hidden: the publisher's stylesheet never sets
    /// `display: none` on it (a browser shows it, and the legacy engine renders
    /// it inline too). Only the marker tap changes — it opens the note in place
    /// instead of paging to the chapter tail.
    static func collectFootnotes(in document: Document) -> [String: String] {
        var map: [String: String] = [:]
        for item in (try? document.select("li[id]").array()) ?? [] {
            let classes = ((try? item.classNames().map { $0 }) ?? [])
            guard classes.contains(where: { $0.contains("footnote") }) else { continue }
            let id = (try? item.attr("id")) ?? ""
            guard !id.isEmpty else { continue }
            let text = ((try? item.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            map[id] = text
        }
        // EPUB 3 structural semantics (Phase 3A): a note body is whatever the
        // author tagged `epub:type="footnote|endnote|note"`, on any element —
        // `<aside epub:type="footnote" id="n1">` is the spec's own example and
        // carries no 多看 class at all. Read from the attribute, never from a
        // class name, so a `<a epub:type="noteref">` marker has a body to show.
        for item in (try? document.select("[id]").array()) ?? [] {
            let id = (try? item.attr("id")) ?? ""
            guard !id.isEmpty, map[id] == nil else { continue }
            let tokens = ((try? item.attr("epub:type")) ?? "")
                .lowercased()
                .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
                .map(String.init)
            guard tokens.contains("footnote") || tokens.contains("endnote")
                    || tokens.contains("note") || tokens.contains("rearnote")
            else { continue }
            let text = ((try? item.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            map[id] = text
        }
        return map
    }

    /// The root box's authored background-image style, if any.
    /// The root box's authored background (color + image style), if any.
    /// html/body background propagates to the page CANVAS, not the content
    /// bounds (Phase 2C).
    struct RootBackground {
        var color: UIColor?
        var image: BackgroundImageStyle?
    }

    static func bodyBackground(rootBox: BlockBox) -> RootBackground {
        // The root box IS html/body: its own background-color and
        // background-image. The reader theme color (config) is NOT authored
        // and must not be treated as the page background source.
        RootBackground(
            color: rootBox.style.backgroundColor,
            image: rootBox.style.backgroundImage
        )
    }

    /// Resolves the physical rect of a cover/contain background image inside a
    /// container, honoring `background-position` (center → symmetric crop).
    /// `imageSize` is the intrinsic bitmap size; `container` the content rect.
    static func coverRect(
        for imageSize: CGSize,
        container: CGSize,
        positionX: BackgroundImageStyle.BackgroundPosition,
        positionY: BackgroundImageStyle.BackgroundPosition,
        mode: BackgroundImageStyle.BackgroundSize = .cover
    ) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, container.width > 0, container.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        var drawW: CGFloat
        var drawH: CGFloat
        switch mode {
        case .cover:
            // Scale so the image fully COVERS the container; the larger axis
            // overflows and is cropped (symmetrically per position).
            let scale = max(container.width / imageSize.width, container.height / imageSize.height)
            drawW = imageSize.width * scale
            drawH = imageSize.height * scale
        case .contain:
            let scale = min(container.width / imageSize.width, container.height / imageSize.height)
            drawW = imageSize.width * scale
            drawH = imageSize.height * scale
        case .auto:
            drawW = imageSize.width
            drawH = imageSize.height
        }

        let slackX = max(0, container.width - drawW)
        let slackY = max(0, container.height - drawH)
        let offsetX = positionFraction(positionX) * slackX
        let offsetY = positionFraction(positionY) * slackY
        return CGRect(x: offsetX, y: offsetY, width: drawW, height: drawH)
    }

    private static func positionFraction(_ position: BackgroundImageStyle.BackgroundPosition) -> CGFloat {
        switch position {
        case .percent(let f): return min(max(f, 0), 1)
        case .keyword(let f): return min(max(f, 0), 1)
        case .length(let v): return v
        }
    }

    /// Runs the full pipeline and records per-stage timing + peak memory.
    func renderPagesAndMeasure(containerSize: CGSize) async throws -> (pages: [PageFragments], metrics: LayoutMetrics) {
        var metrics = LayoutMetrics()
        let startFootprint = MemoryStats.currentFootprint()
        var peakFootprint = startFootprint

        // Sub-stages are recorded individually; wrapping them in an outer span
        // as well would double-count them in `total`.
        let pipeline = try makeLayout(containerSize: containerSize, metrics: &metrics)
        peakFootprint = max(peakFootprint, MemoryStats.currentFootprint())

        var pages: [PageFragments] = []
        if !pipeline.rootBox.lines.isEmpty || !pipeline.rootBox.children.isEmpty {
            pages = metrics.time("fragment") {
                PageFragmentation.fragment(
                    box: pipeline.rootBox,
                    pageSize: containerSize,
                    contentInsets: config.contentInsets
                )
            }
        }
        // Authored html/body background (paint-only): resolved through the
        // same imageLoader as <img>; injected as a FULL-CANVAS fragment at the
        // FRONT of EVERY page (cover/center semantics resolved below). The
        // canvas equals the actual page viewport — never the content bounds.
        // The background-color fills the canvas; the image draws over it.
        let background = Self.bodyBackground(rootBox: pipeline.rootBox)
        if background.color != nil || background.image != nil {
            let canvas = PageLocalRect(rawValue: CGRect(origin: .zero, size: containerSize))
            let backgroundColor = background.color ?? config.backgroundColor
            for (index, page) in pages.enumerated() {
                var fragments: [Fragment] = []
                fragments.append(.fill(FillFragment(
                    rect: canvas,
                    documentRect: DocumentRect(rawValue: CGRect(origin: .zero, size: containerSize)),
                    color: backgroundColor,
                    cornerRadius: 0,
                    borderTop: .zero, borderBottom: .zero, borderLeft: .zero, borderRight: .zero,
                    nodeID: -1,
                    writingMode: config.writingMode
                )))
                if let bg = background.image, let image = imageLoader(bg.source) {
                    let rect = Self.coverRect(
                        for: image.size,
                        container: containerSize,
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
                pages[index] = PageFragments(index: page.index, pageRect: page.pageRect, fragments: fragments)
            }
        }
        peakFootprint = max(peakFootprint, MemoryStats.currentFootprint())

        lastSourceText = pipeline.sourceText
        lastAnchorOffsets = pipeline.anchorOffsets
        lastLinkAnchors = pipeline.linkAnchors
        metrics.peakFootprintDelta = peakFootprint - startFootprint
        lastMetrics = metrics
        return (pages, metrics)
    }

    // MARK: - Output helpers

    /// Human-readable fragment tree dump for one chapter layout.
    func dumpFragments(_ pages: [PageFragments]) -> String {
        var lines: [String] = ["sourceText(\(lastSourceText.count)): \(lastSourceText.debugDescription)"]
        for page in pages {
            lines.append("page[\(page.index)] rect=\(page.pageRect)")
            dumpFragments(page.fragments, indent: "  ", into: &lines)
        }
        return lines.joined(separator: "\n")
    }

    private func dumpFragments(_ fragments: [Fragment], indent: String, into lines: inout [String]) {
        for fragment in fragments {
            switch fragment {
            case .text(let t):
                let text = slice(lastSourceText, t.sourceRange)
                lines.append("\(indent)text node=\(t.nodeID) range=\(t.sourceRange) link=\(t.linkTarget ?? "-") \(t.rect) \"\(text)\"")
            case .fill(let f):
                lines.append("\(indent)fill node=\(f.nodeID) \(f.rect) \(f.color)")
            case .image(let i):
                lines.append("\(indent)image node=\(i.nodeID) \(i.rect) src=\(i.source)")
            case .group(let children):
                lines.append("\(indent)group")
                dumpFragments(children, indent: indent + "  ", into: &lines)
            }
        }
    }

    private func slice(_ sourceText: String, _ range: NSRange) -> String {
        guard !sourceText.isEmpty, range.length > 0 else { return "" }
        let ns = sourceText as NSString
        guard range.location >= 0, range.location + range.length <= ns.length else { return "" }
        return ns.substring(with: range)
    }

    private func extractInlineStyles(_ html: String) -> [String] {
        guard let doc = try? SwiftSoup.parse(html),
              let head = doc.head() else { return [] }
        let styleTags = (try? head.select("style").array()) ?? []
        return styleTags.compactMap { try? $0.html() }.filter { !$0.isEmpty }
    }
}

/// phys_footprint sampling via task_info — the metric for "peak memory".
enum MemoryStats {
    static func currentFootprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int64(info.phys_footprint)
    }
}

/// Per-artifact-type memory accounting for Phase 2B lifecycle verification.
/// `record` adds retained bytes, `release` subtracts them — the live snapshot
/// shows what is CURRENTLY retained per type (not just peaks). Estimates are
/// documented approximations; the goal is proving no monotonic growth, not
/// byte-exact accounting.
enum MemoryTracker {
    enum ArtifactType: String, CaseIterable {
        case domStyleTree      // DOM + ComputedStyleNode
        case layoutBoxTree
        case fragmentTree
        case ctLineRun         // CoreText line/run objects during shaping
        case displayList
        case decodedImage
        case snapshotBitmap
    }

    private static let lock = NSLock()
    private static var retained: [ArtifactType: Int64] = [:]
    private static var created: [ArtifactType: Int64] = [:]
    private static var released: [ArtifactType: Int64] = [:]

    static func record(_ type: ArtifactType, bytes: Int64) {
        lock.lock()
        retained[type, default: 0] += bytes
        created[type, default: 0] += 1
        lock.unlock()
    }

    static func release(_ type: ArtifactType, bytes: Int64) {
        lock.lock()
        retained[type, default: 0] = max(0, retained[type, default: 0] - bytes)
        released[type, default: 0] += 1
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        retained.removeAll()
        created.removeAll()
        released.removeAll()
        lock.unlock()
    }

    /// Current retained bytes per type.
    static var snapshot: [ArtifactType: Int64] {
        lock.lock()
        defer { lock.unlock() }
        return retained
    }

    static func summary() -> String {
        lock.lock()
        defer { lock.unlock() }
        return ArtifactType.allCases
            .map { "\($0.rawValue): \(retained[$0] ?? 0)B (created \(created[$0] ?? 0), released \(released[$0] ?? 0))" }
            .joined(separator: ", ")
    }
}
