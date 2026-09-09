import Foundation
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
        BrowserReaderTextStyling.prepare(root: box, sourceText: sourceText.text, config: config)
        #if DEBUG
        assertUnformatted(box)
        #endif
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
        var assignedFirstInlineContext = false
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
                } else if let element = elementNode.semanticElement,
                          let svgSource = Self.svgWrappedImageSource(element) {
                    registerAnchors(&anchorStack, ownID: elementNode.anchorID,
                                    anchors: &anchors, at: sourceText.currentOffset)
                    appendSVGImageRun(elementNode, source: svgSource, to: &pendingInline,
                                      sourceText: &sourceText, imageLoader: imageLoader)
                } else if elementNode.tag == "img" {
                    registerAnchors(&anchorStack, ownID: elementNode.anchorID,
                                    anchors: &anchors, at: sourceText.currentOffset)
                    if elementNode.style.isFloated || elementNode.style.display == .block {
                        flushGroup(
                            &pendingInline,
                            style: node.style,
                            into: &kids,
                            assignedFirstInlineContext: &assignedFirstInlineContext
                        )
                        let attachment = makeBlockImage(for: elementNode, imageLoader: imageLoader)
                        let box = BlockBox(style: elementNode.style, boxType: .block)
                        box.imageAttachment = attachment
                        Self.attachDebugIdentity(box, node: elementNode)
                        kids.append(box)
                    } else {
                        appendImageRun(elementNode, to: &pendingInline, sourceText: &sourceText,
                                       imageLoader: imageLoader)
                    }
                } else if elementNode.tag == "ruby" {
                    appendRubyRun(
                        elementNode,
                        to: &pendingInline,
                        sourceText: &sourceText,
                        anchors: &anchors,
                        anchorStack: &anchorStack
                    )
                } else if elementNode.style.isFloated || elementNode.style.display == .block {
                    flushGroup(
                        &pendingInline,
                        style: node.style,
                        into: &kids,
                        assignedFirstInlineContext: &assignedFirstInlineContext
                    )
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
        let trailingVisibleRuns = visibleRuns(pendingInline)
        if !trailingVisibleRuns.isEmpty {
            box.inlineRuns = trailingVisibleRuns
            box.ownsFirstFormattedLine = !assignedFirstInlineContext
            assignedFirstInlineContext = true
        }
        _ = assignedFirstInlineContext
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
        let firstRun = runs.count
        let sourceStart = sourceText.currentOffset
        defer {
            if runs.count > firstRun {
                preserveInlineDecoration(node, firstRun: firstRun, sourceStart: sourceStart,
                    sourceEnd: sourceText.currentOffset, runs: &runs)
            }
        }
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
                } else if let element = elementNode.semanticElement,
                          let svgSource = Self.svgWrappedImageSource(element) {
                    registerAnchors(&localStack, ownID: elementNode.anchorID,
                                    anchors: &anchors, at: sourceText.currentOffset)
                    appendSVGImageRun(elementNode, source: svgSource, to: &runs,
                                      sourceText: &sourceText, imageLoader: imageLoader)
                } else if elementNode.tag == "img" {
                    registerAnchors(&localStack, ownID: elementNode.anchorID,
                                    anchors: &anchors, at: sourceText.currentOffset)
                    appendImageRun(elementNode, to: &runs, sourceText: &sourceText,
                                   imageLoader: imageLoader)
                } else if elementNode.tag == "ruby" {
                    appendRubyRun(
                        elementNode,
                        to: &runs,
                        sourceText: &sourceText,
                        anchors: &anchors,
                        anchorStack: &localStack
                    )
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

    private static func preserveInlineDecoration(
        _ node: ComputedStyleNode, firstRun: Int, sourceStart: Int,
        sourceEnd: Int, runs: inout [InlineRun]
    ) {
        let style = node.style
        let startEdge = style.paddingLeft != .px(0) || style.borderLeftWidth > 0
        let endEdge = style.paddingRight != .px(0) || style.borderRightWidth > 0
        let hasPaint = style.backgroundColor != nil || style.borderTopWidth > 0
            || style.borderBottomWidth > 0 || startEdge || endEdge
        guard hasPaint else { return }
        let decoration = InlineDecoration(nodeID: node.nodeID, style: style,
            sourceRange: NSRange(location: sourceStart, length: sourceEnd - sourceStart))
        for index in firstRun..<runs.count {
            runs[index].inlineDecorations.insert(decoration, at: 0)
        }
        // U+FFFC reserves shaped-only padding. U+2060 joins each edge to
        // its adjacent glyph so padding cannot be orphaned on a wrapped line.
        func edge(_ isStart: Bool) -> InlineRun {
            var run = InlineRun(text: isStart ? "\u{FFFC}\u{2060}" : "\u{2060}\u{FFFC}", style: style,
                sourceRange: NSRange(location: isStart ? sourceStart : sourceEnd, length: 0),
                nodeID: node.nodeID, linkTarget: node.linkTarget)
            run.inlineDecorations = [decoration]
            run.decorationEdge = isStart
            return run
        }
        if endEdge { runs.append(edge(false)) }
        if startEdge { runs.insert(edge(true), at: firstRun) }
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

    private static func appendRubyRun(
        _ node: ComputedStyleNode,
        to runs: inout [InlineRun],
        sourceText: inout SourceTextBuilder,
        anchors: inout [String: Int],
        anchorStack: inout [String]
    ) {
        guard let structure = HorizontalRubySupport.structure(for: node) else {
            assertionFailure("unsupported Ruby reached BoxTreeBuilder")
            return
        }

        var baseRuns: [InlineRun] = []
        var localAnchors = anchorStack
        if let own = node.anchorID { localAnchors.append(own) }
        collectRubyBase(
            structure.baseChildren,
            inheritedNode: node,
            runs: &baseRuns,
            sourceText: &sourceText,
            anchors: &anchors,
            anchorStack: &localAnchors
        )
        let pieces = baseRuns.map {
            RubyInlinePiece(
                text: $0.text,
                style: $0.style,
                sourceRange: $0.sourceRange,
                nodeID: $0.nodeID,
                linkTarget: $0.linkTarget
            )
        }
        guard let first = pieces.first, let last = pieces.last else {
            assertionFailure("validated Ruby produced no base pieces")
            return
        }
        anchorStack.removeAll()

        var annotationPieces: [RubyAnnotationPiece] = []
        collectRubyAnnotation(
            structure.annotation.children,
            inheritedNode: structure.annotation,
            pieces: &annotationPieces
        )
        annotationPieces = trimRubyAnnotationEdges(annotationPieces)
        let range = NSRange(
            location: first.sourceRange.location,
            length: NSMaxRange(last.sourceRange) - first.sourceRange.location
        )
        let unit = RubyInlineUnit(
            base: pieces,
            annotation: RubyAnnotation(
                pieces: annotationPieces
            ),
            sourceRange: range,
            nodeID: node.nodeID,
            linkTarget: node.linkTarget,
            alignment: node.style.rubyAlign,
            position: node.style.rubyPosition
        )
        runs.append(InlineRun(
            text: "\u{FFFC}",
            style: node.style,
            sourceRange: range,
            nodeID: node.nodeID,
            linkTarget: node.linkTarget,
            ruby: unit
        ))
    }

    private static func collectRubyBase(
        _ children: [StyleTreeChild],
        inheritedNode: ComputedStyleNode,
        runs: inout [InlineRun],
        sourceText: inout SourceTextBuilder,
        anchors: inout [String: Int],
        anchorStack: inout [String]
    ) {
        for child in children {
            switch child {
            case .text(let raw):
                appendTextNode(
                    raw,
                    style: inheritedNode.style,
                    nodeID: inheritedNode.nodeID,
                    link: inheritedNode.linkTarget,
                    to: &runs,
                    sourceText: &sourceText,
                    anchors: &anchors,
                    anchorStack: &anchorStack
                )
            case .element(let element):
                guard element.tag != "rp" else { continue }
                var nestedAnchors = anchorStack
                if let own = element.anchorID { nestedAnchors.append(own) }
                collectRubyBase(
                    element.children,
                    inheritedNode: element,
                    runs: &runs,
                    sourceText: &sourceText,
                    anchors: &anchors,
                    anchorStack: &nestedAnchors
                )
            }
        }
    }

    private static func collectRubyAnnotation(
        _ children: [StyleTreeChild],
        inheritedNode: ComputedStyleNode,
        pieces: inout [RubyAnnotationPiece]
    ) {
        for child in children {
            switch child {
            case .text(let raw):
                let text = InlineLayout.collapseText(
                    raw,
                    mode: inheritedNode.style.whiteSpace
                )
                guard !text.isEmpty else { continue }
                pieces.append(RubyAnnotationPiece(
                    text: text,
                    style: inheritedNode.style,
                    nodeID: inheritedNode.nodeID,
                    linkTarget: inheritedNode.linkTarget
                ))
            case .element(let element):
                collectRubyAnnotation(
                    element.children,
                    inheritedNode: element,
                    pieces: &pieces
                )
            }
        }
    }

    private static func trimRubyAnnotationEdges(
        _ pieces: [RubyAnnotationPiece]
    ) -> [RubyAnnotationPiece] {
        var result = pieces
        while let first = result.first {
            let text = first.text.drop(while: { $0.isWhitespace })
            if text.isEmpty {
                result.removeFirst()
            } else if text.count != first.text.count {
                result[0] = RubyAnnotationPiece(
                    text: String(text),
                    style: first.style,
                    nodeID: first.nodeID,
                    linkTarget: first.linkTarget
                )
                break
            } else {
                break
            }
        }
        while let last = result.last {
            let text = last.text.reversed().drop(while: { $0.isWhitespace }).reversed()
            if text.isEmpty {
                result.removeLast()
            } else if text.count != last.text.count {
                result[result.count - 1] = RubyAnnotationPiece(
                    text: String(text),
                    style: last.style,
                    nodeID: last.nodeID,
                    linkTarget: last.linkTarget
                )
                break
            } else {
                break
            }
        }
        return result
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
    static func svgWrappedImageSource(_ element: HTMLDOMElementSnapshot) -> String? {
        guard element.tagName == "svg" else { return nil }
        guard case .rasterWrapper(let source) = element.svgRenderability else {
            return nil
        }
        return source
    }

    /// Emits an SVG-wrapped cover image as a replaced element. BoxTreeBuilder
    /// records intrinsic data only; BlockLayout owns its final used size once
    /// the containing block is known.
    private static func appendSVGImageRun(
        _ node: ComputedStyleNode,
        source: String,
        to runs: inout [InlineRun],
        sourceText: inout SourceTextBuilder,
        imageLoader: (String) -> UIImage?
    ) {
        guard let image = imageLoader(source) else { return }
        let intrinsic = image.size
        guard intrinsic.width > 0, intrinsic.height > 0 else { return }
        runs.append(InlineRun(
            text: "\u{FFFC}", style: node.style,
            sourceRange: NSRange(location: sourceText.currentOffset, length: 0),
            nodeID: node.nodeID, linkTarget: node.linkTarget,
            atomic: AtomicInline(
                source: source, image: image, usedSize: intrinsic,
                nodeID: node.nodeID, linkTarget: node.linkTarget
            )
        ))
    }

    private static func appendImageRun(
        _ node: ComputedStyleNode,
        to runs: inout [InlineRun],
        sourceText: inout SourceTextBuilder,
        imageLoader: (String) -> UIImage?
    ) {
        let src = node.semanticElement?.attribute("src") ?? ""
        let image = imageLoader(src)
        let intrinsic = image?.size ?? .zero
        guard intrinsic.width > 0, intrinsic.height > 0, let image else { return }
        runs.append(InlineRun(
            text: "\u{FFFC}", style: node.style,
            sourceRange: NSRange(location: sourceText.currentOffset, length: 0),
            nodeID: node.nodeID, linkTarget: node.linkTarget,
            atomic: AtomicInline(
                source: src, image: image, usedSize: intrinsic,
                nodeID: node.nodeID, linkTarget: node.linkTarget
            )
        ))
    }

    private static func makeBlockImage(
        for node: ComputedStyleNode,
        imageLoader: (String) -> UIImage?
    ) -> AtomicInline? {
        let src = node.semanticElement?.attribute("src") ?? ""
        guard let image = imageLoader(src) else { return nil }
        return AtomicInline(
            source: src, image: image, usedSize: image.size,
            nodeID: node.nodeID, linkTarget: node.linkTarget
        )
    }

    // MARK: - Group lifecycle

    /// Closes the pending inline group as an anonymous block at the CURRENT
    /// position in the sibling order (a block sibling is about to follow).
    private static func flushGroup(
        _ runs: inout [InlineRun],
        style: ComputedStyle,
        into kids: inout [BlockBox],
        assignedFirstInlineContext: inout Bool
    ) {
        let visible = visibleRuns(runs)
        guard !visible.isEmpty else {
            runs = []
            return
        }
        kids.append(BlockBox(
            style: style,
            boxType: .anonymous,
            inlineRuns: visible,
            ownsFirstFormattedLine: !assignedFirstInlineContext
        ))
        assignedFirstInlineContext = true
        runs = []
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

    #if DEBUG
    /// BoxTreeBuilder owns unformatted runs only. A non-empty line array here
    /// means shaping escaped the InlineLayout call owned by BlockLayout.
    private static func assertUnformatted(_ box: BlockBox) {
        assert(box.lines.isEmpty, "BoxTreeBuilder must not create LayoutLine values")
        for child in box.children {
            assertUnformatted(child)
        }
    }
    #endif
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
        if let element = node.semanticElement {
            box.debugClasses = element.classTokens
        }
    }
}
