import CoreGraphics
import CoreText
import CryptoKit
import Foundation
import UIKit
@testable import yuedu_app

/// Exact BrowserLayout geometry serialization used by the Phase 4E0 parity
/// gate. Floating-point values are recorded by IEEE-754 bit pattern: this is
/// deliberately stricter than a screenshot or rounded-coordinate comparison.
enum BrowserLayoutGeometryFingerprint {
    struct Snapshot: Equatable {
        let digest: String
        let canonicalRows: [String]
    }

    static func scalar(_ value: CGFloat) -> String {
        String(Double(value).bitPattern, radix: 16)
    }

    static func range(_ value: NSRange) -> String {
        "\(value.location):\(value.length)"
    }

    static func rect(_ value: CGRect) -> String {
        [value.minX, value.minY, value.width, value.height]
            .map(scalar)
            .joined(separator: ",")
    }

    static func size(_ value: CGSize) -> String {
        [value.width, value.height].map(scalar).joined(separator: ",")
    }

    static func edgeSizes(_ value: EdgeSizes) -> String {
        [value.top, value.right, value.bottom, value.left]
            .map(scalar)
            .joined(separator: ",")
    }

    static func snapshot(
        pipeline: BrowserLayoutDocument.BrowserLayoutPipelineResult,
        pages: [PageFragments],
        selectionRange: NSRange? = nil,
        spineIndex: Int = 0
    ) -> Snapshot {
        var rows = ["source.length|\((pipeline.sourceText as NSString).length)"]
        appendBox(pipeline.rootBox, path: "0", rows: &rows)
        appendPages(pages, rows: &rows)

        let pageRanges = BrowserChapterLayout.buildPageRanges(
            pages,
            sourceText: pipeline.sourceText
        )
        for (index, pageRange) in pageRanges.enumerated() {
            rows.append("pageRange|\(index)|\(range(pageRange))")
        }

        for (pageIndex, page) in pages.enumerated() {
            let displayList = DisplayListBuilder.build(
                for: page,
                sourceText: pipeline.sourceText
            )
            appendDisplayList(displayList, pageIndex: pageIndex, rows: &rows)
            let links = LinkInteractionRegionSet.build(
                from: displayList,
                spineIndex: spineIndex,
                anchors: pipeline.linkAnchors
            )
            appendLinks(links, pageIndex: pageIndex, rows: &rows)
        }

        if let selectionRange {
            appendSelection(
                pages: pages,
                range: selectionRange,
                rows: &rows
            )
        }

        return makeSnapshot(rows)
    }

    static func boxLineSnapshot(_ root: BlockBox) -> Snapshot {
        var rows: [String] = []
        appendBox(root, path: "0", rows: &rows)
        return makeSnapshot(rows)
    }

    static func fragmentSnapshot(_ pages: [PageFragments]) -> Snapshot {
        var rows: [String] = []
        appendPages(pages, rows: &rows)
        return makeSnapshot(rows)
    }

    static func pageRangeSnapshot(
        _ pages: [PageFragments],
        sourceText: String
    ) -> Snapshot {
        let rows = BrowserChapterLayout.buildPageRanges(
            pages,
            sourceText: sourceText
        ).enumerated().map { index, value in
            "pageRange|\(index)|\(range(value))"
        }
        return makeSnapshot(rows)
    }

    private static func makeSnapshot(_ rows: [String]) -> Snapshot {
        let data = Data(rows.joined(separator: "\n").utf8)
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return Snapshot(digest: digest, canonicalRows: rows)
    }

