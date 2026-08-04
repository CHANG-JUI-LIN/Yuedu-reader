import Foundation
import SwiftSoup
import UIKit

/// Accumulates the chapter's collapsed source text. Runs' `sourceRange`s point
/// into `text`; concatenating them in document order reassembles the text.
struct SourceTextBuilder {
    private(set) var text = ""
    var currentOffset: Int { (text as NSString).length }

    @discardableResult
    mutating func append(_ s: String) -> NSRange {
        let range = NSRange(location: currentOffset, length: (s as NSString).length)
        text.append(s)
        return range
    }
}

/// ComputedStyleNode tree → block box tree, preserving DOM order.
///
/// A block's children are either block boxes or inline content. Inline content
/// is gathered into runs; whenever a block sibling interrupts the inline flow,
/// the pending runs are flushed into a NEW anonymous block AT THAT POSITION —
/// interleaving order (inline/block/inline) is fully preserved, and content is
/// never merged across a block sibling.
///
/// This stage also builds the chapter `sourceText` (one collapse pass, shared
/// with line layout) and resolves replaced elements (`<img>`).
enum BoxTreeBuilder {

    static func buildBlock(
        for node: ComputedStyleNode,
        config: BrowserLayoutConfig,
        sourceText: inout SourceTextBuilder,
        anchors: inout [String: Int],
        imageLoader: (String) -> UIImage?
    ) -> BlockBox {
        var kids: [BlockBox] = []
        var pendingInline: [InlineRun] = []
        // anchor IDs that will register at the first text run appended under them
        var anchorStack: [String] = []
        if let anchor = node.anchorID { anchorStack.append(anchor) }

        for child in node.children {
            switch child {
            case .text(let raw):
                appendTextNode(
                    raw, style: node.style, nodeID: node.nodeID, link: node.linkTarget,
                    to: &pendingInline, sourceText: &sourceText,
                    anchors: &anchors, anchorStack: &anchorStack
                )
            case .element(let elementNode):
                if elementNode.tag == "br" {
                    // Forced line break: survives every whitespace mode.
                    let range = sourceText.append("\n")
                    pendingInline.append(InlineRun(
                        text: "\n", style: elementNode.style,
                        sourceRange: range, nodeID: elementNode.nodeID,
                        linkTarget: elementNode.linkTarget, isHardBreak: true
                    ))
                } else if elementNode.tag == "img" {
                    if elementNode.style.display == .block {
                        flushGroup(&pendingInline, style: node.style, config: config,
                                   sourceText: &sourceText, into: &kids)
                        let attachment = makeBlockImage(for: elementNode, config: config, imageLoader: imageLoader)
                        let box = BlockBox(style: elementNode.style, boxType: .block)
                        box.imageAttachment = attachment
                        kids.append(box)
                    } else {
                        appendImageRun(elementNode, to: &pendingInline, sourceText: &sourceText,
                                       config: config, imageLoader: imageLoader)
                    }
                } else if elementNode.style.display == .block {
                    flushGroup(&pendingInline, style: node.style, config: config,
                               sourceText: &sourceText, into: &kids)
                    kids.append(buildBlock(
                        for: elementNode, config: config,
                        sourceText: &sourceText, anchors: &anchors, imageLoader: imageLoader
                    ))
                } else if elementNode.style.display == .none {
                    continue
                } else {
                    collectInline(
                        elementNode, into: &pendingInline, config: config,
                        sourceText: &sourceText, anchors: &anchors,
                        anchorStack: &anchorStack, imageLoader: imageLoader
                    )
                }
            }
        }

        let box = BlockBox(style: node.style, boxType: .block, children: kids)
        if !pendingInline.isEmpty {
            if let lines = layoutRuns(pendingInline, style: node.style, config: config, sourceText: &sourceText) {
                box.lines = lines
            }
        }
        return box
    }

    // MARK: - Inline gathering

    private static func collectInline(
        _ node: ComputedStyleNode,
        into runs: inout [InlineRun],
        config: BrowserLayoutConfig,
        sourceText: inout SourceTextBuilder,
        anchors: inout [String: Int],
        anchorStack: inout [String],
        imageLoader: (String) -> UIImage?
    ) {
        var localStack = anchorStack
        if let anchor = node.anchorID { localStack.append(anchor) }
        for child in node.children {
            switch child {
            case .text(let raw):
                appendTextNode(
                    raw, style: node.style, nodeID: node.nodeID, link: node.linkTarget,
                    to: &runs, sourceText: &sourceText, anchors: &anchors, anchorStack: &localStack
                )
            case .element(let elementNode):
                if elementNode.tag == "br" {
                    let range = sourceText.append("\n")
                    runs.append(InlineRun(
                        text: "\n", style: elementNode.style,
                        sourceRange: range, nodeID: elementNode.nodeID,
                        linkTarget: elementNode.linkTarget, isHardBreak: true
                    ))
                } else if elementNode.tag == "img" {
                    appendImageRun(elementNode, to: &runs, sourceText: &sourceText,
                                   config: config, imageLoader: imageLoader)
                } else if elementNode.style.display == .block || elementNode.style.display == .none {
                    // Block sibling inside inline flow (e.g. div inside span):
                    // Phase 1.5 flattens it into its own anonymous group boundary
                    // by closing the current group (interleaving preserved at the
                    // nearest enclosing block level via recursion in buildBlock).
                    continue
                } else {
                    collectInline(
                        elementNode, into: &runs, config: config,
                        sourceText: &sourceText, anchors: &anchors,
                        anchorStack: &localStack, imageLoader: imageLoader
                    )
                }
            }
        }
    }

