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
        let fullCSS = cssTexts + extractInlineStyles(html)
        let document = try SwiftSoup.parse(html)
        guard let body = document.body() else {
            throw BrowserLayoutError.emptyBody
        }
        let rules = fullCSS.flatMap { CSSParser.parse(css: $0, orderOffset: 0) }
        let builder = ComputedStyleTreeBuilder(rules: rules, config: config)
        let rootNode = builder.buildTree(body: body)
        var sourceText = SourceTextBuilder()
        var anchors: [String: Int] = [:]
        let rootBox = BoxTreeBuilder.buildBlock(
            for: rootNode, config: config,
            sourceText: &sourceText, anchors: &anchors,
            imageLoader: imageLoader
        )
        let contentWidth = max(1, containerSize.width - config.contentInsets.left - config.contentInsets.right)
        let contentHeight = max(1, containerSize.height - config.contentInsets.top - config.contentInsets.bottom)
        _ = BlockLayout.layOut(
            root: rootBox,
            containerWidth: contentWidth,
            rootFontSize: config.rootFontSize,
            writingMode: config.writingMode
        )
        return BrowserLayoutPipelineResult(
            rootBox: rootBox,
            sourceText: sourceText.text,
            anchorOffsets: anchors,
            contentSize: CGSize(width: contentWidth, height: contentHeight),
            nodeCount: rootNode.nodeID,
            boxCount: BoxTreeBuilder.countBoxes(in: rootBox)
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
    }

    enum BrowserLayoutError: Error {
        case emptyBody
    }

    /// The root box's authored background-image style, if any.
    static func bodyBackgroundImage(rootBox: BlockBox) -> BackgroundImageStyle? {
        rootBox.style.backgroundImage
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

        let pipeline = try metrics.time("pipeline") {
            try makeLayout(containerSize: containerSize)
        }
        peakFootprint = max(peakFootprint, MemoryStats.currentFootprint())

        var pages: [PageFragments] = []
        if !pipeline.rootBox.lines.isEmpty || !pipeline.rootBox.children.isEmpty {
            pages = metrics.time("fragment") {
                PageFragmentation.fragment(box: pipeline.rootBox, pageSize: pipeline.contentSize)
            }
        }
        // Authored body background-image (paint-only): resolved through the
        // same imageLoader as <img>; injected as a full-viewport image fragment
        // at the front of page 0 (cover/center semantics resolved below). The
        // fragment is per-page (not a whole-chapter bitmap) and never replaces
        // the reader theme — it draws ON TOP of the theme fill.
        if let background = Self.bodyBackgroundImage(rootBox: pipeline.rootBox),
           let image = imageLoader(background.source),
           var firstPage = pages.first {
            // The background covers the FULL page (content + page margins),
            // matching CSS `background: fixed` on body.
            let container = CGSize(
                width: containerSize.width,
                height: containerSize.height
            )
            let rect = Self.coverRect(
                for: image.size,
                container: container,
                positionX: background.positionX,
                positionY: background.positionY
            )
            var fragments = firstPage.fragments
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
            firstPage = PageFragments(index: firstPage.index, pageRect: firstPage.pageRect, fragments: fragments)
            pages[0] = firstPage
        }
        peakFootprint = max(peakFootprint, MemoryStats.currentFootprint())

        lastSourceText = pipeline.sourceText
        lastAnchorOffsets = pipeline.anchorOffsets
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
        case pageFragments
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
