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
    /// DOM identity of the replaced element.
    ///
    /// An INLINE image is emitted as a `LineRun`, which carries its own
    /// nodeID/linkTarget, so these duplicate it. A BLOCK-level image has no run:
    /// it becomes `BlockBox.imageAttachment`, and the attachment is the only
    /// thing the page walker sees. Without them, `<a href="…"><img
    /// style="display:block"></a>` reached the page as an image with no link at
    /// all — which is why an illustration wrapped in an anchor rendered but
    /// could not be tapped.
    let nodeID: Int
    let linkTarget: String?

    init(
        source: String,
        image: UIImage,
        usedSize: CGSize,
        nodeID: Int = -1,
        linkTarget: String? = nil
    ) {
        self.source = source
        self.image = image
        self.usedSize = usedSize
        self.nodeID = nodeID
        self.linkTarget = linkTarget
    }
}

/// One run of inline content inside a line box. `sourceRange` points into the
/// chapter's `sourceText` (see `BrowserLayoutDocument`) — concatenating line-run
/// ranges in document order reassembles the visible text.
/// Non-inherited paint/edge ownership survives flattening nested inline nodes.
struct InlineDecoration {
    let nodeID: Int
    let style: ComputedStyle
    let sourceRange: NSRange
}

struct InlineLineDecoration {
    /// X is relative to line.contentX; Y is relative to the block content top.
    var rect: CGRect
    let owner: InlineDecoration
    let paintsStartEdge: Bool
    let paintsEndEdge: Bool
}

struct LineRun {
    let sourceRange: NSRange
    let shapedRange: NSRange?
    let x: CGFloat                    // left edge of the run within the line's content box
    let width: CGFloat
    let style: ComputedStyle
    let font: UIFont
    let nodeID: Int
    let linkTarget: String?
    let atomic: AtomicInline?         // non-nil = replaced element run (image)
    let ruby: RubyBox?
    var inlineDecorations: [InlineDecoration] = []
    var isDecorationEdge = false

    init(
        sourceRange: NSRange,
        shapedRange: NSRange? = nil,
        x: CGFloat,
        width: CGFloat,
        style: ComputedStyle,
        font: UIFont,
        nodeID: Int,
        linkTarget: String?,
        atomic: AtomicInline?,
        ruby: RubyBox? = nil
    ) {
        self.sourceRange = sourceRange
        self.shapedRange = shapedRange ?? sourceRange
        self.x = x
        self.width = width
        self.style = style
        self.font = font
        self.nodeID = nodeID
        self.linkTarget = linkTarget
        self.atomic = atomic
        self.ruby = ruby
    }
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
    var inlineDecorations: [InlineLineDecoration] = []
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
    /// Post-layout output. This must remain empty after BoxTreeBuilder and is
    /// populated only by BlockLayout through InlineLayout. PageWalker consumes
    /// it only after BlockLayout has completed the tree.
    var lines: [LayoutLine]
    /// Immutable inline-formatting input after BoxTreeBuilder completes.
    var inlineRuns: [InlineRun] = []
    /// Whether this internal inline formatting context consumes its DOM block
    /// container's first formatted line. Mixed inline/block content can create
    /// multiple internal boxes; only the first visible group owns text-indent.
    /// This is ownership metadata only — BoxTreeBuilder never shapes content.
    var ownsFirstFormattedLine: Bool
    /// Non-nil when this box IS a replaced element (block-level image).
    var imageAttachment: AtomicInline? = nil
    /// Border-box rect in PARENT content-local coordinates (Phase 2C contract).
    var frame: ParentLocalRect = .zero
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
    /// DOM identity for diagnostics (tag/class/id). Layout never reads these.
    var debugTag: String = ""
    var debugClasses: [String] = []
    var debugID: String?
    /// Debug-only: the owning style-node id (fragment nodeID correlation).
    var debugNodeID: Int = -1
    /// Debug-only: weak parent link for ancestry walks (never used by layout).
    weak var parentBox: BlockBox?
    /// Debug-only: cached document-absolute origin (set by diagnostics).
    var documentOrigin: CGPoint = .zero

    var isFloated: Bool {
        style.cssFloat == .left || style.cssFloat == .right
    }

    init(
        style: ComputedStyle,
        boxType: BlockBoxType = .block,
        children: [BlockBox] = [],
        lines: [LayoutLine] = [],
        inlineRuns: [InlineRun] = [],
        ownsFirstFormattedLine: Bool = true
    ) {
        self.style = style
        self.boxType = boxType
        self.children = children
        self.lines = lines
        self.inlineRuns = inlineRuns
        self.ownsFirstFormattedLine = ownsFirstFormattedLine
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
