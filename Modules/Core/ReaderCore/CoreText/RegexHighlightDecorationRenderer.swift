import CoreText
import UIKit

/// Paints immutable regex-highlight decorations before CoreText draws their glyphs.
/// Image lookup is cache-only: drawing never performs file I/O or image decoding.
enum RegexHighlightDecorationRenderer {
    struct Fragment {
        let range: NSRange
        let rect: CGRect
        let decoration: RegexHighlightDecoration
    }

    static func drawHorizontal(
        line: CTLine,
        origin: CGPoint,
        attributedString: NSAttributedString,
        range: NSRange,
        context: CGContext
    ) {
        let fragments = horizontalFragments(
            line: line,
            origin: origin,
            attributedString: attributedString,
            range: range
        )
        guard !fragments.isEmpty else { return }
        paint(fragments: fragments, writingMode: .horizontal, context: context)
    }

    /// Builds the decoration rects for one drawn line.
    ///
    /// `line` is the line as it will actually be drawn, which is not always the CTFrame's own line:
    /// `CoreTextHorizontalLineDrawer` rebuilds every justified line from that line's attributed
    /// substring, and a line built that way indexes its characters from 0 — while `range` and the
    /// decoration attribute runs are absolute indices into `attributedString`. Feeding absolute
    /// indices to such a line clamps them to its end, which collapses the fragment to zero width
    /// (highlight silently loses its background) or anchors it at the wrong character. Every index
    /// is therefore rebased into the line's own index space before it reaches CoreText.
    static func horizontalFragments(
        line: CTLine,
        origin: CGPoint,
        attributedString: NSAttributedString,
        range: NSRange
    ) -> [Fragment] {
        let boundedRange = NSIntersectionRange(
            range,
            NSRange(location: 0, length: attributedString.length)
        )
        guard boundedRange.length > 0 else { return [] }

        let lineStringRange = CTLineGetStringRange(line)
        let lineLowerBound = lineStringRange.location
        let lineUpperBound = lineStringRange.location + max(0, lineStringRange.length)
        let indexShift = lineLowerBound - boundedRange.location

        var lineAscent: CGFloat = 0
        var lineDescent: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &lineAscent, &lineDescent, nil)

        var fragments: [Fragment] = []
        attributedString.enumerateAttribute(
            RegexHighlightDecoration.attributeKey,
            in: boundedRange,
            options: []
        ) { value, highlightedRange, _ in
            guard let decoration = value as? RegexHighlightDecoration,
                  highlightedRange.length > 0 else { return }

            let startIndex = clamped(
                highlightedRange.location + indexShift,
                lowerBound: lineLowerBound,
                upperBound: lineUpperBound
            )
            let endIndex = clamped(
                NSMaxRange(highlightedRange) + indexShift,
                lowerBound: lineLowerBound,
                upperBound: lineUpperBound
            )
            guard endIndex > startIndex else { return }

            let startOffset = CGFloat(CTLineGetOffsetForStringIndex(line, startIndex, nil))
            let endOffset = CGFloat(CTLineGetOffsetForStringIndex(line, endIndex, nil))
            guard startOffset.isFinite, endOffset.isFinite,
                  abs(endOffset - startOffset) > 0.25 else { return }

            let ascent: CGFloat
            let descent: CGFloat
            if let font = attributedString.attribute(
                .font,
                at: highlightedRange.location,
                effectiveRange: nil
            ) as? UIFont {
                ascent = font.ascender
                descent = -font.descender
            } else {
                ascent = lineAscent
                descent = lineDescent
            }

            let glyphRect = CGRect(
                x: origin.x + min(startOffset, endOffset),
                y: origin.y - descent,
                width: abs(endOffset - startOffset),
                height: max(1, ascent + descent)
            )
            let logicalEdges = RegexHighlightDecorationGeometry.combinedEdges(
                padding: decoration.style.padding,
                margin: decoration.style.margin
            )
            // `expandedRect` uses UIKit top-down edges; swap vertical edges for this y-up context.
            let coreTextEdges = ReaderStyleEdges(
                top: logicalEdges.bottom,
                leading: logicalEdges.leading,
                bottom: logicalEdges.top,
                trailing: logicalEdges.trailing
            )
            let expanded = RegexHighlightDecorationGeometry.expandedRect(
                glyphRect: glyphRect,
                padding: coreTextEdges,
                writingMode: .horizontal
            )
            fragments.append(
                Fragment(range: highlightedRange, rect: expanded, decoration: decoration)
            )
        }

