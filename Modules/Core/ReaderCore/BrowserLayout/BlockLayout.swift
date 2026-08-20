import CoreGraphics
import UIKit

/// One-pass block formatting: resolves used widths/margins/paddings and stacks
/// children along the BLOCK axis. `containerWidth` is the parent's *content*
/// width (physical). Phase 3A: the stacking algorithm operates on logical
/// coordinates — children advance along block-start → block-end and are
/// positioned at inline-start — with the physical direction decided by the
/// writing mode. For horizontalTB this is byte-for-byte the historical
/// top-to-bottom stacking; for verticalRL it becomes right-to-left.
enum BlockLayout {

    /// Lays out `box` and all descendants; returns the box's content-box extent
    /// along the BLOCK axis. `rootFontSize` is the chapter's root font size —
    /// the rem base (never the current element's font size).
    ///
    /// Child frames are positioned relative to THIS box's CONTENT box (inside
    /// border+padding). The fragment walk adds each box's own border+padding
    /// when descending, so parent padding is never double-counted.
    @discardableResult
    static func layOut(
        root box: BlockBox,
        containerWidth: CGFloat,
        rootFontSize: CGFloat = 17,
        writingMode: ReaderWritingMode = .horizontal,
        floatContext: FloatContext? = nil,
        blockOffsetY: CGFloat = 0,
        sourceText: String = "",
        fontResolver: (([String], Int, Bool, CGFloat) -> UIFont?)? = nil,
        fragmentHeight: CGFloat? = nil
    ) -> CGFloat {
        var sides = resolveSides(box, containerWidth: containerWidth, rootFontSize: rootFontSize, writingMode: writingMode)
        // Paged replaced-element fit policy is resolved before float exclusion
        // and line breaking. Doing this later in PageWalker would shrink only
        // the painted image while surrounding text still excluded the original
        // 300pt-tall rectangle.
        if box.isFloated,
           let pageHeight = fragmentHeight,
           let attachment = box.imageAttachment {
            let availableHeight = max(
                1,
                pageHeight - sides.margins.vertical - sides.padding.vertical - sides.borders.vertical
            )
            if attachment.usedSize.height > availableHeight {
                let scale = availableHeight / attachment.usedSize.height
                box.imageAttachment = AtomicInline(
                    source: attachment.source,
                    image: attachment.image,
                    usedSize: CGSize(
                        width: max(1, attachment.usedSize.width * scale),
                        height: availableHeight
                    ),
                    nodeID: attachment.nodeID,
                    linkTarget: attachment.linkTarget
                )
                sides = resolveSides(
                    box,
                    containerWidth: containerWidth,
                    rootFontSize: rootFontSize,
                    writingMode: writingMode
                )
            }
        }
        box.margins = sides.margins
        box.padding = sides.padding
        box.borders = sides.borders
        box.contentSize.width = sides.contentWidth
        // Frame is physical; its width is the inline-axis extent of the box.
        box.frame = ParentLocalRect(rawValue: CGRect(x: 0, y: 0, width: sides.borderBoxWidth, height: 0))

        // Create or inherit FloatContext (only for horizontal writing mode in Phase 4B)
        let fc: FloatContext?
        if writingMode == .horizontal {
            fc = floatContext ?? FloatContext(containerWidth: sides.contentWidth)
        } else {
            fc = nil
        }

        var cursorBlock: CGFloat = 0   // content-box-relative, along block axis
        var previousBlockEndMargin: CGFloat? = nil
        var hasInFlowChild = false

        for child in box.children {
            // Resolve the child's used box model before positioning it. Reading
            // `child.margins` before the recursive layout left every fresh box
            // at zero, so fixed-width blocks with auto margins were pinned left.
            let childSides = resolveSides(
                child,
                containerWidth: box.contentSize.width,
                rootFontSize: rootFontSize,
                writingMode: writingMode
            )
            child.margins = childSides.margins
            child.padding = childSides.padding
            child.borders = childSides.borders
            child.contentSize.width = childSides.contentWidth

            // 1. Clearance calculation
            if let fc = fc, child.style.cssClear != .none {
                let clearedY = fc.clearance(for: child.style.cssClear, currentY: blockOffsetY + cursorBlock)
                if clearedY > blockOffsetY + cursorBlock {
                    cursorBlock = clearedY - blockOffsetY
                    // CSS 2.1 §8.3.1: clearance prevents margins from collapsing with preceding siblings
                    previousBlockEndMargin = nil
                }
            }

            if child.isFloated, writingMode == .horizontal, let fc = fc {
                // 2. Floated Child
                // A float establishes its own formatting context. Its contents
                // are local to the float and must not wrap around the parent
                // context's floats before the outer float has even been placed.
                let childContentHeight = layOut(
                    root: child,
                    containerWidth: box.contentSize.width,
                    rootFontSize: rootFontSize,
                    writingMode: writingMode,
                    floatContext: nil,
                    blockOffsetY: 0,
                    sourceText: sourceText,
                    fontResolver: fontResolver,
                    fragmentHeight: fragmentHeight
                )

                let borderBoxBlockExtent = child.borders.vertical + child.padding.vertical + childContentHeight
                let borderBoxInlineExtent = child.borderBoxWidth

                let marginBoxSize = CGSize(
                    width: borderBoxInlineExtent + child.margins.horizontal,
                    height: borderBoxBlockExtent + child.margins.vertical
                )

                let placed = fc.placeFloat(
                    side: child.style.cssFloat,
                    marginBoxSize: marginBoxSize,
                    margins: child.margins,
                    startY: blockOffsetY + cursorBlock,
                    nodeID: child.debugNodeID,
                    clear: child.style.cssClear
                )

                let childLocalX = placed.borderBox.minX
                let childLocalY = placed.borderBox.minY - blockOffsetY

                child.logicalInlineOrigin = childLocalX
                child.logicalBlockOrigin = childLocalY
                child.frame = ParentLocalRect(rawValue: CGRect(
                    x: childLocalX,
                    y: childLocalY,
                    width: borderBoxInlineExtent,
                    height: borderBoxBlockExtent
                ))

                // Floats do not collapse margins with normal-flow siblings
                previousBlockEndMargin = nil
            } else {
                // 3. Normal Flow Child
                let childMarginBlockStart = LogicalGeometry.blockStart(edge: child.margins, mode: writingMode)
                let childMarginBlockEnd = LogicalGeometry.blockEnd(edge: child.margins, mode: writingMode)
                let childMarginInlineStart = LogicalGeometry.inlineStart(edge: child.margins, mode: writingMode)
                let collapsedTop: CGFloat

                if let prev = previousBlockEndMargin {
                    collapsedTop = Margins.collapse(prev, childMarginBlockStart)
                    child.logicalBlockOrigin = cursorBlock - prev + collapsedTop
                } else if !hasInFlowChild
                            && cursorBlock == 0
                            && child.style.cssClear == .none
                            && LogicalGeometry.blockStart(edge: box.borders, mode: writingMode) == 0
                            && LogicalGeometry.blockStart(edge: box.padding, mode: writingMode) == 0 {
                    collapsedTop = childMarginBlockStart
                    child.logicalBlockOrigin = 0
                    box.margins.top = max(box.margins.top, collapsedTop)
                } else {
                    collapsedTop = childMarginBlockStart
                    child.logicalBlockOrigin = cursorBlock + childMarginBlockStart
                }

                if child.style.cssClear != .none, let fc = fc {
                    let clearanceY = fc.clearance(for: child.style.cssClear, currentY: blockOffsetY + child.logicalBlockOrigin)
                    if clearanceY > blockOffsetY + child.logicalBlockOrigin {
                        child.logicalBlockOrigin = clearanceY - blockOffsetY
                        previousBlockEndMargin = nil
                    }
                }
                child.logicalInlineOrigin = childMarginInlineStart

                let childBlockOffsetY = blockOffsetY + child.logicalBlockOrigin
                    + LogicalGeometry.blockStart(edge: child.borders, mode: writingMode)
                    + LogicalGeometry.blockStart(edge: child.padding, mode: writingMode)

                let childContentHeight = layOut(
                    root: child,
                    containerWidth: box.contentSize.width,
                    rootFontSize: rootFontSize,
                    writingMode: writingMode,
                    floatContext: fc,
                    blockOffsetY: childBlockOffsetY,
                    sourceText: sourceText,
                    fontResolver: fontResolver,
                    fragmentHeight: fragmentHeight
                )

                let borderBoxBlockExtent = LogicalGeometry.blockAxisExtent(child.borders, mode: writingMode)
                    + LogicalGeometry.blockAxisExtent(child.padding, mode: writingMode)
                    + childContentHeight

                let inlineExtent = child.borderBoxWidth
                switch writingMode {
                case .horizontal:
                    child.frame = ParentLocalRect(rawValue: CGRect(
                        x: child.logicalInlineOrigin,
                        y: child.logicalBlockOrigin,
                        width: inlineExtent,
                        height: borderBoxBlockExtent
                    ))
                case .verticalRTL:
                    let parentContentBlockExtent = box.contentSize.width
                    let blockPosFromRight = child.logicalBlockOrigin
                    let x = parentContentBlockExtent - blockPosFromRight - borderBoxBlockExtent
                    child.frame = ParentLocalRect(rawValue: CGRect(
                        x: x,
                        y: child.logicalInlineOrigin,
                        width: borderBoxBlockExtent,
                        height: inlineExtent
                    ))
                }
                cursorBlock = child.logicalBlockOrigin + borderBoxBlockExtent + childMarginBlockEnd
                previousBlockEndMargin = childMarginBlockEnd
                hasInFlowChild = true
            }
        }

        if box.lines.isEmpty, let last = previousBlockEndMargin,
           LogicalGeometry.blockEnd(edge: box.borders, mode: writingMode) == 0,
           LogicalGeometry.blockEnd(edge: box.padding, mode: writingMode) == 0 {
            cursorBlock -= last
        }

        // BoxTreeBuilder already shaped inline content at the box's resolved
        // width. Re-shape only when one of those actual line bands intersects
        // an active float. Re-laying every box here changes centering and line
        // geometry across chapters that contain no floats at all.
        let needsFloatReflow = !box.inlineRuns.isEmpty
            && writingMode == .horizontal
            && box.lines.contains { line in
                fc?.intersectsExclusion(
                    y: blockOffsetY + line.top,
                    height: line.height
                ) == true
            }
        if needsFloatReflow {
            let lines = InlineLayout.layoutLines(
                runs: box.inlineRuns,
                maxWidth: box.contentSize.width,
                rootFontSize: rootFontSize,
                lineHeight: box.style.lineHeight,
                writingMode: writingMode,
                sourceText: sourceText,
                fontResolver: fontResolver,
                floatContext: fc,
                blockOffsetY: blockOffsetY
            )
            box.lines = lines
        }

        var minLineTop: CGFloat = 0
        for line in box.lines {
            cursorBlock = max(cursorBlock, line.top + line.height)
            minLineTop = min(minLineTop, line.top)
        }
        if minLineTop < 0 { cursorBlock -= minLineTop }

        // Block-level replaced element (image): its content box IS the image.
        if let attachment = box.imageAttachment {
            box.contentSize = attachment.usedSize
            switch writingMode {
            case .horizontal: cursorBlock = attachment.usedSize.height
            case .verticalRTL: cursorBlock = attachment.usedSize.width
            }
        }

        var totalHeight = cursorBlock
        if floatContext == nil, let fc = fc {
            totalHeight = max(totalHeight, fc.maxBottom)
        }

        box.contentSize.height = max(0, totalHeight)
        if case .px(let fixed) = box.style.height {
            box.contentSize.height = fixed
        }
        box.frame = ParentLocalRect(rawValue: CGRect(
            x: box.frame.rawValue.minX,
            y: box.frame.rawValue.minY,
            width: box.frame.rawValue.width,
            height: LogicalGeometry.blockAxisExtent(box.borders, mode: writingMode)
                + LogicalGeometry.blockAxisExtent(box.padding, mode: writingMode)
                + box.contentSize.height
        ))
        return box.contentSize.height
    }

