import YueduCoreText
import CoreText
import UIKit

/// Paints 對話氣泡 behind the glyphs of the paragraphs
/// `ReaderDialogueBubbleMarker` marked.
///
/// Works on whole paragraphs, not on single lines: a bubble is one rounded box
/// around every line of its paragraph, so the rects have to be unioned before
/// anything is drawn. Image lookup is cache-only — drawing never decodes or
/// reads from disk.
enum ReaderDialogueBubbleRenderer {
    /// The 5px lip the WeChat-style templates put below the tail's base, in
    /// multiples of the 66px dialogue font they lay out with.
    private static let tailLipEm: CGFloat = 5.0 / 66

    struct Bubble {
        let mark: ReaderDialogueBubbleMark
        let rect: CGRect
        /// One line's height, which is what a skin's artwork is drawn against.
        let lineHeight: CGFloat
    }

    /// Groups a frame's lines into bubbles.
    ///
    /// `origins` must already carry every shift the caller applies when drawing
    /// the glyphs (the horizontal drawer redistributes bottom slack across
    /// paragraph gaps), otherwise the bubble detaches from its own text.
    static func bubbles(
        lines: [CTLine],
        origins: [CGPoint],
        attributedString: NSAttributedString,
        writingMode: ReaderWritingMode
    ) -> [Bubble] {
        // Vertical writing has no chat-bubble geometry to speak of: sides become
        // top/bottom and the tail points the wrong way. 對話氣泡 stays a
        // horizontal feature, and vertical keeps the inline 對話 decoration.
        guard !writingMode.isVertical,
              lines.count == origins.count,
              attributedString.length > 0 else {
            return []
        }

        var bubbles: [Bubble] = []
        var currentMark: ReaderDialogueBubbleMark?
        var currentRect: CGRect = .null
        var currentLineHeight: CGFloat = 0

        func flush() {
            if let mark = currentMark, !currentRect.isNull {
                bubbles.append(
                    Bubble(
                        mark: mark,
                        rect: padded(currentRect, mark: mark),
                        lineHeight: currentLineHeight
                    )
                )
            }
            currentMark = nil
            currentRect = .null
            currentLineHeight = 0
        }

        for (index, line) in lines.enumerated() {
            let mark = self.mark(of: line, in: attributedString)
            guard let mark else {
                flush()
                continue
            }
            if currentMark !== mark {
                flush()
                currentMark = mark
            }
            let glyph = glyphRect(of: line, origin: origins[index])
            currentLineHeight = max(currentLineHeight, glyph.height)
            currentRect = currentRect.union(glyph)
        }
        flush()
        return bubbles
    }

    static func draw(_ bubbles: [Bubble], context: CGContext) {
        for bubble in bubbles where bubble.rect.width > 0.5 && bubble.rect.height > 0.5 {
            draw(bubble, context: context)
        }
    }

    // MARK: - Geometry

    private static func mark(
        of line: CTLine,
        in attributedString: NSAttributedString
    ) -> ReaderDialogueBubbleMark? {
        let range = CTLineGetStringRange(line)
        guard range.length > 0, range.location >= 0,
              range.location < attributedString.length else {
            return nil
        }
        return attributedString.attribute(
            ReaderDialogueBubbleMarker.attributeKey,
            at: range.location,
            effectiveRange: nil
        ) as? ReaderDialogueBubbleMark
    }

    private static func glyphRect(of line: CTLine, origin: CGPoint) -> CGRect {
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        // Trailing whitespace is part of the line's advance but not of the text
        // the bubble should wrap.
        let visibleWidth = max(0, width - CGFloat(CTLineGetTrailingWhitespaceWidth(line)))
        return CGRect(
            x: origin.x,
            y: origin.y - descent,
            width: visibleWidth,
            height: max(1, ascent + descent)
        )
    }

    private static func padded(_ rect: CGRect, mark: ReaderDialogueBubbleMark) -> CGRect {
        rect.insetBy(
            dx: -mark.metrics.horizontalPadding,
            dy: -mark.metrics.verticalPadding
        )
    }

    // MARK: - Painting

