import CoreGraphics
import Foundation

/// An active float exclusion in containing-block content coordinates.
struct ActiveFloat: Equatable {
    let side: CSSFloat               // .left or .right
    let marginBox: CGRect            // Outer bounding box including margins, in container content coordinates
    let borderBox: CGRect            // Border box (frame in container content coordinates)
    let nodeID: Int
    let clear: CSSClear

    var top: CGFloat { marginBox.minY }
    var bottom: CGFloat { marginBox.maxY }
    var left: CGFloat { marginBox.minX }
    var right: CGFloat { marginBox.maxX }
}

/// Interval of available horizontal space for an inline line band or float placement.
struct InlineInterval: Equatable {
    let lineX: CGFloat               // Start x in containing-block content coordinates (e.g. leftIntrusion)
    let lineWidth: CGFloat           // Usable inline width
    let leftIntrusion: CGFloat       // Width occupied by active left floats
    let rightIntrusion: CGFloat      // Width occupied by active right floats
}

/// Manages active float exclusions and clearance calculations within a block formatting context.
final class FloatContext {
    private(set) var activeFloats: [ActiveFloat] = []
    let containerWidth: CGFloat

    init(containerWidth: CGFloat) {
        self.containerWidth = max(0, containerWidth)
    }

    /// Queries the available horizontal interval for a vertical band [y, y + height].
    func availableInterval(y: CGFloat, height: CGFloat) -> InlineInterval {
        guard !activeFloats.isEmpty else {
            return InlineInterval(lineX: 0, lineWidth: containerWidth, leftIntrusion: 0, rightIntrusion: 0)
        }

        let bandTop = y
        let bandBottom = y + max(height, 0.1)

        var maxLeftX: CGFloat = 0
        var maxRightIntrusion: CGFloat = 0

        for float in activeFloats {
            // Check vertical overlap between the float's margin box and the query band
            if float.top < bandBottom && float.bottom > bandTop {
                if float.side == .left {
                    maxLeftX = max(maxLeftX, float.marginBox.maxX)
                } else if float.side == .right {
                    let intrusion = containerWidth - float.marginBox.minX
                    maxRightIntrusion = max(maxRightIntrusion, intrusion)
                }
            }
        }

        let leftIntrusion = max(0, min(maxLeftX, containerWidth))
        let rightIntrusion = max(0, min(maxRightIntrusion, containerWidth - leftIntrusion))
        let availableWidth = max(0, containerWidth - leftIntrusion - rightIntrusion)

        return InlineInterval(
            lineX: leftIntrusion,
            lineWidth: availableWidth,
            leftIntrusion: leftIntrusion,
            rightIntrusion: rightIntrusion
        )
    }

    /// Whether a vertical line band intersects any active float exclusion.
    /// Keeping this check here ensures BlockLayout uses the same half-open
    /// overlap rule as the interval calculation itself.
    func intersectsExclusion(y: CGFloat, height: CGFloat) -> Bool {
        let interval = availableInterval(y: y, height: height)
        return interval.leftIntrusion > 0 || interval.rightIntrusion > 0
    }

    /// Computes vertical clearance for `clear` property. Returns the adjusted Y coordinate.
    func clearance(for clear: CSSClear, currentY: CGFloat) -> CGFloat {
        guard clear != .none, !activeFloats.isEmpty else { return currentY }

        var targetY = currentY
        for float in activeFloats {
            let matches: Bool
            switch clear {
            case .left: matches = (float.side == .left)
            case .right: matches = (float.side == .right)
            case .both: matches = true
            case .none: matches = false
            }
            if matches {
                targetY = max(targetY, float.bottom)
            }
        }
        return targetY
    }

    /// Places a new float box. Finds the first vertical position >= `startY` where
    /// the float's margin box width fits horizontally, aligns it to left or right edge,
    /// and adds it to `activeFloats`.
    /// Returns the resolved marginBox and borderBox rects.
    @discardableResult
    func placeFloat(
        side: CSSFloat,
        marginBoxSize: CGSize,
        margins: EdgeSizes,
        startY: CGFloat,
        nodeID: Int = -1,
        clear: CSSClear = .none
    ) -> (marginBox: CGRect, borderBox: CGRect) {
        let clearedY = clearance(for: clear, currentY: startY)
        var testY = clearedY

        // Loop until horizontal space is enough to accommodate the float margin box width
        while true {
            let interval = availableInterval(y: testY, height: marginBoxSize.height)
            if interval.lineWidth >= marginBoxSize.width || interval.lineWidth == containerWidth {
                // Fits horizontally!
                let marginX: CGFloat
                if side == .left {
                    marginX = interval.lineX
                } else {
                    // Right float
                    marginX = containerWidth - interval.rightIntrusion - marginBoxSize.width
                }
                let marginBox = CGRect(x: marginX, y: testY, width: marginBoxSize.width, height: marginBoxSize.height)
                let borderBox = CGRect(
                    x: marginX + margins.left,
                    y: testY + margins.top,
                    width: max(0, marginBoxSize.width - margins.horizontal),
                    height: max(0, marginBoxSize.height - margins.vertical)
                )
                let active = ActiveFloat(
                    side: side,
                    marginBox: marginBox,
                    borderBox: borderBox,
                    nodeID: nodeID,
                    clear: clear
                )
                activeFloats.append(active)
                return (marginBox, borderBox)
            }

            // Does not fit: find the next lowest float bottom in the current band to jump down to
            let overlappingBottoms = activeFloats
                .filter { $0.top < testY + marginBoxSize.height && $0.bottom > testY }
                .map { $0.bottom }

            if let nextY = overlappingBottoms.filter({ $0 > testY }).min() {
                testY = nextY
            } else {
                // Fallback: place at testY
                let marginX = (side == .left) ? 0 : max(0, containerWidth - marginBoxSize.width)
                let marginBox = CGRect(x: marginX, y: testY, width: marginBoxSize.width, height: marginBoxSize.height)
                let borderBox = CGRect(
                    x: marginX + margins.left,
                    y: testY + margins.top,
                    width: max(0, marginBoxSize.width - margins.horizontal),
                    height: max(0, marginBoxSize.height - margins.vertical)
                )
                let active = ActiveFloat(side: side, marginBox: marginBox, borderBox: borderBox, nodeID: nodeID, clear: clear)
                activeFloats.append(active)
                return (marginBox, borderBox)
            }
        }
    }

    /// Maximum bottom extent of all active floats.
    var maxBottom: CGFloat {
        activeFloats.map { $0.bottom }.max() ?? 0
    }

    /// Clears floats that end at or before `y`.
    func pruneFloats(beforeY y: CGFloat) {
        activeFloats.removeAll { $0.bottom <= y }
    }
}
