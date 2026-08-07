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
        writingMode: ReaderWritingMode = .horizontal
    ) -> CGFloat {
        let sides = resolveSides(box, containerWidth: containerWidth, rootFontSize: rootFontSize, writingMode: writingMode)
        box.margins = sides.margins
        box.padding = sides.padding
        box.borders = sides.borders
        box.contentSize.width = sides.contentWidth
        // Frame is physical; its width is the inline-axis extent of the box.
        box.frame = ParentLocalRect(rawValue: CGRect(x: 0, y: 0, width: sides.borderBoxWidth, height: 0))

        var cursorBlock: CGFloat = 0   // content-box-relative, along block axis
        var previousBlockEndMargin: CGFloat? = nil

        for child in box.children {
            let childContentHeight = layOut(
                root: child,
                containerWidth: box.contentSize.width,
                rootFontSize: rootFontSize,
                writingMode: writingMode
            )
            // Logical access: block-start/block-end margins, inline-start edge.
            let childMarginBlockStart = LogicalGeometry.blockStart(edge: child.margins, mode: writingMode)
            let childMarginBlockEnd = LogicalGeometry.blockEnd(edge: child.margins, mode: writingMode)
            let childMarginInlineStart = LogicalGeometry.inlineStart(edge: child.margins, mode: writingMode)
            let collapsedTop: CGFloat
            if let prev = previousBlockEndMargin {
                collapsedTop = Margins.collapse(prev, childMarginBlockStart)
                // Block-axis position: cursor at the previous child's block-end,
                // collapsed margin folded in (sibling margin collapse).
                child.logicalBlockOrigin = cursorBlock - prev + collapsedTop
            } else if LogicalGeometry.blockStart(edge: box.borders, mode: writingMode) == 0
                        && LogicalGeometry.blockStart(edge: box.padding, mode: writingMode) == 0 {
                // First child's block-start margin collapses into the box's own
                // block-start margin (CSS: adjacent margins collapse to max()).
                // Record the folded margin on the box so the fragment walker can
                // honor it when the box is the root (whose frame origin is fixed).
                collapsedTop = childMarginBlockStart
                child.logicalBlockOrigin = 0
                box.margins.top = max(box.margins.top, collapsedTop)
            } else {
                collapsedTop = childMarginBlockStart
                child.logicalBlockOrigin = cursorBlock + childMarginBlockStart
            }
            // Inline-axis position: child sits at the inline-start edge.
            child.logicalInlineOrigin = childMarginInlineStart

            // Border-box extent along the block axis: border+padding (block
            // axis) + content height. `childContentHeight` is already a
            // block-axis extent (returned by layOut above).
            let borderBoxBlockExtent = LogicalGeometry.blockAxisExtent(child.borders, mode: writingMode)
                + LogicalGeometry.blockAxisExtent(child.padding, mode: writingMode)
                + childContentHeight

            // Store physical frame: for horizontal, x=inline, y=block; for
            // vertical-rl, x=block (right→left), y=inline (top→bottom).
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
                // Block axis runs right→left: larger block offset = further left.
                // Origin is relative to the parent content box; position is
                // measured from the RIGHT content edge.
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
        }
        if box.lines.isEmpty, let last = previousBlockEndMargin,
           LogicalGeometry.blockEnd(edge: box.borders, mode: writingMode) == 0,
           LogicalGeometry.blockEnd(edge: box.padding, mode: writingMode) == 0 {
            // Last-child block-end margin collapses into the box's own
            // block-end margin (the box's content extent excludes it).
            cursorBlock -= last
        }
        // A line box may start ABOVE the block's content top (a tall inline
        // image's top strip overflows upward by its descent). The block's
        // content extent must therefore cover [minLineTop, lineBottom] — i.e.
        // flow position = last line-box bottom, PLUS the negative top offset
        // of the highest line box (CSS 2.1 §10.8: the line box is sized to
        // contain its inline boxes; a block containing such a line must not
        // report a content height smaller than the image).
        var minLineTop: CGFloat = 0
        for line in box.lines {
            cursorBlock = max(cursorBlock, line.top + line.height)
            minLineTop = min(minLineTop, line.top)
        }
        if minLineTop < 0 { cursorBlock -= minLineTop }

        // Block-level replaced element (image): its content box IS the image.
        if let attachment = box.imageAttachment {
            box.contentSize = attachment.usedSize
            // Block-axis extent of the image: its height for horizontal, width
            // for vertical-rl (the inline and block axes swap).
            switch writingMode {
            case .horizontal: cursorBlock = attachment.usedSize.height
            case .verticalRTL: cursorBlock = attachment.usedSize.width
            }
        }

        box.contentSize.height = max(0, cursorBlock)
        if case .px(let fixed) = box.style.height {
            // CSS height stays physical; for horizontal it is the block extent,
            // for vertical-rl the inline extent — the mapper decides.
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
        case (nil, nil):
            w = intrinsic.width
            h = intrinsic.height
        }
        if let maxW = maxWidth {
            if w > maxW {
                let scaled = maxW / (w > 0 ? w : 1)
                w = maxW
                h = h * scaled
            }
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

        // The containing-block inline size: `containerWidth` is physical width,
        // which IS the inline extent for horizontal and the BLOCK extent for
        // vertical-rl. The usable inline extent for a vertical-rl box is the
        // container's physical HEIGHT — but the legacy pipeline only ever passes
        // width here. Phase 3B threads the physical height through; for now the
        // mapper keeps horizontal behavior identical and vertical uses the same
        // measurement path (refined in 3B when the engine passes real heights).
        let ml = resolve(style.marginLeft, style: style, ctx: ctx)
        let mr = resolve(style.marginRight, style: style, ctx: ctx)
        let marginTotalPad = s.padding.horizontal + s.borders.horizontal

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
