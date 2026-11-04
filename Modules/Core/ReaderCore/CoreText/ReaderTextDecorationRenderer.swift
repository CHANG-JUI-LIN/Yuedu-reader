import CoreText
import UIKit
import YueduCoreText

/// Authored `text-decoration` lines on a run of text (`HTMLAttributedStringBuilder.textDecorationAttribute`):
/// the lines of every decorating box the run is in, outermost first, as CSS propagates them.
final class ReaderTextDecorationMark: NSObject {
    let decorations: [RenderTextDecoration]

    init(_ decorations: [RenderTextDecoration]) {
        self.decorations = decorations
    }

    override func isEqual(_ object: Any?) -> Bool {
        (object as? ReaderTextDecorationMark)?.decorations == decorations
    }

    override var hash: Int { decorations.count }
}

/// Draws legacy's authored decoration lines, paged and scrolled, in both writing modes.
///
/// Core Text cannot: it has no line-through, no overline and no wavy line, and draws
/// `.underlineStyle` on the left of a vertical line only (probe, iOS 27.2 simulator, 2026-11-04;
/// Aozora plan, Task 7). Before this, legacy's `<s>` and `<del>` were never struck through.
///
/// Lines are placed and drawn as the browser engine places and draws them (YueduCoreText
/// `TextDecorationLayout` and `TextDecorationPainter`, after WebKit `TextBoxPainter`), with the
/// text's own font placing them: legacy has no inline box tree, so a decorating box's lines follow
/// each run's font where WebKit keeps the box's. In each run's own frame, x runs along the line from
/// the run's start and y from its baseline toward the under side: down, and left in vertical-rl.
/// Thickness is `font-size / 16`; the gap off the text `max(1, ceil(font-size / 32))`.
/// - Underline: the gap below the baseline; vertically, the gap beyond the left edge of the text's
///   content box, or its right edge for `text-underline-position: right`.
/// - Overline: at the content box's top; vertically, the gap beyond the side the underline is not on.
/// - Line-through: two thirds of the ascent below the content box's top, which in vertical-rl is
///   its right edge.
///
/// Underlines do not skip the ink of Latin descenders, as the browser engine's do.
enum ReaderTextDecorationRenderer {
    /// Under- and overlines go under the glyphs, line-throughs over them, as in WebKit.
    enum Layer {
        case underText
        case overText

        func includes(_ line: RenderTextDecoration.Lines) -> Bool {
            switch self {
            case .underText: line != .lineThrough
            case .overText: line == .lineThrough
            }
        }
    }

    /// One drawn line of a horizontal frame. `range` is the line's range in `attributedString`;
    /// `line` may be rebuilt from its substring (`RegexHighlightDecorationRenderer.horizontalSpans`).
    static func drawHorizontal(
        line: CTLine,
        origin: CGPoint,
        attributedString: NSAttributedString,
        range: NSRange,
        layer: Layer,
        context: CGContext
    ) {
        let spans = RegexHighlightDecorationRenderer.horizontalSpans(
            of: HTMLAttributedStringBuilder.textDecorationAttribute,
            line: line,
            attributedString: attributedString,
            range: range
        )
        for span in spans {
            guard let mark = span.value as? ReaderTextDecorationMark else { continue }
            let drawing = RegexHighlightDecorationRenderer.dominantDrawing(of: span.range, in: attributedString)
            guard let font = drawing.font else { continue }
            context.saveGState()
            // The context runs y up: the run's frame turns it down from the raised baseline.
            context.translateBy(x: origin.x + span.start, y: origin.y + drawing.raise)
            context.scaleBy(x: 1, y: -1)
            paint(mark.decorations, layer: layer, font: font, vertical: false, length: span.end - span.start,
                  textColor: textColor(of: span.range, in: attributedString), context: context)
            context.restoreGState()
        }
    }

