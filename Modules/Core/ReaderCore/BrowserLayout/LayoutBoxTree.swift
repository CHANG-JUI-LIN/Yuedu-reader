import CoreGraphics
import CoreText
import Foundation
import UIKit

/// A replaced element (Phase 1.5: images only). `usedSize` is the final laid-out
/// size after CSS width/height/max-width resolution; intrinsic aspect is preserved.
struct AtomicInline {
    let source: String
    let image: UIImage
    let usedSize: CGSize
}

/// One run of inline content inside a line box. `sourceRange` points into the
/// chapter's `sourceText` (see `BrowserLayoutDocument`) — concatenating line-run
/// ranges in document order reassembles the visible text.
struct LineRun {
    let sourceRange: NSRange
    let x: CGFloat                    // left edge of the run within the line's content box
    let width: CGFloat
    let style: ComputedStyle
    let font: UIFont
    let nodeID: Int
    let linkTarget: String?
    let atomic: AtomicInline?         // non-nil = replaced element run (image)
}

struct LayoutLine {
    let runs: [LineRun]
    let height: CGFloat               // line-box height (line-height or ascent+descent)
    let ascent: CGFloat
    let descent: CGFloat
    let top: CGFloat                  // line-box top within the box's content box
    let baseline: CGFloat             // baseline Y within the box's content box
    let contentX: CGFloat             // left edge of the line content within the box's content box
    /// The shaped line covering this line's full (untrimmed) range, retained
    /// for precise string-index → typographic-offset mapping (kerning,
    /// ligatures, RTL, emoji clusters). Nil when unavailable.
    let ctLine: CTLine?
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
    /// Non-nil when this box IS a replaced element (block-level image).
    var imageAttachment: AtomicInline? = nil
    var frame = CGRect.zero
    var contentSize = CGSize.zero
    var margins = EdgeSizes.zero
    var padding = EdgeSizes.zero
    var borders = EdgeSizes.zero
    /// Logical block-axis origin within the parent's content box (Phase 3A).
    /// For horizontal this equals frame.minY; for vertical-rl it is the
    /// distance from the parent's block-start (right edge).
    var logicalBlockOrigin: CGFloat = 0
    /// Logical inline-axis origin within the parent's content box (Phase 3A).
    var logicalInlineOrigin: CGFloat = 0

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
