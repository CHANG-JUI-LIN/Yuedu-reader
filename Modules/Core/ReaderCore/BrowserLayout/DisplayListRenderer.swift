import CoreGraphics
import Foundation
import UIKit

/// Renders a single-page DisplayList into a UIImage. Coordinates are page-local;
/// the renderer owns no layout state. Glyph drawing goes through UIKit text
/// drawing (shaped by the item's font) — CoreText shaping happened earlier.
///
/// `DisplayListDrawer.draw(_:in:)` is the CGContext core shared with
/// `BrowserLayoutPageView` (direct page drawing — no intermediate UIImage).
enum DisplayListRenderer {

    static func render(
        _ list: DisplayList,
        size: CGSize,
        backgroundColor: UIColor = .white
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            backgroundColor.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            DisplayListDrawer.draw(list, in: context.cgContext)
        }
    }
}

enum DisplayListDrawer {
    /// Draws the list into the CURRENT context. The caller owns the background.
    static func draw(_ list: DisplayList, in context: CGContext) {
        for item in list.items {
            switch item {
            case .fill(let f):
                if f.cornerRadius > 0 {
                    let path = UIBezierPath(
                        roundedRect: f.rect,
                        cornerRadius: min(f.cornerRadius, f.rect.width / 2, f.rect.height / 2)
                    )
                    f.color.setFill()
                    path.fill()
                } else {
                    f.color.setFill()
                    context.fill(f.rect)
                }
            case .text(let t):
                drawText(t)
            case .image(let i):
                if let image = i.image {
                    image.draw(in: i.rect)
                } else {
                    UIColor.lightGray.setFill()
                    context.fill(i.rect)
                }
            }
        }
    }

    private static func drawText(_ item: DisplayTextItem) {
        guard !item.text.isEmpty else { return }
        let string = NSAttributedString(string: item.text, attributes: [
            .font: item.font,
            .foregroundColor: item.color,
        ])
        // Draw with the glyph top aligned to the line box top (baseline math
        // already accounts for ascent).
        let drawPoint = CGPoint(x: item.rect.minX, y: item.baselineY - item.font.ascender)
        string.draw(at: drawPoint)
    }
}
