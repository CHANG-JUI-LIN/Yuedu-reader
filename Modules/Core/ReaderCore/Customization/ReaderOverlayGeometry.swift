import CoreGraphics
import Foundation

enum ReaderOverlayHorizontalAnchor {
    case leading
    case center
    case trailing

    static func resolve(forNormalizedX x: Double) -> ReaderOverlayHorizontalAnchor {
        if x < 0.5 { return .leading }
        if x > 0.5 { return .trailing }
        return .center
    }
}

enum ReaderOverlayGeometry {
    static func denormalize(
        _ point: ReaderOverlayNormalizedPoint,
        in bounds: CGRect
    ) -> CGPoint {
        let point = point.clamped
        return CGPoint(
            x: denormalizeAxis(point.x, origin: bounds.origin.x, extent: bounds.size.width),
            y: denormalizeAxis(point.y, origin: bounds.origin.y, extent: bounds.size.height)
        )
    }

    static func normalize(
        _ point: CGPoint,
        in bounds: CGRect
    ) -> ReaderOverlayNormalizedPoint {
        guard isUsable(bounds) else {
            return ReaderOverlayNormalizedPoint(x: 0.5, y: 0.5)
        }

        return ReaderOverlayNormalizedPoint(
            x: Double((point.x - bounds.minX) / bounds.width),
            y: Double((point.y - bounds.minY) / bounds.height)
        ).clamped
    }

    static func clamp(
        center: CGPoint,
        size: CGSize,
        to bounds: CGRect
    ) -> CGPoint {
        CGPoint(
            x: clampAxis(
                center: center.x,
                componentExtent: size.width,
                boundsOrigin: bounds.origin.x,
                boundsExtent: bounds.size.width
            ),
            y: clampAxis(
                center: center.y,
                componentExtent: size.height,
                boundsOrigin: bounds.origin.y,
                boundsExtent: bounds.size.height
            )
        )
    }

    /// Places a component in `bounds` using a normalized position interpreted as an
    /// **anchor point** (not necessarily the center). For `.leading`, the position
    /// represents the left edge; `.trailing` → the right edge; `.center` → the midpoint.
    /// Returns the concrete placement point + horizontal anchor.
    static func anchoredPlacement(
        normalizedPoint: ReaderOverlayNormalizedPoint,
        size: CGSize,
        in bounds: CGRect
    ) -> (point: CGPoint, anchor: ReaderOverlayHorizontalAnchor) {
        guard bounds.width > 0, bounds.height > 0 else {
            return (bounds.origin, .center)
        }

        let anchor = ReaderOverlayHorizontalAnchor.resolve(
            forNormalizedX: normalizedPoint.x
        )
        let denorm = denormalize(normalizedPoint, in: bounds)
        let safeSize = CGSize(
            width: size.width.isFinite && size.width > 0 ? size.width : 0,
            height: size.height.isFinite && size.height > 0 ? size.height : 0
        )

        switch anchor {
        case .leading:
            let minX = bounds.minX
            let maxX = bounds.maxX - safeSize.width
            let clampedX = min(max(denorm.x, minX), max(minX, maxX))
            let clampedY = clampAxis(
                center: denorm.y,
                componentExtent: safeSize.height,
                boundsOrigin: bounds.minY,
                boundsExtent: bounds.height
            )
            return (CGPoint(x: clampedX, y: clampedY), .leading)

        case .trailing:
            let maxX = bounds.maxX
            let minX = bounds.minX + safeSize.width
            let clampedX = min(max(denorm.x, minX), max(minX, maxX))
            let clampedY = clampAxis(
                center: denorm.y,
                componentExtent: safeSize.height,
                boundsOrigin: bounds.minY,
                boundsExtent: bounds.height
            )
            return (CGPoint(x: clampedX, y: clampedY), .trailing)

        case .center:
            let center = clamp(center: denorm, size: safeSize, to: bounds)
            return (center, .center)
        }
    }

    /// Converts a visual **center** (e.g. from `measuredFrames`) to the corresponding
    /// **anchor point** that should be stored as the normalized position, given the
    /// anchor mode determined by where the center falls horizontally.
    static func centerToAnchorPoint(
        center: CGPoint,
        componentSize: CGSize,
        canvasWidth: CGFloat
    ) -> (point: CGPoint, anchor: ReaderOverlayHorizontalAnchor) {
        guard canvasWidth > 0 else {
            return (center, .center)
        }
        let halfWidth = componentSize.width.isFinite && componentSize.width > 0
            ? componentSize.width / 2 : 0
        let anchor: ReaderOverlayHorizontalAnchor
        let x: CGFloat
        if center.x < canvasWidth / 2 {
            anchor = .leading
            x = center.x - halfWidth
        } else if center.x > canvasWidth / 2 {
            anchor = .trailing
            x = center.x + halfWidth
        } else {
            anchor = .center
            x = center.x
        }
        return (CGPoint(x: x, y: center.y), anchor)
    }

    private static func denormalizeAxis(
        _ normalized: Double,
        origin: CGFloat,
        extent: CGFloat
    ) -> CGFloat {
        guard origin.isFinite, extent.isFinite else { return 0 }
        let coordinate = origin + extent * CGFloat(normalized)
        return coordinate.isFinite ? coordinate : 0
    }

    private static func clampAxis(
        center: CGFloat,
        componentExtent: CGFloat,
        boundsOrigin: CGFloat,
        boundsExtent: CGFloat
    ) -> CGFloat {
        let finiteCenter = center.isFinite ? center : 0
        guard boundsOrigin.isFinite,
              boundsExtent.isFinite,
              boundsExtent > 0,
              (boundsOrigin + boundsExtent).isFinite else {
            return finiteCenter
        }

        let boundsMid = boundsOrigin + boundsExtent / 2
        let componentExtent = componentExtent.isFinite && componentExtent > 0
            ? componentExtent
            : 0
        guard componentExtent <= boundsExtent else { return boundsMid }

        let halfExtent = componentExtent / 2
        let minimum = boundsOrigin + halfExtent
        let maximum = boundsOrigin + boundsExtent - halfExtent
        let proposed = center.isFinite ? center : boundsMid
        return min(max(proposed, minimum), maximum)
    }

    private static func isUsable(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite
            && rect.origin.y.isFinite
            && rect.width.isFinite
            && rect.height.isFinite
            && rect.width > 0
            && rect.height > 0
            && rect.maxX.isFinite
            && rect.maxY.isFinite
    }
}
