import UIKit

/// Draws the small inline "comment count" bubble used for Legado paragraph reviews (段評).
///
/// The bubble is a rounded speech balloon (rounded rect + a small tail) containing the
/// review count, sized relative to the surrounding body font so it sits inline at the
/// end of a paragraph. Rendered images are cached by (count, size, color).
enum ReviewBadgeRenderer {

    private static let cache = NSCache<NSString, UIImage>()

    /// Returns a cached bubble image for the given count, sized to the body `pointSize`.
    /// - Parameters:
    ///   - count: the visible count text (already clamped by the source, e.g. "12" / "99+").
    ///   - pointSize: the surrounding body font point size.
    ///   - color: stroke + text color (caller typically passes a muted theme text color).
    static func bubble(count: String, pointSize: CGFloat, color: UIColor) -> UIImage {
        let displayText = count.isEmpty ? "0" : count
        let key = cacheKey(text: displayText, pointSize: pointSize, color: color)
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let image = draw(text: displayText, pointSize: pointSize, color: color)
        cache.setObject(image, forKey: key)
        return image
    }

    private static func draw(text: String, pointSize: CGFloat, color: UIColor) -> UIImage {
        let fontSize = max(8, pointSize * 0.62)
        let badgeFont = UserReaderFontResolver.bodyFont(size: fontSize, isBold: GlobalSettings.shared.readerFontBold)
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: badgeFont,
            .foregroundColor: color,
        ]
        let textSize = (text as NSString).size(withAttributes: textAttrs)

        let height = ceil(pointSize * 0.96)
        let paddingH = max(4, pointSize * 0.30)
        let bubbleWidth = max(height, ceil(textSize.width) + paddingH * 2)
        let leadingGap = ceil(pointSize * 0.28)   // transparent space so it doesn't crowd the text
        let tailHeight = max(2, pointSize * 0.12)

        let canvasSize = CGSize(
            width: leadingGap + bubbleWidth,
            height: height + tailHeight
        )
        let lineWidth = 1.0 / max(UIScreen.main.scale, 1)

        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 3
        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: format)

        return renderer.image { _ in
            let bubbleRect = CGRect(
                x: leadingGap + lineWidth / 2,
                y: lineWidth / 2,
                width: bubbleWidth - lineWidth,
                height: height - lineWidth
            )
            let cornerRadius = bubbleRect.height * 0.42
            let path = UIBezierPath(roundedRect: bubbleRect, cornerRadius: cornerRadius)

            // Small tail at the bottom-left of the bubble.
            let tailX = bubbleRect.minX + bubbleRect.width * 0.28
            let tail = UIBezierPath()
            tail.move(to: CGPoint(x: tailX, y: bubbleRect.maxY - 1))
            tail.addLine(to: CGPoint(x: tailX, y: bubbleRect.maxY + tailHeight))
            tail.addLine(to: CGPoint(x: tailX + tailHeight * 1.6, y: bubbleRect.maxY - 1))
            tail.close()
            path.append(tail)

            color.setStroke()
            path.lineWidth = lineWidth
            path.lineJoinStyle = .round
            path.stroke()

            let textOrigin = CGPoint(
                x: bubbleRect.minX + (bubbleRect.width - textSize.width) / 2,
                y: bubbleRect.minY + (bubbleRect.height - textSize.height) / 2
            )
            (text as NSString).draw(at: textOrigin, withAttributes: textAttrs)
        }
    }

    private static func cacheKey(text: String, pointSize: CGFloat, color: UIColor) -> NSString {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        let rgba = String(format: "%.2f-%.2f-%.2f-%.2f", r, g, b, a)
        let fontName = GlobalSettings.shared.selectedReaderFontPostScript ?? "system"
        let isBold = GlobalSettings.shared.readerFontBold ? "bold" : "regular"
        return "\(text)|\(Int(pointSize.rounded()))|\(rgba)|\(fontName)|\(isBold)" as NSString
    }
}
