import CoreGraphics
import UIKit

/// The sticker artwork, drawn as paths rather than rasterised.
///
/// Every shape is authored in the same 100×100 box the script's SVG uses, with
/// the y axis already flipped for CoreText's upward coordinates, so a sticker
/// lands where the script would put it and stays sharp at any type size.
enum ReaderDialogueBubbleDecorationShape {
    struct Part {
        let path: CGPath
        /// Non-nil for the highlight pieces the script paints in a fixed colour
        /// (a flower's pollen, a bow's knot).
        let fixedColorHex: UInt32?
    }

    static func parts(for kind: ReaderDialogueBubbleDecorationKind) -> [Part] {
        switch kind {
        case .star: return [Part(path: star(), fixedColorHex: nil)]
        case .heart: return [Part(path: heart(), fixedColorHex: nil)]
        case .dot: return [Part(path: circle(x: 50, y: 50, radius: 38), fixedColorHex: nil)]
        case .flower: return flower()
        case .bow: return bow()
        }
    }

    private static func star() -> CGPath {
        let points: [CGPoint] = [
            CGPoint(x: 50, y: 94), CGPoint(x: 62, y: 64), CGPoint(x: 94, y: 62),
            CGPoint(x: 69, y: 42), CGPoint(x: 77, y: 10), CGPoint(x: 50, y: 28),
            CGPoint(x: 23, y: 10), CGPoint(x: 31, y: 42), CGPoint(x: 6, y: 62),
            CGPoint(x: 38, y: 64),
        ]
        let path = CGMutablePath()
        path.addLines(between: points)
        path.closeSubpath()
        return path
    }

    private static func heart() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 50, y: 14))
        path.addCurve(
            to: CGPoint(x: 15, y: 70),
            control1: CGPoint(x: 18, y: 35),
            control2: CGPoint(x: 8, y: 53)
        )
        path.addCurve(
            to: CGPoint(x: 50, y: 69),
            control1: CGPoint(x: 22, y: 87),
            control2: CGPoint(x: 43, y: 85)
        )
        path.addCurve(
            to: CGPoint(x: 85, y: 70),
            control1: CGPoint(x: 57, y: 85),
            control2: CGPoint(x: 78, y: 87)
        )
        path.addCurve(
            to: CGPoint(x: 50, y: 14),
            control1: CGPoint(x: 92, y: 53),
            control2: CGPoint(x: 82, y: 35)
        )
        path.closeSubpath()
        return path
    }

    private static func flower() -> [Part] {
        let petals = CGMutablePath()
        for centre in [
            CGPoint(x: 50, y: 76), CGPoint(x: 75, y: 57), CGPoint(x: 66, y: 27),
            CGPoint(x: 34, y: 27), CGPoint(x: 25, y: 57),
        ] {
            petals.addPath(circle(x: centre.x, y: centre.y, radius: 20))
        }
        return [
            Part(path: petals, fixedColorHex: nil),
            Part(path: circle(x: 50, y: 50, radius: 16), fixedColorHex: 0xFFF4B8),
        ]
    }

    private static func bow() -> [Part] {
        let wings = CGMutablePath()
        wings.move(to: CGPoint(x: 47, y: 55))
        wings.addCurve(
            to: CGPoint(x: 12, y: 55),
            control1: CGPoint(x: 34, y: 81),
            control2: CGPoint(x: 8, y: 83)
        )
        wings.addCurve(
            to: CGPoint(x: 47, y: 47),
            control1: CGPoint(x: 15, y: 35),
            control2: CGPoint(x: 35, y: 39)
        )
        wings.closeSubpath()
        wings.move(to: CGPoint(x: 53, y: 55))
        wings.addCurve(
            to: CGPoint(x: 88, y: 55),
            control1: CGPoint(x: 66, y: 81),
            control2: CGPoint(x: 92, y: 83)
        )
        wings.addCurve(
            to: CGPoint(x: 53, y: 47),
            control1: CGPoint(x: 85, y: 35),
            control2: CGPoint(x: 65, y: 39)
        )
        wings.closeSubpath()
        let knot = UIBezierPath(
            roundedRect: CGRect(x: 40, y: 36, width: 20, height: 25),
            cornerRadius: 8
        ).cgPath
        return [
            Part(path: wings, fixedColorHex: nil),
            Part(path: knot, fixedColorHex: 0xFFF4B8),
        ]
    }

    private static func circle(x: CGFloat, y: CGFloat, radius: CGFloat) -> CGPath {
        CGPath(
            ellipseIn: CGRect(
                x: x - radius,
                y: y - radius,
                width: radius * 2,
                height: radius * 2
            ),
            transform: nil
        )
    }
}