    private static func appendBox(
        _ box: BlockBox,
        path: String,
        rows: inout [String]
    ) {
        rows.append([
            "box", path, box.debugTag, String(box.debugNodeID),
            String(describing: box.boxType), rect(box.frame.rawValue),
            size(box.contentSize), edgeSizes(box.margins), edgeSizes(box.padding),
            edgeSizes(box.borders), scalar(box.logicalInlineOrigin),
            scalar(box.logicalBlockOrigin), String(box.inlineRuns.count),
            String(box.lines.count), String(box.children.count),
        ].joined(separator: "|"))

        for (lineIndex, line) in box.lines.enumerated() {
            let ctRange = line.ctLine.map {
                let value = CTLineGetStringRange($0)
                return "\(value.location):\(value.length)"
            } ?? "nil"
            rows.append([
                "line", path, String(lineIndex), scalar(line.top),
                scalar(line.baseline), scalar(line.height), scalar(line.ascent),
                scalar(line.descent), scalar(line.contentX), ctRange,
                String(line.runs.count),
            ].joined(separator: "|"))

            for (runIndex, run) in line.runs.enumerated() {
                rows.append([
                    "run", path, String(lineIndex), String(runIndex),
                    range(run.sourceRange), run.shapedRange.map(range) ?? "nil",
                    scalar(run.x), scalar(run.width), String(run.nodeID),
                    run.linkTarget ?? "nil", run.font.fontName,
                    scalar(run.font.pointSize), run.atomic == nil ? "text" : "atomic",
                    run.ruby == nil ? "plain" : "ruby",
                ].joined(separator: "|"))
                if let atomic = run.atomic {
                    rows.append([
                        "atomic", path, String(lineIndex), String(runIndex),
                        atomic.source, size(atomic.usedSize), String(atomic.nodeID),
                        atomic.linkTarget ?? "nil",
                    ].joined(separator: "|"))
                }
                if let ruby = run.ruby {
                    appendRuby(
                        ruby,
                        path: "\(path).l\(lineIndex).r\(runIndex)",
                        rows: &rows
                    )
                }
            }
        }

        if let image = box.imageAttachment {
            rows.append([
                "blockImage", path, image.source, size(image.usedSize),
                String(image.nodeID), image.linkTarget ?? "nil",
            ].joined(separator: "|"))
        }
        for (index, child) in box.children.enumerated() {
            appendBox(child, path: "\(path).\(index)", rows: &rows)
        }
    }

    private static func appendRuby(
        _ ruby: RubyBox,
        path: String,
        rows: inout [String]
    ) {
        rows.append([
            "ruby", path, range(ruby.unit.sourceRange), String(ruby.unit.nodeID),
            ruby.unit.linkTarget ?? "nil", scalar(ruby.advance), scalar(ruby.ascent),
            scalar(ruby.descent), scalar(ruby.baseOffsetX),
            scalar(ruby.annotationOffsetX), scalar(ruby.annotationBaselineOffset),
        ].joined(separator: "|"))
        appendRubyLine(ruby.base, kind: "base", path: path, rows: &rows)
        appendRubyLine(ruby.annotation, kind: "annotation", path: path, rows: &rows)
    }

    private static func appendRubyLine(
        _ line: RubyLine,
        kind: String,
        path: String,
        rows: inout [String]
    ) {
        let ctRange = CTLineGetStringRange(line.line)
        rows.append([
            "rubyLine", path, kind, scalar(line.width), scalar(line.ascent),
            scalar(line.descent), "\(ctRange.location):\(ctRange.length)",
            String(line.pieces.count),
        ].joined(separator: "|"))
        for (index, piece) in line.pieces.enumerated() {
            rows.append([
                "rubyPiece", path, kind, String(index), piece.text,
                range(piece.sourceRange), range(piece.shapedRange),
                scalar(piece.x), scalar(piece.width), String(piece.nodeID),
                piece.linkTarget ?? "nil", piece.font.fontName,
                scalar(piece.font.pointSize),
            ].joined(separator: "|"))
        }
    }

    private static func appendPages(
        _ pages: [PageFragments],
        rows: inout [String]
    ) {
        for (pageIndex, page) in pages.enumerated() {
            rows.append([
                "page", String(pageIndex), String(page.index),
                rect(page.pageRect.rawValue), String(page.fragments.count),
            ].joined(separator: "|"))
            appendFragments(
                page.fragments,
                path: "p\(pageIndex)",
                rows: &rows
            )
        }
    }