    /// Resolves the used size of a replaced element against the containing block.
    /// Preserves aspect ratio when exactly one dimension is specified; clamps to
    /// `max-width`; `max-width: 100%` (the common EPUB rule) clamps to the container.
    static func resolveReplacedSize(
        intrinsic: CGSize,
        style: ComputedStyle,
        containerWidth: CGFloat,
        rootFontSize: CGFloat
    ) -> CGSize {
        let ctx = LayoutContext(rootFontSize: rootFontSize, percentBase: containerWidth)
        let widthSpec = resolve(style.width, style: style, ctx: ctx)
        let heightSpec = resolve(style.height, style: style, ctx: ctx)
        let maxWidth = style.maxWidth.flatMap { resolve($0, style: style, ctx: ctx) }

        var w: CGFloat
        var h: CGFloat
        switch (widthSpec, heightSpec) {
        case (.some(let ww), .some(let hh)):
            w = max(ww, 0)
            h = max(hh, 0)
        case (.some(let ww), nil):
            w = max(ww, 0)
            h = intrinsic.height > 0 ? w * intrinsic.height / intrinsic.width : 0
        case (nil, .some(let hh)):
            h = max(hh, 0)
            w = intrinsic.width > 0 ? h * intrinsic.width / intrinsic.height : 0
        default:
            w = intrinsic.width
            h = intrinsic.height
        }
        if let maxW = maxWidth, w > maxW {
            let scale = maxW / w
            w = maxW
            h *= scale
        }
        // Clamping to container width if intrinsically larger: CSS standard behavior.
        if containerWidth > 0 && w > containerWidth {
            let scale = containerWidth / w
            w = containerWidth
            h *= scale
        }
        return CGSize(width: max(w, 0), height: max(h, 0))
    }

