import CoreGraphics
import UIKit

/// One-pass block formatting: resolves used widths/margins/paddings and stacks children
/// vertically. `containerWidth` is the parent's *content* width.
enum BlockLayout {

    /// Lays out `box` and all descendants; returns the box's content-box height.
    @discardableResult
    static func layOut(root box: BlockBox, containerWidth: CGFloat) -> CGFloat {
        let sides = resolveSides(box, containerWidth: containerWidth)
        box.margins = sides.margins
        box.padding = sides.padding
        box.borders = sides.borders
        box.contentSize.width = sides.contentWidth
        box.frame = CGRect(x: 0, y: 0, width: sides.borderBoxWidth, height: 0)

        var cursorY: CGFloat = box.borders.top + box.padding.top
        var previousBottomMargin: CGFloat? = nil
        var previousChild: BlockBox? = nil

        for child in box.children {
            let childContentHeight = layOut(root: child, containerWidth: box.contentSize.width)
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

        box.contentSize.height = max(0, cursorY - box.borders.top - box.padding.top)
        if case .px(let fixed) = box.style.height { box.contentSize.height = fixed }
        box.frame.size.height = box.borders.vertical + box.padding.vertical + box.contentSize.height
        return box.contentSize.height
    }

    // MARK: - Sides resolution

    private struct Sides {
        var contentWidth: CGFloat
        var borderBoxWidth: CGFloat
        var margins = EdgeSizes.zero
        var padding = EdgeSizes.zero
        var borders = EdgeSizes.zero
    }

    private static func resolveSides(_ box: BlockBox, containerWidth: CGFloat) -> Sides {
        let style = box.style
        var s = Sides(contentWidth: 0, borderBoxWidth: 0)
        s.padding = EdgeSizes(
            top: len(style.paddingTop, style: style, percent: containerWidth) ?? 0,
            right: len(style.paddingRight, style: style, percent: containerWidth) ?? 0,
            bottom: len(style.paddingBottom, style: style, percent: containerWidth) ?? 0,
            left: len(style.paddingLeft, style: style, percent: containerWidth) ?? 0
        )
        s.borders = EdgeSizes(top: style.borderTopWidth, right: style.borderRightWidth, bottom: style.borderBottomWidth, left: style.borderLeftWidth)
        s.margins.top = len(style.marginTop, style: style, percent: containerWidth) ?? 0
        s.margins.bottom = len(style.marginBottom, style: style, percent: containerWidth) ?? 0

        let ml = len(style.marginLeft, style: style, percent: containerWidth)
        let mr = len(style.marginRight, style: style, percent: containerWidth)
        let marginTotalPad = s.padding.horizontal + s.borders.horizontal

        switch style.width {
        case .auto:
            let left = ml ?? 0
            let right = mr ?? 0
            s.contentWidth = max(containerWidth - marginTotalPad - left - right, 0)
            s.margins.left = left
            s.margins.right = right
        default:
            let width = len(style.width, style: style, percent: containerWidth) ?? containerWidth
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
        s.borderBoxWidth = s.contentWidth + marginTotalPad
        return s
    }

    private static func len(_ length: CSSLength, style: ComputedStyle, percent: CGFloat) -> CGFloat? {
        CSSLengthResolver.resolve(length, emBase: style.fontSize, remBase: style.fontSize, percentBase: percent)
    }
}

enum Margins {
    static func collapse(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        max(a, b)
    }
}
