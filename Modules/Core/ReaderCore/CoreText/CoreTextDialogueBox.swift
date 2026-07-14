import CoreText
import UIKit

/// Draws the "對話底色框" background box behind quoted dialogue.
///
/// Two styles (`Style`), chosen in reader settings and shared by both writing modes:
/// - `.solid` — the base color as an opaque, lightly-rounded block.
/// - `.gradientPill` — a translucent left→right gradient in a fully-rounded pill, derived from the
///   base color (matching a shared reference: `linear-gradient(90deg, base@45%, lighter@35%)`,
///   `border-radius: 999px`). Because it's translucent, page background / textures show through.
///
/// Horizontal mode calls `fill` from `CoreTextHorizontalLineDrawer` (which owns the justified line
/// geometry). Vertical mode has no line drawer, so `drawVertical` fills before `CTFrameDraw`,
/// reusing `CoreTextAnnotationRenderer`'s vertical rect geometry (the same math that positions
/// vertical annotation highlights) so alignment matches without re-deriving column coordinates.
///
/// Dialogue spans are marked with `DialogueHighlighter.boxColorAttribute` (value: `UIColor` base).
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

    /// Fills dialogue boxes for a vertical CTFrame. The caller must have already applied the
    /// CoreText → UIKit coordinate flip (as `CTFrameDraw` requires); rects are converted from the
    /// annotation renderer's UIKit coordinates back into that flipped space.
    ///
    /// - Parameters:
    ///   - contentOffset: The frame path's origin in layout coordinates (page mode uses the content
    ///     rect origin; chunk mode uses `.zero`), matching what the annotation overlay passes.
    ///   - layoutHeight: The height used for the coordinate flip (page layout height / chunk bounds).
    static func drawVertical(
        frame: CTFrame,
        attrStr: NSAttributedString,
        contentOffset: CGPoint,
        layoutHeight: CGFloat,
        writingMode: ReaderWritingMode,
        in ctx: CGContext
    ) {
        guard writingMode.isVertical else { return }

        let lines = CTFrameGetLines(frame) as! [CTLine]
        guard !lines.isEmpty else { return }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRangeMake(0, lines.count), &origins)

        let frameRange = CTFrameGetStringRange(frame)
        let ns = NSRange(location: max(0, frameRange.location), length: max(0, frameRange.length))
        guard ns.length > 0, ns.location + ns.length <= attrStr.length else { return }

        let style = currentStyle

        attrStr.enumerateAttribute(DialogueHighlighter.boxColorAttribute, in: ns, options: []) { value, range, _ in
            guard let color = value as? UIColor, range.length > 0 else { return }

            let uiRects = CoreTextAnnotationRenderer.rects(
                forRange: range,
                lines: lines,
                lineOrigins: origins,
                contentOffset: contentOffset,
                layoutHeight: layoutHeight,
                writingMode: writingMode
            )

            for uiRect in uiRects {
                let padH: CGFloat = 1.0
                let padV: CGFloat = 1.0
                // Flip the UIKit-space rect back into the CoreText-flipped draw context.
                let boxRect = CGRect(
                    x: uiRect.minX - padH,
                    y: layoutHeight - uiRect.maxY - padV,
                    width: uiRect.width + 2 * padH,
                    height: uiRect.height + 2 * padV
                )
                fill(rect: boxRect, baseColor: color, style: style, in: ctx)
            }
        }
    }
}
