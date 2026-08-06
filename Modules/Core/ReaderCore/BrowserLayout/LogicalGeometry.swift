import CoreGraphics
import Foundation

/// Writing mode enum — the single source of truth for axis mapping across the
/// browser layout engine. Phase 3A: all core layout algorithms (block layout,
/// inline layout, page walker, margin collapsing, atomic boxes, fragmentation)
/// operate on LOGICAL coordinates and never assume horizontal flow directly.
///
/// Reuses `ReaderWritingMode` (the app-wide typealias `WritingMode` in
/// CoreTextCommon) so the browser engine and the legacy renderer share ONE
/// writing-mode vocabulary — no parallel enum, one path per concern.
/// `.horizontal` = horizontalTB, `.verticalRTL` = vertical-rl.

/// Logical size: `inline` is the inline axis extent (left→right for
/// horizontalTB, top→bottom for verticalRL), `block` is the block axis extent
/// (top→bottom for horizontalTB, right→left for verticalRL).
struct LogicalSize: Equatable {
    var inline: CGFloat
    var block: CGFloat

    static let zero = LogicalSize(inline: 0, block: 0)
}

/// Logical point: distance from the inline-start / block-start edges.
struct LogicalPoint: Equatable {
    var inline: CGFloat
    var block: CGFloat

    static let zero = LogicalPoint(inline: 0, block: 0)
}

/// Logical rect: origin in logical coordinates, size in logical extents.
struct LogicalRect: Equatable {
    var origin: LogicalPoint
    var size: LogicalSize

    static let zero = LogicalRect(origin: .zero, size: .zero)

    var minInline: CGFloat { origin.inline }
    var maxInline: CGFloat { origin.inline + size.inline }
    var minBlock: CGFloat { origin.block }
    var maxBlock: CGFloat { origin.block + size.block }

    func offsetBy(inline di: CGFloat, block db: CGFloat) -> LogicalRect {
        LogicalRect(origin: LogicalPoint(inline: origin.inline + di, block: origin.block + db), size: size)
    }
}

/// Axis mapper: converts logical coordinates to/from physical UIKit/CoreGraphics
/// coordinates. Conversion to physical geometry is ONLY allowed at the
/// boundaries: DisplayList emission, CGContext drawing, hit testing, and debug
/// snapshot/export.
///
/// Physical → logical and logical → physical mappings:
/// - horizontalTB: inline = x (left→right), block = y (top→bottom)
/// - verticalRL:   inline = y (top→bottom), block = x (right→left)
struct LogicalGeometry {

    /// Physical size the logical size occupies.
    static func physicalSize(_ logical: LogicalSize, mode: WritingMode) -> CGSize {
        switch mode {
        case .horizontal:
            return CGSize(width: logical.inline, height: logical.block)
        case .verticalRTL:
            return CGSize(width: logical.block, height: logical.inline)
        }
    }

    /// Physical rect for a logical rect inside a container whose block extent
    /// (width for vertical-rl) is `containerBlockExtent`. The container's
    /// physical origin is (0, 0).
    static func physicalRect(
        _ logical: LogicalRect,
        mode: WritingMode,
        containerBlockExtent: CGFloat
    ) -> CGRect {
        switch mode {
        case .horizontal:
            return CGRect(
                x: logical.origin.inline,
                y: logical.origin.block,
                width: logical.size.inline,
                height: logical.size.block
            )
        case .verticalRTL:
            // block axis runs right→left: block offset 0 sits at the container's
            // right edge; the origin x = containerWidth − blockStart − blockSize.
            let x = containerBlockExtent - logical.origin.block - logical.size.block
            return CGRect(
                x: x,
                y: logical.origin.inline,
                width: logical.size.block,
                height: logical.size.inline
            )
        }
    }

    /// Logical rect for a physical rect inside a container whose block extent
    /// is `containerBlockExtent`. Inverse of `physicalRect`.
    static func logicalRect(
        _ physical: CGRect,
        mode: WritingMode,
        containerBlockExtent: CGFloat
    ) -> LogicalRect {
        switch mode {
        case .horizontal:
            return LogicalRect(
                origin: LogicalPoint(inline: physical.minX, block: physical.minY),
                size: LogicalSize(inline: physical.width, block: physical.height)
            )
        case .verticalRTL:
            let block = containerBlockExtent - physical.maxX
            return LogicalRect(
                origin: LogicalPoint(inline: physical.minY, block: block),
                size: LogicalSize(inline: physical.height, block: physical.width)
            )
        }
    }