    // MARK: - Sides resolution

    private struct Sides {
        var contentWidth: CGFloat
        var borderBoxWidth: CGFloat
        var margins = EdgeSizes.zero
        var padding = EdgeSizes.zero
        var borders = EdgeSizes.zero
    }

    private static func resolveSides(
        _ box: BlockBox,
        containerWidth: CGFloat,
        rootFontSize: CGFloat,
        writingMode: ReaderWritingMode
    ) -> Sides {
        let style = box.style
        let ctx = LayoutContext(rootFontSize: rootFontSize, percentBase: containerWidth)
        var s = Sides(contentWidth: 0, borderBoxWidth: 0)
        s.padding = EdgeSizes(
            top: resolve(style.paddingTop, style: style, ctx: ctx) ?? 0,
            right: resolve(style.paddingRight, style: style, ctx: ctx) ?? 0,
            bottom: resolve(style.paddingBottom, style: style, ctx: ctx) ?? 0,
            left: resolve(style.paddingLeft, style: style, ctx: ctx) ?? 0
        )
        s.borders = EdgeSizes(top: style.borderTopWidth, right: style.borderRightWidth, bottom: style.borderBottomWidth, left: style.borderLeftWidth)
        s.margins.top = resolve(style.marginTop, style: style, ctx: ctx) ?? 0
        s.margins.bottom = resolve(style.marginBottom, style: style, ctx: ctx) ?? 0

        let ml = resolve(style.marginLeft, style: style, ctx: ctx)
        let mr = resolve(style.marginRight, style: style, ctx: ctx)
        let marginTotalPad = s.padding.horizontal + s.borders.horizontal

        if let attachment = box.imageAttachment {
            s.contentWidth = attachment.usedSize.width
            s.margins.left = ml ?? 0
            s.margins.right = mr ?? 0
            s.borderBoxWidth = s.contentWidth + marginTotalPad
            return s
        }

        switch style.width {
        case .auto:
            let left = ml ?? 0
            let right = mr ?? 0
            s.contentWidth = max(containerWidth - marginTotalPad - left - right, 0)
            s.margins.left = left
            s.margins.right = right
        default:
            let width = resolve(style.width, style: style, ctx: ctx) ?? containerWidth
            let usedW = min(max(width, 0), containerWidth)
            if box.isFloated {
                s.margins.left = ml ?? 0
                s.margins.right = mr ?? 0
                s.contentWidth = usedW
            } else {
                let leftover = containerWidth - usedW - marginTotalPad - (ml ?? 0) - (mr ?? 0)
                switch (ml, mr) {
                case (.some(let l), .some(let r)):
                    s.margins.left = l; s.margins.right = r
                case (.none, .none):
                    s.margins.left = max(leftover / 2, 0); s.margins.right = max(leftover / 2, 0)
                case (.some(let l), .none):
                    s.margins.left = l; s.margins.right = max(leftover, 0)
                case (.none, .some(let r)):
                    s.margins.left = max(leftover, 0); s.margins.right = r
                }
                s.contentWidth = usedW
            }
        }

        // max-width clamps the used content width.
        if let maxW = style.maxWidth.flatMap({ resolve($0, style: style, ctx: ctx) }) {
            s.contentWidth = min(s.contentWidth, maxW)
        }
        s.borderBoxWidth = s.contentWidth + marginTotalPad
        return s
    }

    private static func resolve(_ length: CSSLength, style: ComputedStyle, ctx: LayoutContext) -> CGFloat? {
        CSSLengthResolver.resolve(length, emBase: style.fontSize, remBase: ctx.rootFontSize, percentBase: ctx.percentBase)
    }
}

enum Margins {
    /// CSS block-axis margin collapsing between adjoining margins:
    /// - both positive → the larger
    /// - both negative → the more negative
    /// - mixed signs → their sum
    static func collapse(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        if a >= 0 && b >= 0 { return max(a, b) }
        if a < 0 && b < 0 { return min(a, b) }
        return a + b
    }
}
