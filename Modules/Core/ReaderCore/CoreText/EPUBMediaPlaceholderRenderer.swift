import UIKit

enum EPUBMediaPlaceholderRenderer {
    @MainActor
    static func image(
        for media: EPUBMediaAttachment,
        maxWidth: CGFloat,
        intrinsicSize: CGSize? = nil,
        font: UIFont,
        textColor: UIColor,
        backgroundColor: UIColor
    ) -> UIImage {
        media.kind == .video
            ? videoImage(maxWidth: maxWidth, intrinsicSize: intrinsicSize)
            : audioImage(for: media, maxWidth: maxWidth, font: font, textColor: textColor)
    }

    @MainActor
    static func interactiveImage(
        title: String,
        detail: String,
        maxWidth: CGFloat,
        font: UIFont,
        textColor: UIColor
    ) -> UIImage {
        let width = max(180, min(maxWidth, 520))
        let height: CGFloat = 86
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        format.opaque = false

        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { _ in
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            textColor.withAlphaComponent(0.07).setFill()
            UIBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerRadius: 8).fill()

            textColor.withAlphaComponent(0.24).setStroke()
            let outline = UIBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerRadius: 8)
            outline.lineWidth = 1 / max(UIScreen.main.scale, 1)
            outline.stroke()

            let config = UIImage.SymbolConfiguration(pointSize: 28, weight: .regular)
            let symbol = UIImage(systemName: "puzzlepiece.extension", withConfiguration: config)?
                .withTintColor(textColor.withAlphaComponent(0.78), renderingMode: .alwaysOriginal)
            let iconSize = symbol?.size ?? CGSize(width: 28, height: 28)
            let iconRect = CGRect(
                x: 16,
                y: (height - iconSize.height) / 2,
                width: iconSize.width,
                height: iconSize.height
            )
            symbol?.draw(in: iconRect)

            let textX = iconRect.maxX + 14
            let textWidth = max(1, width - textX - 16)
            draw(
                title,
                in: CGRect(x: textX, y: 18, width: textWidth, height: 24),
                font: UIFont.systemFont(ofSize: max(13, font.pointSize), weight: .semibold),
                color: textColor
            )
            if !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draw(
                    detail,
                    in: CGRect(x: textX, y: 46, width: textWidth, height: 20),
                    font: UIFont.systemFont(ofSize: max(11, font.pointSize - 2), weight: .regular),
                    color: textColor.withAlphaComponent(0.72)
                )
            }
        }
    }

    // MARK: - Video

    /// A dark 16:9-ish "film" frame with a centered play button — tapping it opens the player.
    /// Honors the element's CSS width/height aspect when known, capped to the content width.
    @MainActor
    private static func videoImage(maxWidth: CGFloat, intrinsicSize: CGSize?) -> UIImage {
        let aspect: CGFloat = {
            if let size = intrinsicSize, size.width > 0, size.height > 0 {
                // Clamp to a sane range so a malformed size can't make a sliver or a tower.
                return min(max(size.height / size.width, 0.4), 1.4)
            }
            return 9.0 / 16.0
        }()
        let cap = min(maxWidth, 640)
        let width = max(200, min(cap, intrinsicSize?.width ?? cap))
        let height = max(120, width * aspect)

        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        format.opaque = false

        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { _ in
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            UIColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1).setFill()
            UIBezierPath(roundedRect: bounds, cornerRadius: 10).fill()

            // Play button: a light disc with a dark triangle, optically nudged right.
            let diameter = min(width, height) * 0.30
            let disc = CGRect(
                x: (width - diameter) / 2,
                y: (height - diameter) / 2,
                width: diameter,
                height: diameter
            )
            UIColor.white.withAlphaComponent(0.92).setFill()
            UIBezierPath(ovalIn: disc).fill()

            let t = diameter * 0.42
            let cx = disc.midX + t * 0.12
            let cy = disc.midY
            let triangle = UIBezierPath()
            triangle.move(to: CGPoint(x: cx - t * 0.5, y: cy - t * 0.6))
            triangle.addLine(to: CGPoint(x: cx - t * 0.5, y: cy + t * 0.6))
            triangle.addLine(to: CGPoint(x: cx + t * 0.64, y: cy))
            triangle.close()
            UIColor(white: 0.1, alpha: 1).setFill()
            triangle.fill()
        }
    }

    // MARK: - Audio

    @MainActor
    private static func audioImage(
        for media: EPUBMediaAttachment,
        maxWidth: CGFloat,
        font: UIFont,
        textColor: UIColor
    ) -> UIImage {
        let width = max(160, min(maxWidth, 520))
        let height: CGFloat = 72
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        format.opaque = false

        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { _ in
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            let fill = textColor.withAlphaComponent(0.08)
            fill.setFill()
            UIBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerRadius: 12).fill()

            let stroke = textColor.withAlphaComponent(0.22)
            stroke.setStroke()
            let outline = UIBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerRadius: 12)
            outline.lineWidth = 1 / max(UIScreen.main.scale, 1)
            outline.stroke()

            let config = UIImage.SymbolConfiguration(pointSize: 30, weight: .regular)
            let symbol = UIImage(systemName: "waveform.circle.fill", withConfiguration: config)?
                .withTintColor(textColor.withAlphaComponent(0.82), renderingMode: .alwaysOriginal)
            let iconSize = symbol?.size ?? CGSize(width: 30, height: 30)
            let iconRect = CGRect(
                x: 16,
                y: (height - iconSize.height) / 2,
                width: iconSize.width,
                height: iconSize.height
            )
            symbol?.draw(in: iconRect)

            let title = (media.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? media.title!
                : "EPUB Audio")
            let textX = iconRect.maxX + 14
            let textWidth = max(1, width - textX - 16)
            draw(
                title,
                in: CGRect(x: textX, y: (height - 24) / 2, width: textWidth, height: 24),
                font: UIFont.systemFont(ofSize: max(13, font.pointSize), weight: .semibold),
                color: textColor
            )
        }
    }

    private static func draw(_ text: String, in rect: CGRect, font: UIFont, color: UIColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        (text as NSString).draw(
            with: rect,
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ],
            context: nil
        )
    }
}