    private static func appendFragments(
        _ fragments: [Fragment],
        path: String,
        rows: inout [String]
    ) {
        for (index, fragment) in fragments.enumerated() {
            let childPath = "\(path).\(index)"
            switch fragment {
            case .text(let text):
                let mapping: String
                switch text.sourceMapping {
                case .linear(let shapedRange): mapping = "linear:\(range(shapedRange))"
                case .wholeRange: mapping = "whole"
                }
                let ctRange = text.ctLine.map {
                    let value = CTLineGetStringRange($0)
                    return "\(value.location):\(value.length)"
                } ?? "nil"
                rows.append([
                    "fragment.text", childPath, range(text.sourceRange),
                    String(text.nodeID), text.linkTarget ?? "nil",
                    String(describing: text.writingMode), rect(text.rect.rawValue),
                    rect(text.documentRect.rawValue), scalar(text.baselineY),
                    text.font.fontName, scalar(text.font.pointSize), mapping,
                    text.renderedTextOverride ?? "nil", ctRange,
                ].joined(separator: "|"))
            case .fill(let fill):
                rows.append([
                    "fragment.fill", childPath, String(fill.nodeID),
                    String(describing: fill.writingMode), rect(fill.rect.rawValue),
                    rect(fill.documentRect.rawValue), scalar(fill.cornerRadius),
                    border(fill.borderTop), border(fill.borderRight),
                    border(fill.borderBottom), border(fill.borderLeft),
                ].joined(separator: "|"))
            case .image(let image):
                rows.append([
                    "fragment.image", childPath, image.source,
                    range(image.sourceRange), String(image.nodeID),
                    image.linkTarget ?? "nil", String(describing: image.writingMode),
                    rect(image.rect.rawValue), rect(image.documentRect.rawValue),
                    image.alt ?? "nil", String(image.isBackgroundPaint),
                ].joined(separator: "|"))
            case .group(let children):
                rows.append("fragment.group.start|\(childPath)|\(children.count)")
                appendFragments(children, path: childPath, rows: &rows)
                rows.append("fragment.group.end|\(childPath)")
            }
        }
    }

    private static func appendDisplayList(
        _ list: DisplayList,
        pageIndex: Int,
        rows: inout [String]
    ) {
        for (index, item) in list.items.enumerated() {
            switch item {
            case .text(let text):
                let mapping: String
                switch text.sourceMapping {
                case .linear(let shapedRange): mapping = "linear:\(range(shapedRange))"
                case .wholeRange: mapping = "whole"
                }
                rows.append([
                    "display.text", String(pageIndex), String(index),
                    range(text.sourceRange), String(text.nodeID),
                    text.linkTarget ?? "nil", rect(text.rect.rawValue),
                    scalar(text.baselineY), mapping,
                    text.renderedTextOverride ?? "nil",
                ].joined(separator: "|"))
            case .fill(let fill):
                rows.append([
                    "display.fill", String(pageIndex), String(index),
                    String(fill.nodeID), rect(fill.rect.rawValue),
                    scalar(fill.cornerRadius), border(fill.borderTop),
                    border(fill.borderRight), border(fill.borderBottom),
                    border(fill.borderLeft),
                ].joined(separator: "|"))
            case .image(let image):
                rows.append([
                    "display.image", String(pageIndex), String(index), image.source,
                    range(image.sourceRange), String(image.nodeID),
                    image.linkTarget ?? "nil", rect(image.rect.rawValue),
                    image.alt ?? "nil", String(image.isBackgroundPaint),
                ].joined(separator: "|"))
            }
        }
    }