    /// Every decorated run of a vertical frame, in a context flipped to Core Text's y-up
    /// coordinates over a canvas `layoutHeight` tall.
    static func drawVertical(
        frame: CTFrame,
        attributedString: NSAttributedString,
        contentOffset: CGPoint,
        layoutHeight: CGFloat,
        suppressedRanges: [NSRange] = [],
        layer: Layer,
        context: CGContext
    ) {
        let lines = CTFrameGetLines(frame) as! [CTLine]
        guard !lines.isEmpty else { return }
        let frameRange = CTFrameGetStringRange(frame)
        let boundedRange = NSIntersectionRange(
            NSRange(location: max(0, frameRange.location), length: max(0, frameRange.length)),
            NSRange(location: 0, length: attributedString.length)
        )
        guard boundedRange.length > 0 else { return }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRangeMake(0, lines.count), &origins)

        attributedString.enumerateAttribute(
            HTMLAttributedStringBuilder.textDecorationAttribute,
            in: boundedRange,
            options: []
        ) { value, range, _ in
            guard let mark = value as? ReaderTextDecorationMark,
                  !suppressedRanges.contains(where: { NSIntersectionRange($0, range).length > 0 }),
                  let font = RegexHighlightDecorationRenderer.dominantDrawing(
                      of: range, in: attributedString, inVerticalLine: true).font else { return }
            let color = textColor(of: range, in: attributedString)
            // Each column's glyph box, centred on the text as the browser engine centres a
            // vertical line's text.
            for rect in RegexHighlightDecorationRenderer.verticalGlyphRects(
                of: range,
                lines: lines,
                origins: origins,
                attributedString: attributedString,
                contentOffset: contentOffset,
                layoutHeight: layoutHeight
            ) {
                context.saveGState()
                // x down the column from the run's top, y leftward from its centre, in the
                // y-up context: (x, y) ↦ (centre − y, layoutHeight − top − x).
                context.concatenate(CGAffineTransform(
                    a: 0, b: -1, c: -1, d: 0, tx: rect.midX, ty: layoutHeight - rect.minY))
                paint(mark.decorations, layer: layer, font: font, vertical: true, length: rect.height,
                      textColor: color, context: context)
                context.restoreGState()
            }
        }
    }

    /// How far a decoration in `font` may reach beyond the text's glyph box, for culling.
    static func reach(fontSize: CGFloat) -> CGFloat {
        fontSize * 4 / 16 + 2
    }

    /// A decoration with no colour of its own takes its decorating box's text colour, which is
    /// then the theme's (`HTMLAttributedStringBuilder.resolvedStyle`): the colour of the characters
    /// with no authored colour, which a theme change recolours (`withUpdatedAppearance`). Where
    /// every character of the run has one, its first character's stands in.
    private static func textColor(of range: NSRange, in string: NSAttributedString) -> UIColor {
        var themed: UIColor?
        string.enumerateAttributes(in: range, options: []) { attributes, _, stop in
            guard attributes[HTMLAttributedStringBuilder.cssSpecifiedForegroundColorAttribute] == nil else { return }
            themed = attributes[.foregroundColor] as? UIColor
            stop.pointee = true
        }
        return themed
            ?? string.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? UIColor
            ?? .label
    }

    private static func paint(
        _ decorations: [RenderTextDecoration],
        layer: Layer,
        font: UIFont,
        vertical: Bool,
        length: CGFloat,
        textColor: UIColor,
        context: CGContext
    ) {
        guard length > 0 else { return }
        let size = font.pointSize
        let ascent = ceil(font.ascender)
        let contentHeight = ascent + ceil(-font.descender)
        let gap = max(1, ceil(size / 16 / 2))
        // The content box's top, from the baseline; a vertical line's baseline is its centre.
        let top = vertical ? -contentHeight / 2 : -ascent
        let toDevice = context.userSpaceToDeviceSpaceTransform
        for decoration in decorations {
            let wavy: CGFloat = decoration.style == .wavy ? 1 : 0
            let color = decoration.color?.uiColor ?? textColor
            for line in [RenderTextDecoration.Lines.underline, .overline, .lineThrough]
            where decoration.lines.contains(line) && layer.includes(line) {
                let fromTop: CGFloat
                switch line {
                case .underline:
                    if vertical {
                        fromTop = decoration.underlineRight ? -gap : contentHeight + gap
                    } else {
                        fromTop = ascent + gap
                    }
                    draw(position: top + fromTop + wavy, line: line, style: decoration.style, color: color,
                         size: size, length: length, toDevice: toDevice, context: context)
                case .overline:
                    let over: CGFloat = vertical ? (decoration.underlineRight ? contentHeight + gap : -gap) : 0
                    draw(position: top + over - wavy, line: line, style: decoration.style, color: color,
                         size: size, length: length, toDevice: toDevice, context: context)
                default:
                    draw(position: top + 2 * ascent / 3, line: line, style: decoration.style, color: color,
                         size: size, length: length, toDevice: toDevice, context: context)
                }
            }
        }
    }

    /// One line, its thickness rounded up to device pixels and its edge snapped to one, as the
    /// browser engine draws it (YueduCoreText `TextDecorationPainter.rect`): an underline or an
    /// overline to the nearest pixel, a line-through to the next one away from the text.
    private static func draw(
        position: CGFloat,
        line: RenderTextDecoration.Lines,
        style: RenderTextDecoration.Style,
        color: UIColor,
        size: CGFloat,
        length: CGFloat,
        toDevice: CGAffineTransform,
        context: CGContext
    ) {
        let scale = max(1e-6, hypot(toDevice.a, toDevice.b))
        let thickness = max(ceil(size / 16 * scale - 1e-6) / scale, 0.5)
        let device = CGPoint(x: 0, y: position).applying(toDevice)
        let snappedY = line == .lineThrough
            ? (toDevice.d < 0 ? floor(device.y) : ceil(device.y))
            : device.y.rounded()
        let origin = CGPoint(x: device.x.rounded(), y: snappedY).applying(toDevice.inverted())
        let rect = CGRect(x: origin.x, y: origin.y, width: length, height: thickness)

        context.saveGState()
        defer { context.restoreGState() }
        if style == .wavy {
            strokeWave(rect, amplitude: size * 1.5 / 16, step: size / 4.5, color: color, context: context)
            return
        }
        context.setFillColor(color.cgColor)
        for piece in rects(of: rect, style: style) { context.fill(piece) }
    }

    /// A dot as long as the line is thick, a dash twice that, with gaps as long; a double line
    /// repeats one thickness below the first (`TextDecorationPainter.rects`).
    private static func rects(of rect: CGRect, style: RenderTextDecoration.Style) -> [CGRect] {
        let thickness = rect.height
        let dash: CGFloat = style == .dotted ? thickness : style == .dashed ? 2 * thickness : 0
        guard dash > 0 else {
            return style == .double ? [rect, rect.offsetBy(dx: 0, dy: 2 * thickness)] : [rect]
        }
        var result: [CGRect] = []
        var x: CGFloat = 0
        while x < rect.width {
            result.append(CGRect(x: rect.minX + x, y: rect.minY, width: min(dash, rect.width - x), height: thickness))
            x += 2 * dash
        }
        return result
    }

    /// Cubic waves along the rect's top edge, started two steps early and clipped to the rect's
    /// length (`TextDecorationPainter.strokeWave`, after WebKit `strokeWavyTextDecoration`).
    private static func strokeWave(_ rect: CGRect, amplitude: CGFloat, step: CGFloat, color: UIColor,
                                   context: CGContext) {
        var y = rect.minY
        // An odd whole thickness sits half a point lower (`adjustLineToPixelBoundaries`).
        if Int(rect.height) % 2 == 1 { y += 0.5 }
        let x1 = rect.minX - 2 * step, x2 = rect.maxX + 2 * step
        guard step >= 1, (x2 - x1) / (2 * step) <= 1024 else {
            context.setFillColor(color.cgColor)
            context.fill(rect)
            return
        }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x1, y: y))
        var x = x1
        while x + 2 * step <= x2 {
            let control = x + step
            x += 2 * step
            path.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: control, y: y + amplitude),
                          control2: CGPoint(x: control, y: y - amplitude))
        }
        context.clip(to: rect.insetBy(dx: 0, dy: -amplitude))
        context.setShouldAntialias(true)
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(rect.height)
        context.addPath(path)
        context.strokePath()
    }
}
