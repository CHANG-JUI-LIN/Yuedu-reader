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

    /// Runs the full pipeline and records per-stage timing + peak memory.
    func renderPagesAndMeasure(containerSize: CGSize) async throws -> (pages: [PageFragments], metrics: LayoutMetrics) {
        var metrics = LayoutMetrics()
        let startFootprint = MemoryStats.currentFootprint()
        var peakFootprint = startFootprint

        let (fullCSS, document) = try metrics.time("cssCollect") {
            let css = cssTexts + extractInlineStyles(html)
            let doc = try SwiftSoup.parse(html)
            return (css, doc)
        }
        guard let body = document.body() else {
            lastSourceText = ""
            lastAnchorOffsets = [:]
            lastMetrics = metrics
            return ([], metrics)
        }

        let rules = metrics.time("cssParse") {
            fullCSS.flatMap { CSSParser.parse(css: $0, orderOffset: 0) }
        }
        let builder = ComputedStyleTreeBuilder(rules: rules, config: config)
        let rootNode = metrics.time("styleTree") {
            builder.buildTree(body: body)
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
        peakFootprint = max(peakFootprint, MemoryStats.currentFootprint())

        let contentWidth = max(1, containerSize.width - config.contentInsets.left - config.contentInsets.right)
        let contentHeight = max(1, containerSize.height - config.contentInsets.top - config.contentInsets.bottom)
        metrics.time("layout") {
            _ = BlockLayout.layOut(root: rootBox, containerWidth: contentWidth, rootFontSize: config.rootFontSize)
        }
        peakFootprint = max(peakFootprint, MemoryStats.currentFootprint())

        var pages: [PageFragments] = []
        if !rootBox.lines.isEmpty || !rootBox.children.isEmpty {
            pages = metrics.time("fragment") {
                PageFragmentation.fragment(box: rootBox, pageSize: CGSize(width: contentWidth, height: contentHeight))
            }
        }
        peakFootprint = max(peakFootprint, MemoryStats.currentFootprint())

        lastSourceText = sourceText.text
        lastAnchorOffsets = anchors
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