    private static func draw(_ bubble: Bubble, context: CGContext) {
        let style = bubble.mark.style
        let metrics = bubble.mark.metrics
        drawAvatar(bubble, context: context)
        drawName(bubble, context: context)
        defer { drawDecoration(bubble, context: context) }

        if let skin = style.skin,
           let image = ReaderStyleAssetImageCache.shared.image(for: skin.assetID)?.cgImage {
            context.saveGState()
            context.setAlpha(CGFloat(skin.opacity))
            context.interpolationQuality = .high
            drawNineSlice(
                image,
                skin: skin,
                lineHeight: max(bubble.lineHeight, metrics.bodyFontSize),
                in: bubble.rect,
                context: context
            )
            context.restoreGState()
            // A skinned bubble is exactly its artwork: the templates that ship
            // one keep border and tail off by default, and drawing ours on top
            // of a decorated PNG is how a bubble ends up with two outlines.
            return
        }

        let radius = min(
            metrics.cornerRadius,
            min(bubble.rect.width, bubble.rect.height) / 2
        )
        let path = UIBezierPath(roundedRect: bubble.rect, cornerRadius: radius).cgPath
        let fill = GlobalSettings.uiColor(rgbHex: style.fillHex)

        context.saveGState()
        if let tail = tailPath(for: bubble) {
            context.setFillColor(fill.cgColor)
            context.addPath(tail)
            context.fillPath()
        }
        context.setFillColor(fill.cgColor)
        context.addPath(path)
        context.fillPath()

        if let borderHex = style.borderHex, metrics.borderWidth > 0 {
            let inset = bubble.rect.insetBy(
                dx: metrics.borderWidth / 2,
                dy: metrics.borderWidth / 2
            )
            context.setStrokeColor(GlobalSettings.uiColor(rgbHex: borderHex).cgColor)
            context.setLineWidth(metrics.borderWidth)
            context.addPath(
                UIBezierPath(roundedRect: inset, cornerRadius: radius).cgPath
            )
            context.strokePath()
        }
        context.restoreGState()
    }

    /// The sticker. Placed on the bubble's box exactly where the script places
    /// it — anchor fractions, jitter along that edge, rotation, then the 100×100
    /// unit box scaled to size. An outside sticker is stroked in the bubble's
    /// own colour first, so it reads as stuck on top rather than drawn into the
    /// artwork.
    private static func drawDecoration(_ bubble: Bubble, context: CGContext) {
        guard let decoration = bubble.mark.metrics.decoration, decoration.size > 0.5 else {
            return
        }
        let rect = bubble.rect
        let place = decoration.anchor.place(outside: decoration.isOutside)
        var x = rect.minX + rect.width * place.x + decoration.offsetX
        // SVG measures down from the bubble's top; this context measures up.
        var y = rect.maxY - rect.height * place.y - decoration.offsetY
        if decoration.anchor.jittersHorizontally {
            x += decoration.jitter
        } else {
            y += decoration.jitter
        }

        context.saveGState()
        context.setAlpha(decoration.opacity)
        context.translateBy(x: x, y: y)
        // SVG rotates clockwise; this context rotates counter-clockwise.
        context.rotate(by: -decoration.rotationDegrees * .pi / 180)
        let unit = decoration.size / 100
        context.scaleBy(x: unit, y: unit)
        context.translateBy(x: -50, y: -50)

        let parts = ReaderDialogueBubbleDecorationShape.parts(for: decoration.kind)
        if decoration.isOutside {
            context.setStrokeColor(
                GlobalSettings.uiColor(rgbHex: bubble.mark.style.fillHex).cgColor
            )
            context.setLineWidth(12)
            context.setLineJoin(.round)
            for part in parts {
                context.addPath(part.path)
                context.strokePath()
            }
        }
        for part in parts {
            context.setFillColor(
                GlobalSettings.uiColor(
                    rgbHex: part.fixedColorHex ?? decoration.colorHex
                ).cgColor
            )
            context.addPath(part.path)
            context.fillPath()
        }
        context.restoreGState()
    }

