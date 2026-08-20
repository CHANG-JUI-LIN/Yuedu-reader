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
        var boxCount = 0
        let box = buildBlockInternal(
            for: node, config: config, containerWidth: config.renderWidth,
            sourceText: &sourceText, anchors: &anchors,
            imageLoader: imageLoader, boxCount: &boxCount
        )
        Self.linkParents(box)
        return box
    }

    /// DEBUG-only: links each box to its parent for ancestry diagnostics.
    static func linkParents(_ box: BlockBox) {
        for child in box.children {
            child.parentBox = box
            linkParents(child)
        }
    }

    private static func buildBlockInternal(
        for node: ComputedStyleNode,
        config: BrowserLayoutConfig,
        containerWidth: CGFloat,
        sourceText: inout SourceTextBuilder,
        anchors: inout [String: Int],
        imageLoader: (String) -> UIImage?,
        boxCount: inout Int
    ) -> BlockBox {
        boxCount += 1
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
                } else if let element = elementNode.element,
                          let svgSource = Self.svgWrappedImageSource(element) {
                    registerAnchors(&anchorStack, ownID: elementNode.anchorID,
                                    anchors: &anchors, at: sourceText.currentOffset)
                    appendSVGImageRun(elementNode, source: svgSource, to: &pendingInline,
                                      sourceText: &sourceText, config: config, imageLoader: imageLoader)
                } else if elementNode.tag == "img" {
                    registerAnchors(&anchorStack, ownID: elementNode.anchorID,
                                    anchors: &anchors, at: sourceText.currentOffset)
                    if elementNode.style.isFloated || elementNode.style.display == .block {
                        flushGroup(&pendingInline, style: node.style, config: config,
                                   containerWidth: containerWidth,
                                   sourceText: &sourceText, into: &kids)
                        let attachment = makeBlockImage(for: elementNode, config: config, containerWidth: containerWidth, imageLoader: imageLoader)
                        let box = BlockBox(style: elementNode.style, boxType: .block)
                        box.imageAttachment = attachment
                        Self.attachDebugIdentity(box, node: elementNode)
                        kids.append(box)
                    } else {
                        appendImageRun(elementNode, to: &pendingInline, sourceText: &sourceText,
                                       config: config, imageLoader: imageLoader)
                    }
                } else if elementNode.style.isFloated || elementNode.style.display == .block {
                    flushGroup(&pendingInline, style: node.style, config: config,
                               containerWidth: containerWidth,
                               sourceText: &sourceText, into: &kids)
                    let childContainer = Self.childContainerWidth(
                        of: elementNode, parentWidth: containerWidth, config: config
                    )
                    kids.append(buildBlockInternal(
                        for: elementNode, config: config,
                        containerWidth: childContainer,
                        sourceText: &sourceText, anchors: &anchors, imageLoader: imageLoader,
                        boxCount: &boxCount
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
        Self.attachDebugIdentity(box, node: node)
        if !pendingInline.isEmpty {
            let visible = visibleRuns(pendingInline)
            box.inlineRuns = visible
            if let lines = layoutRuns(visible, style: node.style, config: config,
                                      containerWidth: containerWidth, sourceText: &sourceText) {
                box.lines = lines
            }
        }
        return box
    }

    /// The containing-block inline size for THIS node's children: the node's
    /// resolved width when non-auto, else the parent width. Percent widths
    /// resolve against the parent width (CSS 2.1 §10.3).
    private static func childContainerWidth(
        of node: ComputedStyleNode,
        parentWidth: CGFloat,
        config: BrowserLayoutConfig
    ) -> CGFloat {
        let resolved = CSSLengthResolver.resolve(node.style.width, emBase: node.style.fontSize, remBase: config.rootFontSize, percentBase: parentWidth)
        guard case .auto = node.style.width, resolved == nil else {
            return min(max(resolved ?? parentWidth, 0), parentWidth)
        }
        return parentWidth
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
                } else if let element = elementNode.element,
                          let svgSource = Self.svgWrappedImageSource(element) {
                    registerAnchors(&localStack, ownID: elementNode.anchorID,
                                    anchors: &anchors, at: sourceText.currentOffset)
                    appendSVGImageRun(elementNode, source: svgSource, to: &runs,
                                      sourceText: &sourceText, config: config, imageLoader: imageLoader)
                } else if elementNode.tag == "img" {
                    registerAnchors(&localStack, ownID: elementNode.anchorID,
                                    anchors: &anchors, at: sourceText.currentOffset)
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

    // MARK: - Anchor registration

    /// Binds the pending `id`s to the source offset where their content starts,
    /// then clears the stack. The single registration point for
    /// `charOffset(forSpine:fragment:)` — TOC entries, search results, restored
    /// reading positions and link targets all read the same map.
    ///
    /// Also called for replaced elements (Phase 3A). Registering only at text
    /// used to lose every id whose element contains no text of its own, and the
    /// 多看 footnote idiom is exactly that shape: the reference marker is
    /// `<a id="ref_1" href="#note_1"><img/></a>`, so "回到正文" resolved to a
    /// missing anchor and jumped to the top of the chapter instead of back to
    /// the sentence. `ownID` covers an id on the replaced element itself, which
    /// no ancestor stack can carry.
    private static func registerAnchors(
        _ anchorStack: inout [String],
        ownID: String? = nil,
        anchors: inout [String: Int],
        at offset: Int
    ) {
        if let ownID, anchors[ownID] == nil {
            anchors[ownID] = offset
        }
        guard !anchorStack.isEmpty else { return }
        for id in anchorStack where anchors[id] == nil {
            anchors[id] = offset
        }
        anchorStack.removeAll()
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
        if !isWhitespaceOnly {
            registerAnchors(&anchorStack, anchors: &anchors, at: sourceText.currentOffset)
        }
        let range = sourceText.append(collapsed)
        runs.append(InlineRun(
            text: collapsed, style: style,
            sourceRange: range, nodeID: nodeID, linkTarget: link
        ))
    }

    /// The EPUB cover idiom: `<svg viewBox="0 0 1000 1333" width="100%"
    /// height="100%"><image xlink:href="cover.jpg"/></svg>` — an SVG element
    /// used purely as a wrapper around one raster image. Returns the image
    /// source, or nil when the SVG carries any real vector content.
    ///
    /// This is NOT general SVG support: a single `<image>` and nothing else to
    /// draw. `BrowserLayoutCapabilityScanner` calls the SAME predicate, so the
    /// scanner and the box tree can never disagree about which SVGs are
    /// renderable.
    static func svgWrappedImageSource(_ element: Element) -> String? {
        guard element.tagName().lowercased() == "svg" else { return nil }
        guard let images = try? element.select("image").array(), images.count == 1,
              let image = images.first else { return nil }
        let drawable = (try? element.select(
            "path, rect, circle, ellipse, line, polyline, polygon, text, textPath, use, g, symbol, marker, pattern, mask, foreignObject"
        ).array()) ?? []
        guard drawable.isEmpty else { return nil }
        for attribute in ["xlink:href", "href"] {
            if let href = try? image.attr(attribute), !href.isEmpty { return href }
        }
        return nil
    }

    /// Emits an SVG-wrapped cover image as a replaced element. Sized like an
    /// `<img>` under `max-width: 100%`: the intrinsic bitmap, scaled down to
    /// the container when it is wider. The SVG's own `width="100%"` is an
    /// attribute rather than CSS, so the clamp is applied explicitly here.
    private static func appendSVGImageRun(
        _ node: ComputedStyleNode,
        source: String,
        to runs: inout [InlineRun],
        sourceText: inout SourceTextBuilder,
        config: BrowserLayoutConfig,
        imageLoader: (String) -> UIImage?
    ) {
        guard let image = imageLoader(source) else { return }
        let intrinsic = image.size
        guard intrinsic.width > 0, intrinsic.height > 0 else { return }
        let scale = min(1, config.renderWidth / intrinsic.width)
        let usedSize = CGSize(width: intrinsic.width * scale, height: intrinsic.height * scale)
        runs.append(InlineRun(
            text: "\u{FFFC}", style: node.style,
            sourceRange: NSRange(location: sourceText.currentOffset, length: 0),
            nodeID: node.nodeID, linkTarget: node.linkTarget,
            atomic: AtomicInline(
                source: source, image: image, usedSize: usedSize,
                nodeID: node.nodeID, linkTarget: node.linkTarget
            )
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
        // NOTE: the image's containing block for % widths stays the BODY
        // content width (config.renderWidth) — the 画册 CSS sizes images with
        // `width: 90%` against the body, and the reader contract treats that
        // 352.8pt image as the reference size. The PARAGRAPH's line-box
        // maxWidth (passed to layoutRuns) is the narrower containing box, so
        // centering resolves against the actual cell width — the image equals
        // the cell width and centers at the cell origin.
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
            atomic: AtomicInline(
                source: src, image: image, usedSize: usedSize,
                nodeID: node.nodeID, linkTarget: node.linkTarget
            )
        ))
    }

    private static func makeBlockImage(
        for node: ComputedStyleNode,
        config: BrowserLayoutConfig,
        containerWidth: CGFloat,
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
        return AtomicInline(
            source: src, image: image, usedSize: usedSize,
            nodeID: node.nodeID, linkTarget: node.linkTarget
        )
    }

    // MARK: - Group lifecycle

    /// Closes the pending inline group as an anonymous block at the CURRENT
    /// position in the sibling order (a block sibling is about to follow).
    private static func flushGroup(
        _ runs: inout [InlineRun],
        style: ComputedStyle,
        config: BrowserLayoutConfig,
        containerWidth: CGFloat,
        sourceText: inout SourceTextBuilder,
        into kids: inout [BlockBox]
    ) {
        let visible = visibleRuns(runs)
        guard !visible.isEmpty else {
            runs = []
            return
        }
        let box = BlockBox(style: style, boxType: .anonymous, inlineRuns: visible)
        if let lines = layoutRuns(visible, style: style, config: config,
                                  containerWidth: containerWidth, sourceText: &sourceText) {
            box.lines = lines
        }
        kids.append(box)
        runs = []
    }

    /// Drops trailing whitespace-only runs (inter-block whitespace), then lays
    /// the remaining runs into line boxes. nil when nothing visible remains.
    private static func layoutRuns(
        _ runs: [InlineRun],
        style: ComputedStyle,
        config: BrowserLayoutConfig,
        containerWidth: CGFloat,
        sourceText: inout SourceTextBuilder
    ) -> [LayoutLine]? {
        let visible = visibleRuns(runs)
        guard !visible.isEmpty else { return nil }
        return InlineLayout.layoutLines(
            runs: visible,
            maxWidth: containerWidth,
            rootFontSize: config.rootFontSize,
            lineHeight: style.lineHeight,
            sourceText: sourceText.text,
            fontResolver: config.fontResolver
        )
    }

    private static func visibleRuns(_ runs: [InlineRun]) -> [InlineRun] {
        var visible = runs
        while let last = visible.last,
              last.atomic == nil,
              !last.isHardBreak,
              last.text.allSatisfy({ $0 == " " || $0 == "\t" }) {
            visible.removeLast()
        }
        return visible
    }
}

extension BoxTreeBuilder {
    /// Total block-box count in a tree (lifecycle accounting).
    static func countBoxes(in box: BlockBox) -> Int {
        var count = 1
        for child in box.children {
            count += countBoxes(in: child)
        }
        return count
    }

    /// Copies DOM identity (tag/class/id/nodeID) onto a box for diagnostics.
    /// Layout never reads these.
    static func attachDebugIdentity(_ box: BlockBox, node: ComputedStyleNode) {
        box.debugTag = node.tag
        box.debugNodeID = node.nodeID
        box.debugID = node.anchorID
        if let element = node.element {
            box.debugClasses = (try? element.classNames().map { $0 }) ?? []
        }
    }
}