    private static func appendLinks(
        _ set: LinkInteractionRegionSet,
        pageIndex: Int,
        rows: inout [String]
    ) {
        for (index, link) in set.regions.enumerated() {
            rows.append([
                "link", String(pageIndex), String(index), rect(link.pageLocalRect),
                link.href, String(link.linkID), String(link.nodeID),
                range(link.sourceRange), String(link.spineIndex),
                String(describing: link.semantic), String(describing: link.kind),
            ].joined(separator: "|"))
        }
    }

    private static func appendSelection(
        pages: [PageFragments],
        range selection: NSRange,
        rows: inout [String]
    ) {
        let selectionEnd = selection.location + selection.length
        for (pageIndex, page) in pages.enumerated() {
            var rects: [CGRect] = []
            collectSelectionRects(
                page.fragments,
                selection: selection,
                selectionEnd: selectionEnd,
                rects: &rects
            )
            for (index, value) in rects.enumerated() {
                rows.append("selection|\(pageIndex)|\(index)|\(rect(value))")
            }
        }
    }

    /// Mirrors BrowserLayoutPageEngine's source-range → CTLine geometry. The
    /// shipping selection contract is separately covered by
    /// BrowserLayoutSelectionContractTests; here the result is frozen together
    /// with the line artifact so the refactor cannot move selection silently.
    private static func collectSelectionRects(
        _ fragments: [Fragment],
        selection: NSRange,
        selectionEnd: Int,
        rects: inout [CGRect]
    ) {
        for fragment in fragments {
            switch fragment {
            case .text(let text):
                guard text.sourceRange.length > 0 else { continue }
                let start = max(text.sourceRange.location, selection.location)
                let end = min(text.sourceRange.location + text.sourceRange.length, selectionEnd)
                guard end > start else { continue }
                if case .wholeRange = text.sourceMapping {
                    rects.append(text.rect.rawValue)
                } else if let line = text.ctLine,
                          let precise = preciseSelectionRect(
                            fragment: text,
                            line: line,
                            selection: NSRange(location: start, length: end - start)
                          ) {
                    rects.append(precise)
                } else {
                    let fraction = CGFloat(end - start) / CGFloat(text.sourceRange.length)
                    let offset = CGFloat(start - text.sourceRange.location)
                        / CGFloat(text.sourceRange.length) * text.rect.width
                    rects.append(CGRect(
                        x: text.rect.minX + offset,
                        y: text.rect.minY,
                        width: fraction * text.rect.width,
                        height: text.rect.height
                    ))
                }
            case .group(let children):
                collectSelectionRects(
                    children,
                    selection: selection,
                    selectionEnd: selectionEnd,
                    rects: &rects
                )
            default:
                continue
            }
        }
    }

    private static func preciseSelectionRect(
        fragment: TextFragment,
        line: CTLine,
        selection: NSRange
    ) -> CGRect? {
        guard case .linear(let shapedRange) = fragment.sourceMapping else { return nil }
        let startDelta = selection.location - fragment.sourceRange.location
        let endDelta = selection.location + selection.length - fragment.sourceRange.location
        guard startDelta >= 0, endDelta > startDelta, endDelta <= shapedRange.length else {
            return nil
        }
        let shapedStart = shapedRange.location + startDelta
        let shapedEnd = shapedRange.location + endDelta
        let lineRange = CTLineGetStringRange(line)
        guard shapedStart >= lineRange.location,
              shapedEnd <= lineRange.location + lineRange.length else {
            return nil
        }
        let pieceOrigin = CTLineGetOffsetForStringIndex(line, shapedRange.location, nil)
        let start = CTLineGetOffsetForStringIndex(line, shapedStart, nil) - pieceOrigin
        let end = CTLineGetOffsetForStringIndex(line, shapedEnd, nil) - pieceOrigin
        return CGRect(
            x: fragment.rect.minX + start,
            y: fragment.rect.minY,
            width: max(1, end - start),
            height: fragment.rect.height
        )
    }

    private static func border(_ edge: BorderEdge) -> String {
        "\(scalar(edge.width)),\(String(describing: edge.style))"
    }
}
