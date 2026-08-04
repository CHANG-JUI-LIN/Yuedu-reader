import CoreGraphics
import Foundation
import UIKit

struct LineRun {
    let range: NSRange                // into the chapter attributed string built by InlineLayout
    let x: CGFloat                    // left edge of the run within the line's content box
    let width: CGFloat
    let style: ComputedStyle
    let font: UIFont
}

struct LayoutLine {
    let runs: [LineRun]
    let height: CGFloat               // line-box height (line-height or ascent+descent)
    let ascent: CGFloat
    let descent: CGFloat
    let top: CGFloat                  // line-box top within the box's content box
    let baseline: CGFloat             // baseline Y within the box's content box
    let contentX: CGFloat             // left edge of the line content within the box's content box
}

enum BlockBoxType {
    case block
    case anonymous
}

/// A block box. `frame` is the border-box, origin relative to its parent's content box.
/// `contentSize` is the content box. Margin collapsing between siblings/parents is applied
/// during layout in `BlockLayout`.
final class BlockBox {
    let style: ComputedStyle
    let boxType: BlockBoxType
    var children: [BlockBox]
    var lines: [LayoutLine]
    var frame = CGRect.zero
    var contentSize = CGSize.zero
    var margins = EdgeSizes.zero
    var padding = EdgeSizes.zero
    var borders = EdgeSizes.zero

    init(style: ComputedStyle, boxType: BlockBoxType = .block, children: [BlockBox] = [], lines: [LayoutLine] = []) {
        self.style = style
        self.boxType = boxType
        self.children = children
        self.lines = lines
    }

    /// Border-box width (content + padding + border).
    var borderBoxWidth: CGFloat { padding.horizontal + borders.horizontal + contentSize.width }
}

struct LayoutContext {
    let rootFontSize: CGFloat
    let percentBase: CGFloat
    init(rootFontSize: CGFloat, percentBase: CGFloat) {
        self.rootFontSize = rootFontSize
        self.percentBase = percentBase
    }
}
