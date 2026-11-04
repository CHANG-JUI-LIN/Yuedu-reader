import CoreText
import UIKit
import YueduCoreText

/// Adapts an already laid-out chunk to the common viewport paint owner.
/// These are paint partitions only: CTFrame, UTF-16 ranges and scroll geometry
/// stay unchanged. Paragraph boundaries are preferred; long paragraphs split
/// between lines so no entering surface demands a whole-chunk raster.
@MainActor
struct CoreTextPaintFragment {
    let chunk: CoreTextChunk
    let index: Int
    let rect: CGRect
    let renderingRect: CGRect
    let lineIndices: IndexSet

    static func make(chunk: CoreTextChunk, scale: CGFloat) -> [Self] {
        precondition(!chunk.writingMode.isVertical)
        chunk.materializeFrameIfNeeded()
        let scale = max(1, scale)
        let lines = chunk.frame.map { CTFrameGetLines($0) as! [CTLine] } ?? []
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        if let frame = chunk.frame, !lines.isEmpty {
            CTFrameGetLineOrigins(frame, CFRange(location: 0, length: lines.count), &origins)
        }
        let text = chunk.attributedString.string as NSString
        var cuts: [CGFloat] = [0]
        var ink: [CGRect] = []
        // Decorations can extend outside typographic bounds. All block/bubble/
        // image passes still paint through the partition clip; this halo is for
        // per-line glyph, rule and underline work that we may omit entirely.
        var halo: CGFloat = 2
        let range = NSRange(location: chunk.charRange.location, length: chunk.charRange.length)
        chunk.attributedString.enumerateAttributes(in: range) { attributes, _, _ in
            if let shadow = attributes[.shadow] as? NSShadow {
                halo = max(halo, abs(shadow.shadowOffset.height) + shadow.shadowBlurRadius * 4)
            }
            // Inline CSS boxes and rules extend beyond glyph bounds too. Keep
            // the source line in every intersecting partition so its original
            // painter preserves those overlaps at paragraph boundaries.
            if let box = attributes[HTMLAttributedStringBuilder.inlineBorderBoxAttribute]
                as? HTMLAttributedStringBuilder.InlineBorderBoxStyle {
                halo = max(halo, abs(box.paddingVertical) + abs(box.borderWidth) / 2 + 1)
            }
            if let rule = attributes[HTMLAttributedStringBuilder.hrDividerAttribute]
                as? HTMLAttributedStringBuilder.HRDividerStyle {
                halo = max(halo, abs(rule.lineWidth ?? 0.5) / 2 + 1)
            }
            if attributes[HTMLAttributedStringBuilder.textDecorationAttribute] != nil,
               let font = attributes[.font] as? UIFont {
                halo = max(halo, ReaderTextDecorationRenderer.reach(fontSize: font.pointSize))
            }
        }
        if GlobalSettings.shared.readerTextUnderlineDecorationEnabled {
            halo = max(halo, CGFloat(abs(GlobalSettings.shared.readerTextUnderlineOffset)
                + GlobalSettings.shared.readerTextUnderlineThickness))
        }
        for (i, line) in lines.enumerated() {
            var ascent: CGFloat = 0, descent: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
            let baseline = chunk.height - origins[i].y
            var bounds = CGRect(x: origins[i].x, y: baseline - ascent,
                                width: max(1, width), height: max(1, ascent + descent))
            let glyph = TextLinePaintBounds.conservativeBounds(for: line)
            if !glyph.isNull {
                bounds = bounds.union(CGRect(x: origins[i].x + glyph.minX,
                    y: baseline - glyph.maxY, width: glyph.width, height: glyph.height))
            }
            let decorations = RegexHighlightDecorationRenderer.horizontalFragments(
                line: line, origin: origins[i], attributedString: chunk.attributedString, range: range)
            for decoration in decorations {
                let spread = decoration.decoration.style.shadows.map {
                    max(8, CGFloat($0.radius) * 4 + abs(CGFloat($0.y)))
                }.max() ?? 0
                let rect = decoration.rect
                let decorationRect = CGRect(x: rect.minX, y: chunk.height - rect.maxY,
                                            width: rect.width, height: rect.height)
                bounds = bounds.union(decorationRect.insetBy(dx: -spread, dy: -spread))
                let style = decoration.decoration.style
                if style.backgroundImage != nil {
                    // A shifted image may enter a neighbouring partition even
                    // when its source text line is outside that partition.
                    bounds = bounds.union(decorationRect.offsetBy(
                        dx: CGFloat(style.backgroundImageOffsetX ?? 0),
                        dy: CGFloat(style.backgroundImageOffsetY ?? 0)
                    ))
                }
            }
            ink.append(bounds.insetBy(dx: -halo, dy: -halo))
            let lineRange = CTLineGetStringRange(line)
            let startsParagraph = lineRange.location > 0 && lineRange.location <= text.length
                && [UInt16(10), 0x2028, 0x2029].contains(text.character(at: lineRange.location - 1))
            let y = floor(max(0, baseline - ascent) * scale) / scale
            if i > 0, y > cuts.last! + 1, startsParagraph || y - cuts.last! >= 256 {
                cuts.append(min(chunk.height, y))
            }
        }
        // Large illustrations or blank vertical space have no intervening line
        // boundary. Bound their paint area as well, without rescaling the image.
        cuts.append(chunk.height)
        var bounded: [CGFloat] = [0]
        for end in cuts.dropFirst() {
            while end - bounded.last! > 512 { bounded.append(bounded.last! + 256) }
            if end > bounded.last! { bounded.append(end) }
        }
        return zip(bounded, bounded.dropFirst()).enumerated().map { index, pair in
            let rect = CGRect(x: 0, y: pair.0, width: chunk.width, height: pair.1 - pair.0)
            // One logical point of sampling bleed prevents seams at fractional
            // scroll positions. The outer surface clips it to a disjoint band.
            let rendering = rect.insetBy(dx: 0, dy: -1)
            let indices = IndexSet(ink.indices.filter { ink[$0].intersects(rendering) })
            return Self(chunk: chunk, index: index, rect: rect, renderingRect: rendering, lineIndices: indices)
        }
    }
}