    /// Physical offset for a logical point (size zero).
    static func physicalPoint(
        _ logical: LogicalPoint,
        mode: WritingMode,
        containerBlockExtent: CGFloat
    ) -> CGPoint {
        switch mode {
        case .horizontal:
            return CGPoint(x: logical.inline, y: logical.block)
        case .verticalRTL:
            return CGPoint(x: containerBlockExtent - logical.block, y: logical.inline)
        }
    }

    /// Maps a physical CSS edge (top/right/bottom/left) to its block-axis role.
    /// CSS width/height and physical-direction margins/paddings KEEP their
    /// physical semantics; the writing-mode mapper turns them into the logical
    /// sizes the layout uses. Never treat `width` as inline-size directly.
    static func blockStart(edge: EdgeSizes, mode: WritingMode) -> CGFloat {
        switch mode {
        case .horizontal: return edge.top
        case .verticalRTL:   return edge.right
        }
    }

    static func blockEnd(edge: EdgeSizes, mode: WritingMode) -> CGFloat {
        switch mode {
        case .horizontal: return edge.bottom
        case .verticalRTL:   return edge.left
        }
    }

    static func inlineStart(edge: EdgeSizes, mode: WritingMode) -> CGFloat {
        switch mode {
        case .horizontal: return edge.left
        case .verticalRTL:   return edge.top
        }
    }

    static func inlineEnd(edge: EdgeSizes, mode: WritingMode) -> CGFloat {
        switch mode {
        case .horizontal: return edge.right
        case .verticalRTL:   return edge.bottom
        }
    }

    /// The combined block-axis extent (block-start + block-end) of an edge set.
    static func blockAxisExtent(_ edge: EdgeSizes, mode: WritingMode) -> CGFloat {
        switch mode {
        case .horizontal: return edge.vertical
        case .verticalRTL:   return edge.horizontal
        }
    }

    /// The combined inline-axis extent (inline-start + inline-end) of an edge set.
    static func inlineAxisExtent(_ edge: EdgeSizes, mode: WritingMode) -> CGFloat {
        switch mode {
        case .horizontal: return edge.horizontal
        case .verticalRTL:   return edge.vertical
        }
    }

    /// Maps a physical CSS length property (e.g. `marginTop`) to the
    /// block-axis (block-start) or inline-axis (inline-start) accessor.
    static func blockStartLength(style: ComputedStyle, mode: WritingMode) -> CSSLength {
        switch mode {
        case .horizontal: return style.marginTop
        case .verticalRTL:   return style.marginRight
        }
    }

    static func blockEndLength(style: ComputedStyle, mode: WritingMode) -> CSSLength {
        switch mode {
        case .horizontal: return style.marginBottom
        case .verticalRTL:   return style.marginLeft
        }
    }

    static func inlineStartLength(style: ComputedStyle, mode: WritingMode) -> CSSLength {
        switch mode {
        case .horizontal: return style.marginLeft
        case .verticalRTL:   return style.marginTop
        }
    }

    static func inlineEndLength(style: ComputedStyle, mode: WritingMode) -> CSSLength {
        switch mode {
        case .horizontal: return style.marginRight
        case .verticalRTL:   return style.marginBottom
        }
    }

    static func paddingBlockStart(style: ComputedStyle, mode: WritingMode) -> CSSLength {
        switch mode {
        case .horizontal: return style.paddingTop
        case .verticalRTL:   return style.paddingRight
        }
    }

    static func paddingBlockEnd(style: ComputedStyle, mode: WritingMode) -> CSSLength {
        switch mode {
        case .horizontal: return style.paddingBottom
        case .verticalRTL:   return style.paddingLeft
        }
    }

    static func paddingInlineStart(style: ComputedStyle, mode: WritingMode) -> CSSLength {
        switch mode {
        case .horizontal: return style.paddingLeft
        case .verticalRTL:   return style.paddingTop
        }
    }

    static func paddingInlineEnd(style: ComputedStyle, mode: WritingMode) -> CSSLength {
        switch mode {
        case .horizontal: return style.paddingRight
        case .verticalRTL:   return style.paddingBottom
        }
    }
}
