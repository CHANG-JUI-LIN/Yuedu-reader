import UIKit

enum EPUBMediaPlaceholderRenderer {
    @MainActor
    static func image(
        for media: EPUBMediaAttachment,
        maxWidth: CGFloat,
        font: UIFont,
        textColor: UIColor,
        backgroundColor: UIColor
    ) -> UIImage {
        let width = max(160, min(maxWidth, 520))
        let height: CGFloat = media.kind == .video ? 140 : 72
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        format.opaque = false

        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            let fill = textColor.withAlphaComponent(0.08)
            fill.setFill()
            UIBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerRadius: 12).fill()

            let stroke = textColor.withAlphaComponent(0.22)
            stroke.setStroke()
            let outline = UIBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerRadius: 12)
            outline.lineWidth = 1 / max(UIScreen.main.scale, 1)
            outline.stroke()

            let symbolName = media.kind == .video ? "play.rectangle.fill" : "waveform.circle.fill"
            let config = UIImage.SymbolConfiguration(pointSize: media.kind == .video ? 38 : 30, weight: .regular)
            let symbol = UIImage(systemName: symbolName, withConfiguration: config)?.withTintColor(textColor.withAlphaComponent(0.82), renderingMode: .alwaysOriginal)
            let iconSize = symbol?.size ?? CGSize(width: 34, height: 34)
            let iconRect = CGRect(
                x: 16,
                y: (height - iconSize.height) / 2,
                width: iconSize.width,
                height: iconSize.height
            )
            symbol?.draw(in: iconRect)

            let title = (media.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? media.title!
                : (media.kind == .video ? "EPUB Video" : "EPUB Audio"))
            let subtitle = media.sourceHref
            let textX = iconRect.maxX + 14
            let textWidth = max(1, width - textX - 16)

            draw(
                title,
                in: CGRect(x: textX, y: height / 2 - 22, width: textWidth, height: 24),
                font: UIFont.systemFont(ofSize: max(13, font.pointSize), weight: .semibold),
                color: textColor
            )
            draw(
                subtitle,
                in: CGRect(x: textX, y: height / 2 + 2, width: textWidth, height: 20),
                font: UIFont.systemFont(ofSize: max(10, font.pointSize * 0.78), weight: .regular),
                color: textColor.withAlphaComponent(0.58)
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
