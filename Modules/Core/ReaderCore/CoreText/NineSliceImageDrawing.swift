import CoreGraphics

/// Nine-patch: the corners keep a fixed size, the edges stretch along one axis and
/// the centre along both. The one implementation behind dialogue-bubble skins and
/// regex-highlight frames.
///
/// Expects a y-up context (CoreText's), where `CGContext.draw` already draws images
/// upright.
enum NineSliceImageDrawing {
    struct Insets: Equatable {
        var top: CGFloat
        var right: CGFloat
        var bottom: CGFloat
        var left: CGFloat

        /// Opposite slices that together exceed the box would overlap; shrink
        /// the pair proportionally instead, the way a platform nine-patch does.
        func fitted(within size: CGSize) -> Insets {
            var result = self
            let horizontal = left + right
            if horizontal > size.width, horizontal > 0 {
                let factor = size.width / horizontal
                result.left *= factor
                result.right *= factor
            }
            let vertical = top + bottom
            if vertical > size.height, vertical > 0 {
                let factor = size.height / vertical
                result.top *= factor
                result.bottom *= factor
            }
            return result
        }
    }

    /// Destination size of each slice. `slices` are source pixels and `scale` maps
    /// source pixels to points; when the corners do not fit `rect`, both axes shrink
    /// by the *same* factor so the artwork keeps its proportions — scaling each axis
    /// on its own squashes the corners and leaves a banded, mis-assembled look.
    static func destinationInsets(
        slices: Insets,
        sourceSize: CGSize,
        scale baseScale: CGFloat,
        in rect: CGRect
    ) -> (source: Insets, destination: Insets) {
        let source = slices.fitted(
            within: CGSize(width: sourceSize.width - 1, height: sourceSize.height - 1)
        )
        let neededWidth = (source.left + source.right) * baseScale
        let neededHeight = (source.top + source.bottom) * baseScale
        let fit = min(
            1,
            neededWidth > 0 ? rect.width / neededWidth : 1,
            neededHeight > 0 ? rect.height / neededHeight : 1
        )
        let scale = baseScale * max(0, fit)
        return (source, Insets(
            top: source.top * scale,
            right: source.right * scale,
            bottom: source.bottom * scale,
            left: source.left * scale
        ))
    }

    static func draw(
        _ image: CGImage,
        slices: Insets,
        scale: CGFloat,
        in rect: CGRect,
        context: CGContext
    ) {
        let sourceWidth = CGFloat(image.width)
        let sourceHeight = CGFloat(image.height)
        guard sourceWidth > 0, sourceHeight > 0, scale.isFinite,
              rect.width > 0, rect.height > 0 else { return }
        let (source, destination) = destinationInsets(
            slices: slices,
            sourceSize: CGSize(width: sourceWidth, height: sourceHeight),
            scale: scale,
            in: rect
        )

        // Top-down source columns/rows, y-up destination columns/rows.
        let sourceX: [CGFloat] = [0, source.left, sourceWidth - source.right, sourceWidth]
        let sourceY: [CGFloat] = [0, source.top, sourceHeight - source.bottom, sourceHeight]
        // The inner grid lines sit on device pixels. Two slices that share a pixel are
        // each antialiased into it, and two partial coverages of a translucent image
        // composite to less than the image's own alpha — a thin line along the join
        // (FB-238). A centre band thinner than a pixel collapses to nothing here and
        // the slices either side of it meet on the pixel boundary instead.
        let innerLeft = snappedToDevicePixel(
            x: rect.minX + destination.left, in: rect, context: context
        )
        let innerRight = max(innerLeft, snappedToDevicePixel(
            x: rect.maxX - destination.right, in: rect, context: context
        ))
        let innerBottom = snappedToDevicePixel(
            y: rect.minY + destination.bottom, in: rect, context: context
        )
        let innerTop = max(innerBottom, snappedToDevicePixel(
            y: rect.maxY - destination.top, in: rect, context: context
        ))
        let destinationX: [CGFloat] = [rect.minX, innerLeft, innerRight, rect.maxX]
        let destinationY: [CGFloat] = [rect.maxY, innerTop, innerBottom, rect.minY]

        for row in 0..<3 {
            for column in 0..<3 {
                let sourceRect = CGRect(
                    x: sourceX[column],
                    y: sourceY[row],
                    width: sourceX[column + 1] - sourceX[column],
                    height: sourceY[row + 1] - sourceY[row]
                )
                let destinationRect = CGRect(
                    x: destinationX[column],
                    y: destinationY[row + 1],
                    width: destinationX[column + 1] - destinationX[column],
                    height: destinationY[row] - destinationY[row + 1]
                )
                guard sourceRect.width >= 1, sourceRect.height >= 1,
                      destinationRect.width > 0.1, destinationRect.height > 0.1,
                      let piece = image.cropping(to: sourceRect) else {
                    continue
                }
                context.draw(piece, in: destinationRect)
            }
        }
    }

    /// `x` moved to the nearest device-pixel boundary of `context`, kept inside `rect`.
    /// Goes through the context's own transform, so the caller's scale and any
    /// translation it applied (a highlight's background-image offset) are accounted for.
    private static func snappedToDevicePixel(
        x: CGFloat, in rect: CGRect, context: CGContext
    ) -> CGFloat {
        let snapped = snappedToDevicePixel(CGPoint(x: x, y: rect.midY), context: context).x
        return min(max(snapped, rect.minX), rect.maxX)
    }

    private static func snappedToDevicePixel(
        y: CGFloat, in rect: CGRect, context: CGContext
    ) -> CGFloat {
        let snapped = snappedToDevicePixel(CGPoint(x: rect.midX, y: y), context: context).y
        return min(max(snapped, rect.minY), rect.maxY)
    }

    private static func snappedToDevicePixel(_ point: CGPoint, context: CGContext) -> CGPoint {
        let device = context.convertToDeviceSpace(point)
        return context.convertToUserSpace(CGPoint(x: device.x.rounded(), y: device.y.rounded()))
    }
}
