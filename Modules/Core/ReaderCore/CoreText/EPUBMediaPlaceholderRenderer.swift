import YueduCoreText
import UIKit

enum EPUBMediaPlaceholderRenderer {
    @MainActor
    static func image(
        for media: EPUBMediaAttachment,
        maxWidth: CGFloat,
        intrinsicSize: CGSize? = nil,
        poster: UIImage? = nil,
        font: UIFont,
        textColor: UIColor,
        backgroundColor: UIColor
    ) -> UIImage {
        guard media.kind == .video else {
            return audioImage(for: media, maxWidth: maxWidth, font: font, textColor: textColor)
        }
        if let poster, poster.size.width > 0, poster.size.height > 0 {
            return videoPosterImage(poster: poster, maxWidth: maxWidth, intrinsicSize: intrinsicSize)
        }
        return videoImage(maxWidth: maxWidth, intrinsicSize: intrinsicSize)
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
    static func videoImage(maxWidth: CGFloat, intrinsicSize: CGSize? = nil) -> UIImage {
        MediaPlaceholderRenderer.videoImage(maxWidth: maxWidth, intrinsicSize: intrinsicSize)
    }

    /// The video's own `poster` frame with the play button over it — what a reader recognises as
    /// "tap to play". Sized by the same rules as the plain placeholder (`MediaPlaceholderRenderer`),
    /// except that without an authored size the poster's own proportions decide the height, so a
    /// portrait clip is not letterboxed into a 16:9 box.
    @MainActor
    static func videoPosterImage(poster: UIImage, maxWidth: CGFloat, intrinsicSize: CGSize? = nil) -> UIImage {
        let aspect: CGFloat = {
            if let size = intrinsicSize, size.width > 0, size.height > 0 {
                return min(max(size.height / size.width, 0.4), 1.8)
            }
            return min(max(poster.size.height / poster.size.width, 0.4), 1.8)
        }()
        let cap = min(maxWidth, 640)
        let width = max(200, min(cap, intrinsicSize?.width ?? cap))
        let height = max(120, width * aspect)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false

        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { _ in
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            let frame = UIBezierPath(roundedRect: bounds, cornerRadius: 10)
            UIColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1).setFill()
            frame.fill()
            frame.addClip()
            let scale = min(width / poster.size.width, height / poster.size.height)
            let drawn = CGSize(width: poster.size.width * scale, height: poster.size.height * scale)
            poster.draw(in: CGRect(
                x: (width - drawn.width) / 2, y: (height - drawn.height) / 2,
                width: drawn.width, height: drawn.height
            ))

            let diameter = min(width, height) * 0.24
            let disc = CGRect(x: (width - diameter) / 2, y: (height - diameter) / 2, width: diameter, height: diameter)
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

    /// The card an `<iframe>` page shows until it is tapped: the iframe's proportions (16:9 by
    /// default), a dark frame, a play button, and the title and host underneath it, so the reader
    /// can tell a player from an advert before loading anything.
    @MainActor
    static func webEmbedImage(for embed: ReaderWebEmbed, maxWidth: CGFloat, font: UIFont) -> UIImage {
        let aspect = min(max(embed.aspectRatio ?? 9.0 / 16.0, 0.4), 1.8)
        let width = max(200, min(maxWidth, 640))
        let height = max(120, width * aspect)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { _ in
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            UIColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1).setFill()
            UIBezierPath(roundedRect: bounds, cornerRadius: 10).fill()

            let diameter = min(width, height) * 0.24
            let disc = CGRect(x: (width - diameter) / 2, y: (height - diameter) / 2 - 12, width: diameter, height: diameter)
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

            let title = embed.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? embed.title! : localized("內嵌網頁")
            let host = embed.host
            draw(
                host.isEmpty ? title : title + " · " + host,
                in: CGRect(x: 16, y: disc.maxY + 12, width: width - 32, height: 22),
                font: UIFont.systemFont(ofSize: max(13, min(font.pointSize, 16)), weight: .medium),
                color: UIColor.white.withAlphaComponent(0.86),
                alignment: .center
            )
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

    private static func draw(
        _ text: String, in rect: CGRect, font: UIFont, color: UIColor,
        alignment: NSTextAlignment = .natural
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        paragraph.alignment = alignment
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
