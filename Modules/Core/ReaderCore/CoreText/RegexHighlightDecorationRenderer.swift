import YueduCoreText
import CoreText
import UIKit
import YueduCoreTextTypography

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
        // Where the line's text ends (`contentEnd`), in the line's own indices.
        let textUpperBound = contentEnd(
            of: NSIntersectionRange(
                NSRange(location: boundedRange.location, length: lineUpperBound - lineLowerBound),
                NSRange(location: 0, length: attributedString.length)
            ),
            in: attributedString.string as NSString
        ) + indexShift

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
                upperBound: textUpperBound
            )
            let endIndex = clamped(
                NSMaxRange(highlightedRange) + indexShift,
                lowerBound: lineLowerBound,
                upperBound: textUpperBound
            )
            guard endIndex > startIndex else { return }

            let startOffset = CGFloat(GlyphBoundary.offset(line, at: startIndex))
            let endOffset = CGFloat(GlyphBoundary.offset(line, at: endIndex))
            guard startOffset.isFinite, endOffset.isFinite,
                  abs(endOffset - startOffset) > 0.25 else { return }

            let drawing = dominantDrawing(of: highlightedRange, in: attributedString)
            var ascent = drawing.font?.ascender ?? lineAscent
            var descent = drawing.font.map { -$0.descender } ?? lineDescent
            if drawing.isUpright {
                // Centred on the column, as CoreText centres the upright glyphs.
                ascent = (ascent + descent) / 2
                descent = ascent
            }

            let glyphRect = CGRect(
                x: origin.x + min(startOffset, endOffset),
                y: origin.y + drawing.raise - descent,
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

    /// How CoreText draws most of `range`'s characters: the font whose ascent and descent make
    /// their glyph box, their raise off the line origin, and whether they stand upright in a
    /// vertical line, where that box is centred on the column.
    ///
    /// A fragment's characters are not all drawn alike, and its first one is the odd one out more
    /// often than not:
    /// - TXT, online and legacy-EPUB body text centres itself in its fixed-height line with
    ///   `.baselineOffset` (`ReaderTypographyCorrection.baselineOffset`), which CoreText draws as a
    ///   raise of every glyph: about 4pt at 18pt × 1.65. A box measured from the bare line origin
    ///   sat that far below its text (2026-10-15: 3.2–4.3pt on all five built-in rules, paged and
    ///   scroll). Marks that `CJKPunctuation` repositions carry an offset of their own.
    /// - In a vertical column a curly quote lies on its side in the horizontal font, lowered onto
    ///   the column's centre line (`CJKTypography.centreSideways`), while the text it opens
    ///   stands upright. Taking the metrics from the opening quote put every “” and ‘’ box of a
    ///   vertical EPUB 5.5pt to the right of its column (2026-10-15).
    ///
    /// Upright text is drawn in CoreText's vertical variant of its font, whose ascent and descent
    /// are half its vertical advance each: 9 and 9 for PingFang TC at 18pt. A box that thin hugged
    /// the glyphs and left the quotes on their side across its edge (2026-10-15). The box comes
    /// from the variant's horizontal version instead, PingFang TC's own 19.08 and 6.12: what the
    /// same text reports in a horizontal line. Only the browser engine draws upright text through
    /// here, and it gives CJK text a font made for it (`CJKTypography.applyFonts`). A character
    /// that font lacks too, such as an extension-B Han, is drawn by the system's fallback, which
    /// borrows the ascent and descent of the font it stands in for; its horizontal version has
    /// its own instead.
    ///
    /// The legacy engine lays vertical text out in a vertical CTFrame instead, in horizontal
    /// fonts: there the characters marked with vertical forms stand upright
    /// (`CJKTypography.applyOrientation`), and `inVerticalLine` reads that mark.
    ///
    /// A tie keeps the earlier drawing.
    private static func dominantDrawing(
        of range: NSRange,
        in attributedString: NSAttributedString,
        inVerticalLine: Bool = false
    ) -> (font: UIFont?, raise: CGFloat, isUpright: Bool) {
        var runs: [(font: UIFont?, raise: CGFloat, isUpright: Bool, length: Int)] = []
        attributedString.enumerateAttributes(in: range, options: []) { attributes, run, _ in
            let font = attributes[.font] as? UIFont
            let raise = (attributes[.baselineOffset] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
            let isUpright = font.map(isVerticalVariant) ?? false
                || inVerticalLine && (attributes[verticalFormsKey] as? NSNumber)?.boolValue == true
            if let index = runs.firstIndex(where: {
                $0.font == font && $0.raise == raise && $0.isUpright == isUpright
            }) {
                runs[index].length += run.length
            } else {
                runs.append((font, raise, isUpright, run.length))
            }
        }
        var dominant: (font: UIFont?, raise: CGFloat, isUpright: Bool, length: Int)?
        for run in runs where run.length > (dominant?.length ?? 0) {
            dominant = run
        }
        guard let dominant else { return (nil, 0, false) }
        guard let font = dominant.font, isVerticalVariant(font) else {
            return (dominant.font, dominant.raise, dominant.isUpright)
        }
        return (
            CTFontCreateCopyWithAttributes(font as CTFont, 0, nil, horizontalOrientationDescriptor()) as UIFont,
            dominant.raise,
            true
        )
    }

    private static let verticalFormsKey = NSAttributedString.Key(kCTVerticalFormsAttributeName as String)

    /// Whether `font` is CoreText's vertical variant of a font: what it draws upright text in a
    /// vertical line with.
    private static func isVerticalVariant(_ font: UIFont) -> Bool {
        (CTFontCopyAttribute(font as CTFont, kCTFontOrientationAttribute) as? NSNumber)?.uint32Value
            == CTFontOrientation.vertical.rawValue
    }

    /// Made per call: `CTFontDescriptor` is not `Sendable`, so a shared static would be global
    /// mutable state. Only a decoration group whose dominant font is a vertical variant gets here.
    private static func horizontalOrientationDescriptor() -> CTFontDescriptor {
        CTFontDescriptorCreateWithAttributes(
            [kCTFontOrientationAttribute: CTFontOrientation.horizontal.rawValue] as CFDictionary
        )
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
            let rects = verticalGlyphRects(
                of: highlightedRange,
                lines: lines,
                origins: origins,
                attributedString: attributedString,
                contentOffset: contentOffset,
                layoutHeight: layoutHeight
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

    /// The glyph box of `range` in each column of a vertical frame, in UIKit coordinates of a
    /// canvas `layoutHeight` tall: down the column, from its first character to its last one's
    /// end; across it, the box the same text has in a horizontal line (`dominantDrawing`).
    ///
    /// Selection and read-aloud mark the whole column pitch (`CoreTextAnnotationRenderer`). A
    /// highlight box that wide was the line height thick, 29.7pt at 18pt × 1.65, where the same
    /// text's box in a horizontal line is its font's 25.2pt: 89px against 76px (2026-10-15).
    private static func verticalGlyphRects(
        of range: NSRange,
        lines: [CTLine],
        origins: [CGPoint],
        attributedString: NSAttributedString,
        contentOffset: CGPoint,
        layoutHeight: CGFloat
    ) -> [CGRect] {
        let string = attributedString.string as NSString
        var rects: [CGRect] = []
        for (index, line) in lines.enumerated() where index < origins.count {
            let lineStringRange = CTLineGetStringRange(line)
            let lineRange = NSRange(location: lineStringRange.location, length: max(0, lineStringRange.length))
            let inLine = NSIntersectionRange(lineRange, range)
            guard inLine.length > 0 else { continue }
            let end = min(NSMaxRange(inLine), contentEnd(of: lineRange, in: string))
            guard end > inLine.location else { continue }
            let drawn = NSRange(location: inLine.location, length: end - inLine.location)

            let startOffset = CGFloat(GlyphBoundary.offset(line, at: drawn.location))
            let endOffset = CGFloat(GlyphBoundary.offset(line, at: NSMaxRange(drawn)))
            guard startOffset.isFinite, endOffset.isFinite,
                  abs(endOffset - startOffset) > 0.25 else { continue }

            var lineAscent: CGFloat = 0
            var lineDescent: CGFloat = 0
            _ = CTLineGetTypographicBounds(line, &lineAscent, &lineDescent, nil)
            let drawing = dominantDrawing(of: drawn, in: attributedString, inVerticalLine: true)
            let ascent = drawing.font?.ascender ?? lineAscent
            let descent = drawing.font.map { -$0.descender } ?? lineDescent
            let baselineX = contentOffset.x + origins[index].x
            let left: CGFloat
            let right: CGFloat
            if drawing.isUpright {
                // CoreText centres upright glyphs on the baseline, raised with their text
                // (`CoreTextPaginator.combinedUprightCells`).
                let centre = baselineX + drawing.raise
                left = centre - (ascent + descent) / 2
                right = centre + (ascent + descent) / 2
            } else {
                // Text on its side stands on the baseline with its ascent to the right, lowered
                // onto the column's centre line by an offset of its own (`centreSideways`).
                left = baselineX + drawing.raise - descent
                right = baselineX + drawing.raise + ascent
            }
            let columnTop = layoutHeight - (contentOffset.y + origins[index].y)
            rects.append(CGRect(
                x: left,
                y: columnTop + min(startOffset, endOffset),
                width: max(1, right - left),
                height: abs(endOffset - startOffset)
            ))
        }
        return rects
    }

    /// Where a line's text ends: before the spaces and line break it ends with, which take up no
    /// room on the page. A box run on through them stood out past the line's last character,
    /// beyond the text column on a justified line (2026-10-15: a 【】 breaking after its space).
    private static func contentEnd(of lineRange: NSRange, in string: NSString) -> Int {
        var end = NSMaxRange(lineRange)
        while end > lineRange.location,
              let scalar = UnicodeScalar(string.character(at: end - 1)),
              CharacterSet.whitespacesAndNewlines.contains(scalar) {
            end -= 1
        }
        return end
    }

    static func paint(
        fragments: [Fragment],
        writingMode: ReaderWritingMode,
        context: CGContext
    ) {
        let drawable = fragments.filter { $0.rect.width > 0.5 && $0.rect.height > 0.5 }
        guard !drawable.isEmpty else { return }

        for fragment in drawable { drawShadows(for: fragment, context: context) }
        for fragment in drawable { drawBackground(for: fragment, context: context) }
        for fragment in drawable { drawImage(for: fragment, writingMode: writingMode, context: context) }
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

    private static func drawImage(
        for fragment: Fragment,
        writingMode: ReaderWritingMode,
        context: CGContext
    ) {
        let style = fragment.decoration.style
        guard let presentation = style.backgroundImage,
              let image = fragment.decoration.cachedBackgroundImage,
              let cgImage = image.cgImage else { return }

        context.saveGState()
        context.setAlpha(CGFloat(style.opacity ?? 1) * CGFloat(presentation.opacity))
        // Translate before clipping so the entire image (including its rounded
        // boundary) moves. CoreText is y-up; editor Y is positive downwards.
        context.translateBy(
            x: CGFloat(style.backgroundImageOffsetX ?? 0),
            y: -CGFloat(style.backgroundImageOffsetY ?? 0)
        )
        context.addPath(roundedPath(rect: fragment.rect, radius: style.cornerRadius))
        context.clip()
        context.interpolationQuality = .high

        if let slices = presentation.nineSlice {
            // The whole artwork is drawn for the padded box of one line, so its height
            // maps onto the fragment's block-axis thickness: Reeden's frames carry a
            // content window whose margins equal the rule's padding at exactly this scale.
            let thickness = writingMode.isVertical ? fragment.rect.width : fragment.rect.height
            let width = CGFloat(cgImage.width)
            let height = CGFloat(cgImage.height)
            NineSliceImageDrawing.draw(
                cgImage,
                slices: .init(
                    top: CGFloat(slices.top) * height,
                    right: CGFloat(slices.right) * width,
                    bottom: CGFloat(slices.bottom) * height,
                    left: CGFloat(slices.left) * width
                ),
                scale: height > 0 ? thickness / height : 0,
                in: fragment.rect,
                context: context
            )
            context.restoreGState()
            return
        }

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
        // then repeats in user space. The context is already y-up, so the tile needs neither a
        // flip nor a reflected anchor — both were compensating for a flip that should not be here.
        _ = bounds
        context.draw(
            image,
            in: CGRect(origin: anchor, size: pointSize),
            byTiling: true
        )
    }

    /// Draws a CGImage the right way up.
    ///
    /// This painter runs inside the line drawer's context, which is already
    /// flipped to CoreText's y-up convention — and CoreGraphics draws images
    /// upright in a y-up context on its own. The extra flip this used to apply
    /// turned every background image upside down; invisible on a symmetric
    /// texture, obvious on anything with a top and a bottom.
    private static func drawUpright(
        _ image: CGImage,
        in rect: CGRect,
        context: CGContext
    ) {
        guard rect.width > 0, rect.height > 0 else { return }
        context.draw(image, in: rect)
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