        guard !fragments.isEmpty else { return [] }
        fragments.sort { $0.range.location < $1.range.location }
        let orderedFragments = fragments
        return orderedFragments.enumerated().map { index, fragment in
            let previousIsAdjacent = index > 0
                && NSMaxRange(orderedFragments[index - 1].range) == fragment.range.location
            let nextIsAdjacent = index + 1 < orderedFragments.count
                && NSMaxRange(fragment.range) == orderedFragments[index + 1].range.location
            let rect = RegexHighlightDecorationGeometry.applyingInlineGap(
                to: fragment.rect,
                gap: CGFloat(fragment.decoration.style.visualGap ?? 0),
                hasPreviousFragment: previousIsAdjacent,
                hasNextFragment: nextIsAdjacent,
                writingMode: .horizontal
            )
            return Fragment(range: fragment.range, rect: rect, decoration: fragment.decoration)
        }
    }

    private static func clamped(_ index: Int, lowerBound: Int, upperBound: Int) -> Int {
        min(max(index, lowerBound), upperBound)
    }

    static func drawVertical(
        frame: CTFrame,
        attributedString: NSAttributedString,
        contentOffset: CGPoint,
        layoutHeight: CGFloat,
        writingMode: ReaderWritingMode,
        suppressedRanges: [NSRange] = [],
        context: CGContext
    ) {
        guard writingMode.isVertical else { return }
        let lines = CTFrameGetLines(frame) as! [CTLine]
        guard !lines.isEmpty else { return }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRangeMake(0, lines.count), &origins)

        let frameRange = CTFrameGetStringRange(frame)
        let boundedRange = NSIntersectionRange(
            NSRange(location: max(0, frameRange.location), length: max(0, frameRange.length)),
            NSRange(location: 0, length: attributedString.length)
        )
        guard boundedRange.length > 0 else { return }

        var fragments: [Fragment] = []
        attributedString.enumerateAttribute(
            RegexHighlightDecoration.attributeKey,
            in: boundedRange,
            options: []
        ) { value, highlightedRange, _ in
            guard let decoration = value as? RegexHighlightDecoration,
                  highlightedRange.length > 0,
                  !suppressedRanges.contains(where: {
                      NSIntersectionRange($0, highlightedRange).length > 0
                  }) else { return }
            let rects = CoreTextAnnotationRenderer.rects(
                forRange: highlightedRange,
                lines: lines,
                lineOrigins: origins,
                contentOffset: contentOffset,
                layoutHeight: layoutHeight,
                writingMode: writingMode
            )
            let logicalEdges = RegexHighlightDecorationGeometry.combinedEdges(
                padding: decoration.style.padding,
                margin: decoration.style.margin
            )
            for uiRect in rects {
                let expanded = RegexHighlightDecorationGeometry.expandedRect(
                    glyphRect: uiRect,
                    padding: logicalEdges,
                    writingMode: writingMode
                )
                let coreTextRect = CGRect(
                    x: expanded.minX,
                    y: layoutHeight - expanded.maxY,
                    width: expanded.width,
                    height: expanded.height
                )
                fragments.append(
                    Fragment(range: highlightedRange, rect: coreTextRect, decoration: decoration)
                )
            }
        }

        guard !fragments.isEmpty else { return }
        fragments.sort {
            if $0.rect.midX != $1.rect.midX { return $0.rect.midX > $1.rect.midX }
            return $0.rect.minY > $1.rect.minY
        }
        let orderedFragments = fragments
        fragments = orderedFragments.enumerated().map { index, fragment in
            let previousIsAdjacent = index > 0
                && sameVerticalColumn(orderedFragments[index - 1].rect, fragment.rect)
                && rangesTouch(orderedFragments[index - 1].range, fragment.range)
            let nextIsAdjacent = index + 1 < orderedFragments.count
                && sameVerticalColumn(fragment.rect, orderedFragments[index + 1].rect)
                && rangesTouch(fragment.range, orderedFragments[index + 1].range)
            let rect = applyVerticalCoreTextGap(
                to: fragment.rect,
                gap: CGFloat(fragment.decoration.style.visualGap ?? 0),
                hasPrevious: previousIsAdjacent,
                hasNext: nextIsAdjacent
            )
            return Fragment(range: fragment.range, rect: rect, decoration: fragment.decoration)
        }

        paint(fragments: fragments, writingMode: writingMode, context: context)
    }

    private static func paint(
        fragments: [Fragment],
        writingMode: ReaderWritingMode,
        context: CGContext
    ) {
        let drawable = fragments.filter { $0.rect.width > 0.5 && $0.rect.height > 0.5 }
        guard !drawable.isEmpty else { return }

        for fragment in drawable { drawShadows(for: fragment, context: context) }
        for fragment in drawable { drawBackground(for: fragment, context: context) }
        for fragment in drawable { drawImage(for: fragment, context: context) }
        for fragment in drawable {
            drawBorders(for: fragment, writingMode: writingMode, context: context)
        }
    }

    private static func drawShadows(for fragment: Fragment, context: CGContext) {
        let style = fragment.decoration.style
        guard !style.shadows.isEmpty else { return }
        let path = roundedPath(rect: fragment.rect, radius: style.cornerRadius)

        for shadow in style.shadows {
            let spread = max(8, CGFloat(shadow.radius) * 4 + abs(CGFloat(shadow.x)) + abs(CGFloat(shadow.y)))
            let clipRect = fragment.rect.insetBy(dx: -spread, dy: -spread)
            context.saveGState()
            context.setAlpha(CGFloat(style.opacity ?? 1))
            context.addRect(clipRect)
            context.addPath(path)
            context.clip(using: .evenOdd)
            context.setShadow(
                offset: CGSize(width: CGFloat(shadow.x), height: -CGFloat(shadow.y)),
                blur: CGFloat(shadow.radius),
                color: color(hex: shadow.colorHex).cgColor
            )
            context.setFillColor(UIColor.black.cgColor)
            context.addPath(path)
            context.fillPath()
            context.restoreGState()
        }
    }

    private static func drawBackground(for fragment: Fragment, context: CGContext) {
        let style = fragment.decoration.style
        guard style.backgroundColorHex != nil || style.backgroundGradient != nil else { return }

        context.saveGState()
        context.setAlpha(CGFloat(style.opacity ?? 1))
        let path = roundedPath(rect: fragment.rect, radius: style.cornerRadius)
        context.addPath(path)
        context.clip()

        if let hex = style.backgroundColorHex {
            context.setFillColor(color(hex: hex).cgColor)
            context.fill(fragment.rect)
        }
        if let gradient = style.backgroundGradient {
            drawGradient(gradient, in: fragment.rect, context: context)
        }
        context.restoreGState()
    }

    private static func drawImage(for fragment: Fragment, context: CGContext) {
        let style = fragment.decoration.style
        guard let presentation = style.backgroundImage,
              let image = fragment.decoration.cachedBackgroundImage,
              let cgImage = image.cgImage else { return }

        context.saveGState()
        context.setAlpha(CGFloat(style.opacity ?? 1) * CGFloat(presentation.opacity))
        context.addPath(roundedPath(rect: fragment.rect, radius: style.cornerRadius))
        context.clip()
        context.interpolationQuality = .high

        switch presentation.contentMode {
        case .tile:
            let anchor = RegexHighlightImageGeometry.destination(
                source: image.size,
                bounds: fragment.rect,
                mode: .tile,
                focalX: CGFloat(presentation.focalX),
                focalY: 1 - CGFloat(presentation.focalY)
            ).origin
            drawTiledImage(
                cgImage,
                pointSize: image.size,
                anchor: anchor,
                in: fragment.rect,
                context: context
            )
        case .fit, .fill, .stretch:
            let destination = RegexHighlightImageGeometry.destination(
                source: image.size,
                bounds: fragment.rect,
                mode: presentation.contentMode,
                focalX: CGFloat(presentation.focalX),
                focalY: 1 - CGFloat(presentation.focalY)
            )
            drawUpright(cgImage, in: destination, context: context)
        }
        context.restoreGState()
    }

    private static func drawBorders(
        for fragment: Fragment,
        writingMode: ReaderWritingMode,
        context: CGContext
    ) {
        let style = fragment.decoration.style
        guard let borders = style.borders, !borders.isEmpty else { return }
        let active = borders.filter { $0.value.width > 0 }
        guard !active.isEmpty else { return }

        context.saveGState()
        context.setAlpha(CGFloat(style.opacity ?? 1))

        if let first = active.first?.value,
           active.count == ReaderStyleEdge.allCases.count,
           active.values.allSatisfy({ $0 == first }) {
            let width = CGFloat(first.width)
            let strokeRect = fragment.rect.insetBy(dx: width / 2, dy: width / 2)
            context.setStrokeColor(color(hex: first.colorHex).cgColor)
            context.setLineWidth(width)
            context.addPath(roundedPath(rect: strokeRect, radius: style.cornerRadius))
            context.strokePath()
            context.restoreGState()
            return
        }

        for edge in ReaderStyleEdge.allCases {
            guard let border = active[edge] else { continue }
            let width = CGFloat(border.width)
            let segment = borderSegment(
                edge: edge,
                rect: fragment.rect.insetBy(dx: width / 2, dy: width / 2),
                writingMode: writingMode
            )
            context.setStrokeColor(color(hex: border.colorHex).cgColor)
            context.setLineWidth(width)
            context.move(to: segment.start)
            context.addLine(to: segment.end)
            context.strokePath()
        }
        context.restoreGState()
    }

    private static func drawGradient(
        _ gradient: ReaderStyleGradient,
        in rect: CGRect,
        context: CGContext
    ) {
        let sorted = gradient.stops.sorted { $0.location < $1.location }
        guard !sorted.isEmpty else { return }
        let stops = sorted.count == 1 ? [sorted[0], sorted[0]] : sorted
        guard let cgGradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: stops.map { color(hex: $0.colorHex).cgColor } as CFArray,
            locations: stops.map { CGFloat($0.location) }
        ) else { return }

        let radians = CGFloat(gradient.angleDegrees) * .pi / 180
        let direction = CGPoint(x: sin(radians), y: cos(radians))
        let halfLength = abs(direction.x) * rect.width / 2
            + abs(direction.y) * rect.height / 2
        let start = CGPoint(
            x: rect.midX - direction.x * halfLength,
            y: rect.midY - direction.y * halfLength
        )
        let end = CGPoint(
            x: rect.midX + direction.x * halfLength,
            y: rect.midY + direction.y * halfLength
        )
        context.drawLinearGradient(
            cgGradient,
            start: start,
            end: end,
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }

    private static func drawTiledImage(
        _ image: CGImage,
        pointSize: CGSize,
        anchor: CGPoint,
        in bounds: CGRect,
        context: CGContext
    ) {
        guard pointSize.width > 0, pointSize.height > 0 else { return }
        // CGContext's tiled-image API scales one tile to this rect, anchors it at the rect origin,
        // then repeats in user space. Reflect the anchor while correcting CGImage's y orientation.
        let reflectionAxis = bounds.minY + bounds.maxY
        let reflectedAnchorY = reflectionAxis - anchor.y - pointSize.height
        let tileRect = CGRect(
            x: anchor.x,
            y: reflectedAnchorY,
            width: pointSize.width,
            height: pointSize.height
        )
        context.saveGState()
        context.translateBy(x: 0, y: reflectionAxis)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: tileRect, byTiling: true)
        context.restoreGState()
    }

    private static func drawUpright(
        _ image: CGImage,
        in rect: CGRect,
        context: CGContext
    ) {
        guard rect.width > 0, rect.height > 0 else { return }
        context.saveGState()
        context.translateBy(x: 0, y: rect.minY + rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: rect)
        context.restoreGState()
    }

    private static func roundedPath(rect: CGRect, radius: Double?) -> CGPath {
        let safeRadius = min(
            max(0, CGFloat(radius ?? 0)),
            min(rect.width, rect.height) / 2
        )
        return UIBezierPath(roundedRect: rect, cornerRadius: safeRadius).cgPath
    }

    private static func borderSegment(
        edge: ReaderStyleEdge,
        rect: CGRect,
        writingMode: ReaderWritingMode
    ) -> (start: CGPoint, end: CGPoint) {
        if writingMode.isVertical {
            switch edge {
            case .top:
                return (CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY))
            case .leading:
                return (CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY))
            case .bottom:
                return (CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY))
            case .trailing:
                return (CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY))
            }
        }
        switch edge {
        case .top:
            return (CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY))
        case .leading:
            return (CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY))
        case .bottom:
            return (CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY))
        case .trailing:
            return (CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY))
        }
    }

    private static func sameVerticalColumn(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        max(lhs.minX, rhs.minX) < min(lhs.maxX, rhs.maxX)
    }

    private static func rangesTouch(_ lhs: NSRange, _ rhs: NSRange) -> Bool {
        NSMaxRange(lhs) == rhs.location || NSMaxRange(rhs) == lhs.location || lhs == rhs
    }

    private static func applyVerticalCoreTextGap(
        to rect: CGRect,
        gap: CGFloat,
        hasPrevious: Bool,
        hasNext: Bool
    ) -> CGRect {
        let safeGap = max(0, gap)
        let topGap = hasPrevious ? safeGap / 2 : 0
        let bottomGap = hasNext ? safeGap / 2 : 0
        return CGRect(
            x: rect.minX,
            y: rect.minY + bottomGap,
            width: rect.width,
            height: max(0, rect.height - topGap - bottomGap)
        )
    }

    private static func color(hex: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
