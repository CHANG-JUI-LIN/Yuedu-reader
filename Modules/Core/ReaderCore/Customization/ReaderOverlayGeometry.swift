import CoreGraphics
import Foundation

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