    // MARK: - Run creation

    private static func appendTextNode(
        _ raw: String,
        style: ComputedStyle,
        nodeID: Int,
        link: String?,
        to runs: inout [InlineRun],
        sourceText: inout SourceTextBuilder,
        anchors: inout [String: Int],
        anchorStack: inout [String]
    ) {
        let collapsed = InlineLayout.collapseText(raw, mode: style.whiteSpace)
        guard !collapsed.isEmpty else { return }
        let isWhitespaceOnly = collapsed.allSatisfy { $0 == " " || $0 == "\t" }
        if isWhitespaceOnly && runs.isEmpty {
            // Leading whitespace at a group start (e.g. pretty-printed XHTML
            // between block siblings): dropped, never rendered.
            return
        }
        if !isWhitespaceOnly, !anchorStack.isEmpty {
            for id in anchorStack where anchors[id] == nil {
                anchors[id] = sourceText.currentOffset
            }
            anchorStack.removeAll()
        }
        let range = sourceText.append(collapsed)
        runs.append(InlineRun(
            text: collapsed, style: style,
            sourceRange: range, nodeID: nodeID, linkTarget: link
        ))
    }

    private static func appendImageRun(
        _ node: ComputedStyleNode,
        to runs: inout [InlineRun],
        sourceText: inout SourceTextBuilder,
        config: BrowserLayoutConfig,
        imageLoader: (String) -> UIImage?
    ) {
        let src = (node.element.flatMap { try? $0.attr("src") }) ?? ""
        let image = imageLoader(src)
        let intrinsic = image?.size ?? .zero
        let usedSize = BlockLayout.resolveReplacedSize(
            intrinsic: intrinsic,
            style: node.style,
            containerWidth: config.renderWidth,
            rootFontSize: config.rootFontSize
        )
        guard usedSize.width > 0, usedSize.height > 0, let image else { return }
        runs.append(InlineRun(
            text: "\u{FFFC}", style: node.style,
            sourceRange: NSRange(location: sourceText.currentOffset, length: 0),
            nodeID: node.nodeID, linkTarget: node.linkTarget,
            atomic: AtomicInline(source: src, image: image, usedSize: usedSize)
        ))
    }

    private static func makeBlockImage(
        for node: ComputedStyleNode,
        config: BrowserLayoutConfig,
        imageLoader: (String) -> UIImage?
    ) -> AtomicInline? {
        let src = (node.element.flatMap { try? $0.attr("src") }) ?? ""
        guard let image = imageLoader(src) else { return nil }
        let usedSize = BlockLayout.resolveReplacedSize(
            intrinsic: image.size,
            style: node.style,
            containerWidth: config.renderWidth,
            rootFontSize: config.rootFontSize
        )
        return AtomicInline(source: src, image: image, usedSize: usedSize)
    }

    // MARK: - Group lifecycle

    /// Closes the pending inline group as an anonymous block at the CURRENT
    /// position in the sibling order (a block sibling is about to follow).
    private static func flushGroup(
        _ runs: inout [InlineRun],
        style: ComputedStyle,
        config: BrowserLayoutConfig,
        sourceText: inout SourceTextBuilder,
        into kids: inout [BlockBox]
    ) {
        guard let lines = layoutRuns(runs, style: style, config: config, sourceText: &sourceText) else {
            runs = []
            return
        }
        let box = BlockBox(style: style, boxType: .anonymous)
        box.lines = lines
        kids.append(box)
        runs = []
    }

    /// Drops trailing whitespace-only runs (inter-block whitespace), then lays
    /// the remaining runs into line boxes. nil when nothing visible remains.
    private static func layoutRuns(
        _ runs: [InlineRun],
        style: ComputedStyle,
        config: BrowserLayoutConfig,
        sourceText: inout SourceTextBuilder
    ) -> [LayoutLine]? {
        var visible = runs
        while let last = visible.last,
              last.atomic == nil,
              !last.isHardBreak,
              last.text.allSatisfy({ $0 == " " || $0 == "\t" }) {
            visible.removeLast()
        }
        guard !visible.isEmpty else { return nil }
        return InlineLayout.layoutLines(
            runs: visible,
            maxWidth: config.renderWidth,
            rootFontSize: config.rootFontSize,
            lineHeight: style.lineHeight,
            sourceText: sourceText.text,
            fontResolver: config.fontResolver
        )
    }
}