    /// The speaker label above the bubble, pinned to the bubble's near edge —
    /// drawn rather than inserted, so it never lands in selection, search or TTS.
    private static func drawName(_ bubble: Bubble, context: CGContext) {
        let metrics = bubble.mark.metrics
        guard let name = metrics.name, !name.isEmpty else { return }
        // Deliberately *not* the bubble's text colour: that one is chosen to sit
        // on the bubble's fill, and this label sits on the page behind it — a
        // white-on-dark bubble colour turns the name invisible on light paper.
        let color = UIColor.secondaryLabel
        let attributed = NSAttributedString(
            string: name,
            attributes: [
                .font: UserReaderFontResolver.bodyFont(
                    size: metrics.nameFontSize,
                    isBold: false
                ),
                .foregroundColor: color.withAlphaComponent(0.75),
            ]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        let originX: CGFloat
        switch bubble.mark.side {
        case .left: originX = bubble.rect.minX
        case .right: originX = bubble.rect.maxX - width
        }

        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = CGPoint(
            x: originX,
            y: bubble.rect.maxY + descent + metrics.nameFontSize * 0.25
        )
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// The portrait beside the bubble. Sits outside the bubble on its own side,
    /// top-aligned the way every chat client does it, in the gap the paragraph
    /// indents already reserved for it.
    private static func drawAvatar(_ bubble: Bubble, context: CGContext) {
        guard let avatar = bubble.mark.metrics.avatar,
              avatar.size > 0.5,
              let image = ReaderStyleAssetImageCache.shared.image(for: avatar.assetID)?.cgImage
        else {
            return
        }
        let rect = bubble.rect
        let originX: CGFloat
        switch bubble.mark.side {
        case .left:
            originX = rect.minX - avatar.gap - avatar.size + avatar.offsetX
        case .right:
            originX = rect.maxX + avatar.gap + avatar.offsetX
        }
        let frame = CGRect(
            x: originX,
            y: rect.maxY - avatar.size - avatar.offsetY,
            width: avatar.size,
            height: avatar.size
        )
        let radius = min(avatar.cornerRadius, avatar.size / 2)
        let path = UIBezierPath(roundedRect: frame, cornerRadius: radius).cgPath

        context.saveGState()
        context.interpolationQuality = .high
        if let backgroundHex = avatar.backgroundHex {
            context.setFillColor(GlobalSettings.uiColor(rgbHex: backgroundHex).cgColor)
            context.addPath(path)
            context.fillPath()
        }
        context.saveGState()
        context.addPath(path)
        context.clip()
        drawUpright(image, in: frame, context: context)
        context.restoreGState()
        if let borderHex = avatar.borderHex, avatar.borderWidth > 0 {
            context.setStrokeColor(GlobalSettings.uiColor(rgbHex: borderHex).cgColor)
            context.setLineWidth(avatar.borderWidth)
            context.addPath(
                UIBezierPath(
                    roundedRect: frame.insetBy(
                        dx: avatar.borderWidth / 2,
                        dy: avatar.borderWidth / 2
                    ),
                    cornerRadius: max(0, radius - avatar.borderWidth / 2)
                ).cgPath
            )
            context.strokePath()
        }
        context.restoreGState()
    }

    /// The tail as the WeChat-style templates draw it: a wedge whose tip sits
    /// `outside` past the bubble's near edge, `bottomOffset` up from the bottom.
    private static func tailPath(for bubble: Bubble) -> CGPath? {
        guard let tail = bubble.mark.metrics.tail, tail.width > 0, tail.height > 0 else {
            return nil
        }
        let rect = bubble.rect
        let baseY = rect.minY + tail.bottomOffset
        let lip = bubble.mark.metrics.bodyFontSize * tailLipEm
        let path = CGMutablePath()

        switch bubble.mark.side {
        case .left:
            path.move(to: CGPoint(x: rect.minX + tail.width, y: baseY + tail.height))
            path.addLine(to: CGPoint(x: rect.minX - tail.outside, y: baseY))
            path.addLine(to: CGPoint(x: rect.minX + tail.width, y: baseY - lip))
        case .right:
            path.move(to: CGPoint(x: rect.maxX - tail.width, y: baseY + tail.height))
            path.addLine(to: CGPoint(x: rect.maxX + tail.outside, y: baseY))
            path.addLine(to: CGPoint(x: rect.maxX - tail.width, y: baseY - lip))
        }
        path.closeSubpath()
        return path
    }

    /// Nine-patch: the corners keep a fixed size, the edges stretch along one
    /// axis and the centre along both. Slice sizes are source pixels; their
    /// destination size follows the reader's font.
    private static func drawNineSlice(
        _ image: CGImage,
        skin: ReaderDialogueBubbleSkin,
        lineHeight: CGFloat,
        in rect: CGRect,
        context: CGContext
    ) {
        let sourceWidth = CGFloat(image.width)
        let sourceHeight = CGFloat(image.height)
        guard sourceWidth > 0, sourceHeight > 0 else { return }

        // The artwork is drawn for a single-line bubble: its full height stands
        // for one line. Tying the scale to the line height (not to a fixed em
        // multiple) is what puts the corners where the artist drew them at any
        // type size — scaling each axis on its own instead squashes the corners
        // and leaves the banded, mis-assembled look.
        let source = Insets(
            top: CGFloat(skin.sliceTop),
            right: CGFloat(skin.sliceRight),
            bottom: CGFloat(skin.sliceBottom),
            left: CGFloat(skin.sliceLeft)
        ).fitted(within: CGSize(width: sourceWidth - 1, height: sourceHeight - 1))
        let baseScale = lineHeight
            * CGFloat(skin.targetHeightScale)
            * CGFloat(skin.cornerScale)
            / sourceHeight
        let neededWidth = (source.left + source.right) * baseScale
        let neededHeight = (source.top + source.bottom) * baseScale
        // Both axes shrink by the *same* factor when the corners do not fit, so
        // the artwork keeps its proportions.
        let fit = min(
            1,
            neededWidth > 0 ? rect.width / neededWidth : 1,
            neededHeight > 0 ? rect.height / neededHeight : 1
        )
        let scale = baseScale * max(0, fit)
        let destination = Insets(
            top: source.top * scale,
            right: source.right * scale,
            bottom: source.bottom * scale,
            left: source.left * scale
        )

        // Top-down source columns/rows, y-up destination columns/rows.
        let sourceX: [CGFloat] = [0, source.left, sourceWidth - source.right, sourceWidth]
        let sourceY: [CGFloat] = [0, source.top, sourceHeight - source.bottom, sourceHeight]
        let destinationX: [CGFloat] = [
            rect.minX,
            rect.minX + destination.left,
            rect.maxX - destination.right,
            rect.maxX,
        ]
        let destinationY: [CGFloat] = [
            rect.maxY,
            rect.maxY - destination.top,
            rect.minY + destination.bottom,
            rect.minY,
        ]

        for row in 0..<3 {
            for column in 0..<3 {
                let sourceRect = CGRect(
                    x: sourceX[column],
                    y: sourceY[row],
                    width: sourceX[column + 1] - sourceX[column],
                    height: sourceY[row + 1] - sourceY[row]
                )
                let destinationRect = CGRect(
                    x: destinationX[column],
                    y: destinationY[row + 1],
                    width: destinationX[column + 1] - destinationX[column],
                    height: destinationY[row] - destinationY[row + 1]
                )
                guard sourceRect.width >= 1, sourceRect.height >= 1,
                      destinationRect.width > 0.1, destinationRect.height > 0.1,
                      let piece = image.cropping(to: sourceRect) else {
                    continue
                }
                drawUpright(piece, in: destinationRect, context: context)
            }
        }
    }

    private struct Insets {
        var top: CGFloat
        var right: CGFloat
        var bottom: CGFloat
        var left: CGFloat

        /// Opposite slices that together exceed the box would overlap; shrink
        /// the pair proportionally instead, the way a platform nine-patch does.
        func fitted(within size: CGSize) -> Insets {
            var result = self
            let horizontal = left + right
            if horizontal > size.width, horizontal > 0 {
                let factor = size.width / horizontal
                result.left *= factor
                result.right *= factor
            }
            let vertical = top + bottom
            if vertical > size.height, vertical > 0 {
                let factor = size.height / vertical
                result.top *= factor
                result.bottom *= factor
            }
            return result
        }
    }

    /// Draws a CGImage the right way up.
    ///
    /// The line drawer hands us a context that has already been flipped to
    /// CoreText's y-up convention, and CoreGraphics draws images upright in a
    /// y-up context on its own. Flipping again — which is what this used to do,
    /// copied from a painter that runs elsewhere — turns every skin band and
    /// every avatar upside down.
    private static func drawUpright(_ image: CGImage, in rect: CGRect, context: CGContext) {
        guard rect.width > 0, rect.height > 0 else { return }
        context.draw(image, in: rect)
    }
}
