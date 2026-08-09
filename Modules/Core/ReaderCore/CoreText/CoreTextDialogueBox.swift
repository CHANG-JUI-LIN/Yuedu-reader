import UIKit

/// Draws the "對話底色框" background box behind quoted dialogue.
///
/// Two styles (`Style`), chosen in reader settings and shared by both writing modes:
/// - `.solid` — the base color as an opaque, lightly-rounded block.
/// - `.gradientPill` — a translucent left→right gradient in a fully-rounded pill, derived from the
///   base color (matching a shared reference: `linear-gradient(90deg, base@45%, lighter@35%)`,
///   `border-radius: 999px`). Because it's translucent, page background / textures show through.
///
/// This painter is now retained for the TTS interaction overlay. Reading-content backgrounds use
/// `RegexHighlightDecorationRenderer`, which supports the same rules in both writing modes.
enum CoreTextDialogueBox {

    enum Style: Int {
        case solid = 0
        case gradientPill = 1
    }

    /// The style currently selected in reader settings.
    static var currentStyle: Style {
        Style(rawValue: GlobalSettings.shared.readerDialogueBoxStyleRaw) ?? .gradientPill
    }

    /// Fills one dialogue box rect in the current draw context (already in the correct coordinate
    /// space). The rect is the padded glyph box; shape and paint come from `style`.
    static func fill(rect: CGRect, baseColor: UIColor, style: Style, in ctx: CGContext) {
        guard rect.width > 0.5, rect.height > 0.5 else { return }

        switch style {
        case .solid:
            let radius = max(0, min(4, min(rect.width, rect.height) / 2))
            ctx.saveGState()
            ctx.setFillColor(baseColor.cgColor)
            ctx.addPath(UIBezierPath(roundedRect: rect, cornerRadius: radius).cgPath)
            ctx.fillPath()
            ctx.restoreGState()

        case .gradientPill:
            let radius = min(rect.width, rect.height) / 2   // border-radius: 999px → capsule
            let (c0, c1) = gradientStops(from: baseColor)
            guard let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [c0.cgColor, c1.cgColor] as CFArray,
                locations: [0, 1]
            ) else { return }

            ctx.saveGState()
            ctx.addPath(UIBezierPath(roundedRect: rect, cornerRadius: radius).cgPath)
            ctx.clip()
            // Gradient runs along the box's long axis (the reading direction in either writing mode).
            let start: CGPoint
            let end: CGPoint
            if rect.width >= rect.height {
                start = CGPoint(x: rect.minX, y: rect.midY)
                end = CGPoint(x: rect.maxX, y: rect.midY)
            } else {
                start = CGPoint(x: rect.midX, y: rect.minY)
                end = CGPoint(x: rect.midX, y: rect.maxY)
            }
            ctx.drawLinearGradient(
                gradient,
                start: start,
                end: end,
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
            ctx.restoreGState()
        }
    }

    /// Derives the reference's two translucent stops from a single base color:
    /// `base @ 45%` → `base blended 60% toward white @ 35%`.
    static func gradientStops(from base: UIColor) -> (UIColor, UIColor) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard base.getRed(&r, green: &g, blue: &b, alpha: &a) else {
            return (base.withAlphaComponent(0.45), base.withAlphaComponent(0.35))
        }
        let c0 = UIColor(red: r, green: g, blue: b, alpha: 0.45)
        let c1 = UIColor(
            red: r + (1 - r) * 0.6,
            green: g + (1 - g) * 0.6,
            blue: b + (1 - b) * 0.6,
            alpha: 0.35
        )
        return (c0, c1)
    }

}
