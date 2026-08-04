import CoreGraphics
import UIKit

/// One-pass block formatting: resolves used widths/margins/paddings and stacks children
/// vertically. `containerWidth` is the parent's *content* width.
enum BlockLayout {

    /// Lays out `box` and all descendants; returns the box's content-box height.
    /// `rootFontSize` is the chapter's root font size — the rem base (never the
    /// current element's font size).
    @discardableResult
    static func layOut(root box: BlockBox, containerWidth: CGFloat, rootFontSize: CGFloat = 17) -> CGFloat {
        let sides = resolveSides(box, containerWidth: containerWidth, rootFontSize: rootFontSize)
        box.margins = sides.margins
        box.padding = sides.padding
        box.borders = sides.borders
        box.contentSize.width = sides.contentWidth
        box.frame = CGRect(x: 0, y: 0, width: sides.borderBoxWidth, height: 0)

        var cursorY: CGFloat = box.borders.top + box.padding.top
        var previousBottomMargin: CGFloat? = nil
        var previousChild: BlockBox? = nil

        for child in box.children {
            let childContentHeight = layOut(root: child, containerWidth: box.contentSize.width, rootFontSize: rootFontSize)
            let collapsedTop: CGFloat
            if let prev = previousBottomMargin {
                collapsedTop = Margins.collapse(prev, child.margins.top)
                child.frame.origin.y = max(cursorY, cursorY - prev + collapsedTop)
            } else if box.borders.top == 0 && box.padding.top == 0 {
                collapsedTop = child.margins.top   // folds into the box's own top margin
                child.frame.origin.y = 0
            } else {
                collapsedTop = child.margins.top
                child.frame.origin.y = cursorY
            }
            child.frame.origin.x = child.margins.left
            let borderBoxH = child.borders.vertical + child.padding.vertical + childContentHeight
            child.frame.size = CGSize(width: child.borderBoxWidth, height: borderBoxH)
            cursorY = child.frame.maxY + child.margins.bottom
            previousBottomMargin = child.margins.bottom
            previousChild = child
        }
        if box.lines.isEmpty, let last = previousChild, box.borders.bottom == 0, box.padding.bottom == 0 {
            // Last-child bottom margin collapses into the box's own bottom margin
            // (i.e. the box's content height excludes the child's bottom margin).
            cursorY -= last.margins.bottom
        }
        for line in box.lines { cursorY += line.height }

        // Block-level replaced element (image): its content box IS the image.
        if let attachment = box.imageAttachment {
            box.contentSize = attachment.usedSize
            cursorY = box.borders.top + box.padding.top + attachment.usedSize.height
        }

        box.contentSize.height = max(0, cursorY - box.borders.top - box.padding.top)
        if case .px(let fixed) = box.style.height { box.contentSize.height = fixed }
        box.frame.size.height = box.borders.vertical + box.padding.vertical + box.contentSize.height
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

    private static func resolveSides(_ box: BlockBox, containerWidth: CGFloat, rootFontSize: CGFloat) -> Sides {
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
    /// CSS top/bottom margin collapsing between adjoining margins:
    /// - both positive → the larger
    /// - both negative → the more negative
    /// - mixed signs → their sum
    static func collapse(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        if a >= 0 && b >= 0 { return max(a, b) }
        if a < 0 && b < 0 { return min(a, b) }
        return a + b
    }
}
