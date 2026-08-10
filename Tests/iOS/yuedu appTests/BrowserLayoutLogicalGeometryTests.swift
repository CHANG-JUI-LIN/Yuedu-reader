import Testing
import UIKit
@testable import yuedu_app

/// Phase 3A: logical geometry contract. The mapping between logical
/// (inline/block) coordinates and physical (UIKit/CoreGraphics) coordinates
/// must match the writing-mode spec:
/// - horizontalTB: inline = x (left→right), block = y (top→bottom)
/// - verticalRL:   inline = y (top→bottom), block = x (right→left)
@MainActor
struct BrowserLayoutLogicalGeometryTests {

    // MARK: - horizontalTB

    @Test func horizontalIdentityMapping() {
        let logical = LogicalRect(
            origin: LogicalPoint(inline: 10, block: 20),
            size: LogicalSize(inline: 100, block: 40)
        )
        let physical = LogicalGeometry.physicalRect(
            logical, mode: .horizontal, containerBlockExtent: 300
        )
        #expect(physical == CGRect(x: 10, y: 20, width: 100, height: 40))

        let roundTrip = LogicalGeometry.logicalRect(
            physical, mode: .horizontal, containerBlockExtent: 300
        )
        #expect(roundTrip == logical)
    }

    @Test func horizontalBlockAxisIsTopToBottom() {
        #expect(LogicalGeometry.blockStart(edge: EdgeSizes(top: 1, right: 2, bottom: 3, left: 4), mode: .horizontal) == 1)
        #expect(LogicalGeometry.blockEnd(edge: EdgeSizes(top: 1, right: 2, bottom: 3, left: 4), mode: .horizontal) == 3)
        #expect(LogicalGeometry.inlineStart(edge: EdgeSizes(top: 1, right: 2, bottom: 3, left: 4), mode: .horizontal) == 4)
        #expect(LogicalGeometry.inlineEnd(edge: EdgeSizes(top: 1, right: 2, bottom: 3, left: 4), mode: .horizontal) == 2)
    }

    // MARK: - verticalRL

    @Test func verticalInlineAxisIsTopToBottom() {
        // In vertical-rl, a logical inline position maps to physical Y.
        let logical = LogicalRect(
            origin: LogicalPoint(inline: 30, block: 50),
            size: LogicalSize(inline: 60, block: 120)
        )
        let physical = LogicalGeometry.physicalRect(
            logical, mode: .verticalRTL, containerBlockExtent: 300
        )
        // inline 30 → y 30; block 50 with size 120 → x = 300 - 50 - 120 = 130
        #expect(physical == CGRect(x: 130, y: 30, width: 120, height: 60))
    }

    @Test func verticalBlockAxisIsRightToLeft() {
        // block offset 0 (block-start) sits at the container's right edge.
        let start = LogicalRect(
            origin: LogicalPoint(inline: 0, block: 0),
            size: LogicalSize(inline: 100, block: 20)
        )
        let physicalStart = LogicalGeometry.physicalRect(
            start, mode: .verticalRTL, containerBlockExtent: 300
        )
        #expect(physicalStart.maxX == 300)  // right edge

        // block offset 280 with block size 20 (280 + 20 = 300) sits at the
        // container's left edge (block-end).
        let end = LogicalRect(
            origin: LogicalPoint(inline: 0, block: 280),
            size: LogicalSize(inline: 100, block: 20)
        )
        let physicalEnd = LogicalGeometry.physicalRect(
            end, mode: .verticalRTL, containerBlockExtent: 300
        )
        #expect(physicalEnd.minX == 0)  // left edge
    }

    @Test func verticalPhysicalToLogicalRoundTrip() {
        let physical = CGRect(x: 130, y: 30, width: 120, height: 60)
        let logical = LogicalGeometry.logicalRect(
            physical, mode: .verticalRTL, containerBlockExtent: 300
        )
        #expect(logical == LogicalRect(
            origin: LogicalPoint(inline: 30, block: 50),
            size: LogicalSize(inline: 60, block: 120)
        ))
        let back = LogicalGeometry.physicalRect(
            logical, mode: .verticalRTL, containerBlockExtent: 300
        )
        #expect(back == physical)
    }

    @Test func verticalEdgeMapping() {
        // CSS physical edges → logical roles in vertical-rl:
        // block-start = right, block-end = left, inline-start = top, inline-end = bottom.
        let e = EdgeSizes(top: 1, right: 2, bottom: 3, left: 4)
        #expect(LogicalGeometry.blockStart(edge: e, mode: .verticalRTL) == 2)
        #expect(LogicalGeometry.blockEnd(edge: e, mode: .verticalRTL) == 4)
        #expect(LogicalGeometry.inlineStart(edge: e, mode: .verticalRTL) == 1)
        #expect(LogicalGeometry.inlineEnd(edge: e, mode: .verticalRTL) == 3)
        #expect(LogicalGeometry.blockAxisExtent(e, mode: .verticalRTL) == 6)
        #expect(LogicalGeometry.inlineAxisExtent(e, mode: .verticalRTL) == 4)
    }

    @Test func verticalStyleLengthMapping() {
        var style = ComputedStyle()
        style.marginTop = .px(1); style.marginRight = .px(2)
        style.marginBottom = .px(3); style.marginLeft = .px(4)
        style.paddingTop = .px(11); style.paddingRight = .px(12)
        style.paddingBottom = .px(13); style.paddingLeft = .px(14)

        #expect(LogicalGeometry.blockStartLength(style: style, mode: .verticalRTL) == .px(2))
        #expect(LogicalGeometry.blockEndLength(style: style, mode: .verticalRTL) == .px(4))
        #expect(LogicalGeometry.inlineStartLength(style: style, mode: .verticalRTL) == .px(1))
        #expect(LogicalGeometry.inlineEndLength(style: style, mode: .verticalRTL) == .px(3))

        #expect(LogicalGeometry.paddingBlockStart(style: style, mode: .verticalRTL) == .px(12))
        #expect(LogicalGeometry.paddingBlockEnd(style: style, mode: .verticalRTL) == .px(14))
        #expect(LogicalGeometry.paddingInlineStart(style: style, mode: .verticalRTL) == .px(11))
        #expect(LogicalGeometry.paddingInlineEnd(style: style, mode: .verticalRTL) == .px(13))
    }

    // MARK: - Edge cases

    @Test func zeroSizeMapsToContainerEdge() {
        let zero = LogicalRect(origin: .zero, size: .zero)
        let physical = LogicalGeometry.physicalRect(
            zero, mode: .verticalRTL, containerBlockExtent: 300
        )
        #expect(physical == CGRect(x: 300, y: 0, width: 0, height: 0))
    }
}
