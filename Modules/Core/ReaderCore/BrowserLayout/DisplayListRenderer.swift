import YueduCoreText
import CoreGraphics
import CoreText
import Foundation
import UIKit

/// Renders a single-page DisplayList into a UIImage. Coordinates are page
/// canvas-local; the renderer owns no layout state. Glyph drawing goes through
/// UIKit text drawing (shaped by the item's font) — CoreText shaping happened
/// earlier.
///
/// `ReaderDisplayListDrawer.draw(_:in:)` is the CGContext core shared with
/// `BrowserLayoutPageView` (direct page drawing — no intermediate UIImage).
/// Phase 2C: a border box paints its FULL representation — background fill
/// (with radius), then each of the four border edges with its own style
/// (solid / dotted / dashed), clipped to the box.
enum DisplayListRenderer {

    static func render(
        _ list: DisplayList,
        size: CGSize,
        backgroundColor: UIColor = .white,
        readerBackgroundImage: UIImage? = nil,
        bars: ReaderPageBars? = nil
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let bounds = CGRect(origin: .zero, size: size)
        return renderer.image { context in
            backgroundColor.setFill()
            context.fill(bounds)
            // The snapshot stands in for a real page during the curl and cover
            // transitions, so it has to carry the same surface that page draws
            // — otherwise the flipping half is a flat colour and the resting
            // half is the artwork.
            if let readerBackgroundImage {
                CoreTextPageView.drawPageBackground(readerBackgroundImage, in: bounds)
            }
            ReaderDisplayListDrawer.draw(
                list,
                in: context.cgContext,
                skipAuthoredBackgroundPaint: readerBackgroundImage != nil
            )
            bars?.draw(in: bounds, context: context.cgContext)
        }
    }
}
