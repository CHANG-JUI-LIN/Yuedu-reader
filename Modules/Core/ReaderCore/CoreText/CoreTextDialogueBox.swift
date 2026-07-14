import CoreText
import UIKit

/// Draws the "對話底色框" background box behind quoted dialogue in **vertical** writing mode.
///
/// Horizontal mode is handled inline by `CoreTextHorizontalLineDrawer` (which owns the justified
/// line geometry). Vertical mode draws via a bare `CTFrameDraw` with no line drawer, so the box is
/// filled here — before `CTFrameDraw`, so the glyphs sit on top — reusing
/// `CoreTextAnnotationRenderer`'s vertical rect geometry (the same math that positions vertical
/// annotation highlights, so alignment matches without re-deriving column coordinates).
///
/// Dialogue spans are marked with `DialogueHighlighter.boxColorAttribute` (value: `UIColor`).
enum CoreTextDialogueBox {

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
            guard !uiRects.isEmpty else { return }

            ctx.saveGState()
            ctx.setFillColor(color.cgColor)
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
                let radius = max(0, min(4, min(boxRect.width, boxRect.height) / 2))
                ctx.addPath(UIBezierPath(roundedRect: boxRect, cornerRadius: radius).cgPath)
            }
            ctx.fillPath()
            ctx.restoreGState()
        }
    }
}
