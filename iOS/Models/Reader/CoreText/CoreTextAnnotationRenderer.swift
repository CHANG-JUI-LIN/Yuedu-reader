import CoreText
import Foundation

// MARK: - Annotation Renderer

/// Computes highlight/underline rects from annotations and CTFrame layout.
/// Stateless: takes annotations + layout → produces rects grouped by style/color.
/// Both scroll mode and page mode use this single renderer.
struct CoreTextAnnotationRenderer {

    struct Layer {
        let rects: [CGRect]
        let style: AnnotationStyle
        let color: AnnotationColor
    }

    /// Computes annotation rects for a given page/chunk character range.
    /// - Parameters:
    ///   - annotations: All text annotations for the current book
    ///   - spineIndex: Current chapter spine index
    ///   - pageCharRange: Character range of this page/chunk (NSRange)
    ///   - lines: CTFrame lines for this page/chunk
    ///   - lineOrigins: CTFrame line origins for this page/chunk
    ///   - contentOffset: Content area origin in the CoreText coordinate system (contentPathRect.minX, contentPathRect.minY)
    ///   - layoutHeight: Total layout height, used to flip from CoreText to UIKit coordinates
    ///   - writingMode: Horizontal or vertical
    /// - Returns: Layers grouped by (style, color), ready for drawing in UIKit coordinates (no scale applied)
    static func render(
        annotations: [CoreTextTextAnnotation],
        spineIndex: Int,
        pageCharRange: NSRange,
        lines: [CTLine],
        lineOrigins: [CGPoint],
        contentOffset: CGPoint = .zero,
        layoutHeight: CGFloat,
        writingMode: ReaderWritingMode
    ) -> [Layer] {
        guard !annotations.isEmpty, !lines.isEmpty, pageCharRange.length > 0 else { return [] }

        // Group annotations by (style, color) so rects are layered correctly
        var layers: [LayerKey: [CGRect]] = [:]
        let relevantAnnotations = annotations.filter { $0.spineIndex == spineIndex }

        for annotation in relevantAnnotations {
            let intersection = NSIntersectionRange(pageCharRange, annotation.range)
            guard intersection.length > 0 else { continue }

            let key = LayerKey(style: annotation.style, color: annotation.color)
            let rects: [CGRect]

            if writingMode.isVertical {
                rects = verticalRects(
                    range: intersection,
                    lines: lines,
                    lineOrigins: lineOrigins,
                    contentOffset: contentOffset,
                    layoutHeight: layoutHeight
                )
            } else {
                rects = horizontalRects(
                    range: intersection,
                    lines: lines,
                    lineOrigins: lineOrigins,
                    contentOffset: contentOffset,
                    layoutHeight: layoutHeight
                )
            }

            if !rects.isEmpty {
                layers[key, default: []].append(contentsOf: rects)
            }
        }

        return layers.map { key, rects in
            Layer(rects: rects, style: key.style, color: key.color)
        }
    }

    // MARK: - Raw rects (for selection / playback — no style/color grouping)

    /// Computes rects for a single character range. Used by selection highlighting and TTS playback.
    static func rects(
        forRange range: NSRange,
        lines: [CTLine],
        lineOrigins: [CGPoint],
        contentOffset: CGPoint = .zero,
        layoutHeight: CGFloat,
        writingMode: ReaderWritingMode
    ) -> [CGRect] {
        guard !lines.isEmpty, range.length > 0 else { return [] }
        if writingMode.isVertical {
            return verticalRects(range: range, lines: lines, lineOrigins: lineOrigins, contentOffset: contentOffset, layoutHeight: layoutHeight)
        }
        return horizontalRects(range: range, lines: lines, lineOrigins: lineOrigins, contentOffset: contentOffset, layoutHeight: layoutHeight)
    }

    // MARK: - Horizontal rects

    private static func horizontalRects(
        range: NSRange,
        lines: [CTLine],
        lineOrigins: [CGPoint],
        contentOffset: CGPoint,
        layoutHeight: CGFloat
    ) -> [CGRect] {
        var rects: [CGRect] = []
        for idx in lines.indices {
            let line = lines[idx]
            let lineRange = CTLineGetStringRange(line)
            guard lineRange.length > 0 else { continue }
            let lineNS = NSRange(location: lineRange.location, length: lineRange.length)
            let inter = NSIntersectionRange(lineNS, range)
            guard inter.length > 0 else { continue }

            let startOffset = CGFloat(CTLineGetOffsetForStringIndex(line, inter.location, nil))
            let endOffset = CGFloat(CTLineGetOffsetForStringIndex(line, inter.location + inter.length, nil))

            var ascent: CGFloat = 0, descent: CGFloat = 0
            _ = CTLineGetTypographicBounds(line, &ascent, &descent, nil)

            let origin = lineOrigins[idx]
            let baselineY = contentOffset.y + origin.y
            let lineTop = baselineY + ascent
            let lineHeight = max(1, ascent + descent)

            let uiY = layoutHeight - lineTop
            rects.append(CGRect(
                x: contentOffset.x + origin.x + min(startOffset, endOffset),
                y: uiY,
                width: max(1, abs(endOffset - startOffset)),
                height: lineHeight
            ))
        }
        return rects
    }

    // MARK: - Vertical rects

    private static func verticalRects(
        range: NSRange,
        lines: [CTLine],
        lineOrigins: [CGPoint],
        contentOffset: CGPoint,
        layoutHeight: CGFloat
    ) -> [CGRect] {
        var rects: [CGRect] = []
        for idx in lines.indices {
            let line = lines[idx]
            let lineRange = CTLineGetStringRange(line)
            guard lineRange.length > 0 else { continue }
            let lineNS = NSRange(location: lineRange.location, length: lineRange.length)
            let inter = NSIntersectionRange(lineNS, range)
            guard inter.length > 0 else { continue }

            let startOffset = CGFloat(CTLineGetOffsetForStringIndex(line, inter.location, nil))
            let endOffset = CGFloat(CTLineGetOffsetForStringIndex(line, inter.location + inter.length, nil))

            var ascent: CGFloat = 0, descent: CGFloat = 0
            _ = CTLineGetTypographicBounds(line, &ascent, &descent, nil)

            let origin = lineOrigins[idx]
            let baselineX = contentOffset.x + origin.x
            let x1 = baselineX - descent
            let x2 = baselineX + ascent
            let lineTopY = layoutHeight - (contentOffset.y + origin.y)

            rects.append(CGRect(
                x: min(x1, x2),
                y: lineTopY + min(startOffset, endOffset),
                width: max(1, abs(x2 - x1)),
                height: max(1, abs(endOffset - startOffset))
            ))
        }
        return rects
    }
}
