import UIKit
import CoreText

/// Horizontal writing mode text rendering.
///
/// Draws CTFrame line-by-line with CJK-optimized justification,
/// paragraph gap distribution, and HR divider lines.
/// NOT used in vertical writing mode — vertical uses CTFrameDraw directly.
enum CoreTextHorizontalLineDrawer {

    // MARK: - Main entry

    static func drawLines(
        of frame: CTFrame,
        contentWidth: CGFloat,
        contentMinX: CGFloat,
        contentMinY: CGFloat,
        isLastPage: Bool,
        attrStr: NSAttributedString,
        suppressedRanges: [NSRange] = [],
        hrDividerKey: NSAttributedString.Key,
        bottomJustified: Bool = true,
        in ctx: CGContext
    ) {
        let lines = CTFrameGetLines(frame) as! [CTLine]
        guard !lines.isEmpty else { return }

        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRangeMake(0, lines.count), &origins)

        let nsString = attrStr.string as NSString
        let stringLength = attrStr.length

        // Phase 5A: distribute bottom space across paragraph gaps on non-last pages.
        // Callers disable this on pages carrying block decorations: the shift moves the glyph
        // lines, but decoration rects were extracted from the UNSHIFTED line origins, so boxes
        // would detach from their own text (a `.sys` pill drifting onto the paragraphs above),
        // and authored-tight gaps (`.sys p { margin: 0 }`) would inflate by the distributed slack.
        var extraSpacePerGap: CGFloat = 0
        var paragraphGapAfterLine: Set<Int> = []

        if bottomJustified && !isLastPage && lines.count > 1 {
            for i in 0..<(lines.count - 1) {
                let r = CTLineGetStringRange(lines[i])
                let checkIdx = r.location + r.length
                if checkIdx < stringLength {
                    let ch = nsString.character(at: checkIdx)
                    if ch == 0x000A || ch == 0x2028 || ch == 0x2029 {
                        paragraphGapAfterLine.insert(i)
                    }
                }
            }
            if !paragraphGapAfterLine.isEmpty {
                var lastDescent: CGFloat = 0
                CTLineGetTypographicBounds(lines.last!, nil, &lastDescent, nil)
                let lastBaseline = origins[lines.count - 1].y
                let usedBottom = lastBaseline + lastDescent
                let extraSpace = usedBottom - contentMinY
                if extraSpace > 2 {
                    extraSpacePerGap = extraSpace / CGFloat(paragraphGapAfterLine.count)
                }
            }
        }

        var accumulatedShift: CGFloat = 0

        for (lineIdx, line) in lines.enumerated() {
            if lineIdx > 0 && paragraphGapAfterLine.contains(lineIdx - 1) {
                accumulatedShift -= extraSpacePerGap
            }

            var origin = origins[lineIdx]
            origin.x += contentMinX
            origin.y += (accumulatedShift + contentMinY)

            let lineRange = CTLineGetStringRange(line)
            let lineStart = lineRange.location
            let lineEnd = lineRange.location + lineRange.length

            // Skip lines belonging to explicit block renderables (drawn separately)
            if !suppressedRanges.isEmpty {
                let lineNSRange = NSRange(location: lineStart, length: max(0, lineRange.length))
                if suppressedRanges.contains(where: { NSIntersectionRange($0, lineNSRange).length > 0 }) {
                    continue
                }
            }

            // Phase 4: HR divider line. The hrDividerAttribute lives on the divider's "\n", which
            // CoreText often folds into a line range alongside an adjacent paragraph break — so it
            // is NOT necessarily at lineRange.location. Scan the whole line range for it.
            if let hrValue = hrDividerValue(in: attrStr, lineStart: lineStart, lineLength: lineRange.length, stringLength: stringLength, key: hrDividerKey) {
                if drawHR(hrValue, origin: origin, contentWidth: contentWidth, contentMinX: contentMinX, in: ctx) {
                    continue
                }
            }

            // Determine paragraph-last-line (should not be justified)
            let isParagraphLastLine: Bool
            if lineEnd >= stringLength {
                isParagraphLastLine = true
            } else {
                let nextCharCode = nsString.character(at: lineEnd)
                isParagraphLastLine = nextCharCode == 0x000A || nextCharCode == 0x2028
            }

            // Paragraph alignment + right inset. Justification must stretch a line to the
            // paragraph's OWN right edge (tailIndent), not the full column — otherwise justified
            // lines inside padded boxes (`.yj` letter, `.ph` phone frame) poke through the
            // right border (the box is drawn 8pt inside the text zone those lines stretched to).
            let paraStyle: NSParagraphStyle? = lineRange.location < stringLength
                ? attrStr.attribute(.paragraphStyle, at: lineRange.location, effectiveRange: nil) as? NSParagraphStyle
                : nil
            let isJustified = paraStyle?.alignment == .justified
            let tailInset: CGFloat = {
                guard let tail = paraStyle?.tailIndent, tail < 0 else { return 0 }
                return -tail
            }()

            origin.x = max(contentMinX, origin.x)
            let maxRightX = contentMinX + contentWidth - tailInset
            let availableWidth = max(1, maxRightX - origin.x)

            let lineToDraw = resolveJustifiedLine(
                line: line,
                lineStart: lineStart,
                lineRange: lineRange,
                isJustified: isJustified,
                isParagraphLastLine: isParagraphLastLine,
                availableWidth: availableWidth,
                attrStr: attrStr,
                nsString: nsString
            )

            // Inline border "chips" (e.g. page-number badges) are drawn behind the glyphs so the
            // text sits on top of any fill. Offsets are read from the original (un-justified) line;
            // chips occur on centered/short lines that are never justified.
            drawInlineBorderBoxes(
                line: line,
                origin: origin,
                lineStart: lineStart,
                lineLength: lineRange.length,
                attrStr: attrStr,
                stringLength: stringLength,
                in: ctx
            )

            ctx.textPosition = origin
            CTLineDraw(lineToDraw, ctx)
        }
    }

    // MARK: - Inline border chip

    private static func drawInlineBorderBoxes(
        line: CTLine,
        origin: CGPoint,
        lineStart: Int,
        lineLength: Int,
        attrStr: NSAttributedString,
        stringLength: Int,
        in ctx: CGContext
    ) {
        guard lineStart >= 0, lineStart < stringLength else { return }
        let length = min(max(0, lineLength), stringLength - lineStart)
        guard length > 0 else { return }

        var hasChip = false
        attrStr.enumerateAttribute(
            HTMLAttributedStringBuilder.inlineBorderBoxAttribute,
            in: NSRange(location: lineStart, length: length),
            options: []
        ) { value, _, stop in
            if value != nil { hasChip = true; stop.pointee = true }
        }
        guard hasChip else { return }

        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        CTLineGetTypographicBounds(line, &ascent, &descent, nil)

        attrStr.enumerateAttribute(
            HTMLAttributedStringBuilder.inlineBorderBoxAttribute,
            in: NSRange(location: lineStart, length: length),
            options: []
        ) { value, range, _ in
            guard let style = value as? HTMLAttributedStringBuilder.InlineBorderBoxStyle,
                  range.length > 0 else { return }

            let startOffset = CTLineGetOffsetForStringIndex(line, range.location, nil)
            let endOffset = CTLineGetOffsetForStringIndex(line, range.location + range.length, nil)
            let x0 = origin.x + min(startOffset, endOffset)
            let x1 = origin.x + max(startOffset, endOffset)
            guard x1 > x0 else { return }

            let rect = CGRect(
                x: x0 - style.paddingHorizontal,
                y: origin.y - descent - style.paddingVertical,
                width: (x1 - x0) + 2 * style.paddingHorizontal,
                height: (ascent + descent) + 2 * style.paddingVertical
            )
            let radius = max(0, min(style.cornerRadius, min(rect.width, rect.height) / 2))
            let path = UIBezierPath(roundedRect: rect, cornerRadius: radius).cgPath

            ctx.saveGState()
            if let fill = style.fillColor {
                ctx.setFillColor(fill.cgColor)
                ctx.addPath(path)
                ctx.fillPath()
            }
            ctx.setStrokeColor(style.borderColor.cgColor)
            ctx.setLineWidth(style.borderWidth)
            ctx.addPath(path)
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    /// Finds the HR divider attribute anywhere within a line's character range (not just at its
    /// start), returning the first value found. CoreText may place the divider's "\n" at the end
    /// of a line range rather than its location, so a start-only lookup misses it.
    private static func hrDividerValue(
        in attrStr: NSAttributedString,
        lineStart: Int,
        lineLength: Int,
        stringLength: Int,
        key: NSAttributedString.Key
    ) -> Any? {
        guard lineStart >= 0, lineStart < stringLength else { return nil }
        let length = min(max(1, lineLength), stringLength - lineStart)
        var result: Any?
        attrStr.enumerateAttribute(key, in: NSRange(location: lineStart, length: length), options: []) { value, _, stop in
            if let value {
                result = value
                stop.pointee = true
            }
        }
        return result
    }

    // MARK: - HR divider

    private static func drawHR(
        _ hrValue: Any,
        origin: CGPoint,
        contentWidth: CGFloat,
        contentMinX: CGFloat,
        in ctx: CGContext
    ) -> Bool {
        guard let hr = hrValue as? HTMLAttributedStringBuilder.HRDividerStyle else { return false }

        let leftMargin = hr.marginLeft + hr.inheritedBlockMarginLeft
        let rightMargin = hr.marginRight + hr.inheritedBlockMarginRight
        let availableWidth = max(1, contentWidth - leftMargin - rightMargin)

        let ruleWidth: CGFloat
        if let w = hr.ruleWidth { ruleWidth = w }
        else if let pct = hr.ruleWidthPercent { ruleWidth = availableWidth * pct / 100.0 }
        else { ruleWidth = availableWidth }

        let startX: CGFloat
        if hr.isHorizontallyCentered || hr.alignment == .center {
            startX = contentMinX + leftMargin + (availableWidth - ruleWidth) / 2
        } else if hr.alignment == .right {
            startX = contentMinX + leftMargin + (availableWidth - ruleWidth)
        } else {
            startX = contentMinX + leftMargin
        }

        ctx.saveGState()
        ctx.setStrokeColor((hr.color ?? .separator).cgColor)
        ctx.setLineWidth(hr.lineWidth ?? 0.5)
        if !hr.lineDash.isEmpty {
            ctx.setLineDash(phase: 0, lengths: hr.lineDash)
        }
        ctx.move(to: CGPoint(x: startX, y: origin.y))
        ctx.addLine(to: CGPoint(x: startX + ruleWidth, y: origin.y))
        ctx.strokePath()
        ctx.restoreGState()
        return true
    }

    // MARK: - CJK justification

    private static func resolveJustifiedLine(
        line: CTLine,
        lineStart: Int,
        lineRange: CFRange,
        isJustified: Bool,
        isParagraphLastLine: Bool,
        availableWidth: CGFloat,
        attrStr: NSAttributedString,
        nsString: NSString
    ) -> CTLine {
        guard isJustified, !isParagraphLastLine else { return line }

        let lineNSRange = NSRange(location: lineStart, length: max(0, lineRange.length))
        let substring = attrStr.attributedSubstring(from: lineNSRange)
        // Drop the trailing per-glyph spacing (.kern) on the line's last character.
        // CoreText adds .kern as advance *after* every glyph, so without this the last
        // glyph of a justified line stops one letterSpacing short of the right edge,
        // producing a consistent gap that looks like an asymmetric right margin.
        let justifiable: NSAttributedString
        if substring.length > 0,
           let trailingKern = substring.attribute(.kern, at: substring.length - 1, effectiveRange: nil) as? CGFloat,
           trailingKern != 0 {
            let mutable = NSMutableAttributedString(attributedString: substring)
            mutable.removeAttribute(.kern, range: NSRange(location: substring.length - 1, length: 1))
            justifiable = mutable
        } else {
            justifiable = substring
        }
        let naturalLine = CTLineCreateWithAttributedString(justifiable)
        let naturalWidth = CTLineGetTypographicBounds(naturalLine, nil, nil, nil)
        let coverage = naturalWidth / Double(availableWidth)

        if coverage < 0.7 {
            return naturalLine // skip justification for short lines
        }

        let lineText = nsString.substring(with: lineNSRange)
        let shouldUseCJKJustify = isCJKDominant(lineText) && coverage > 0.85

        if shouldUseCJKJustify {
            return CTLineCreateJustifiedLine(naturalLine, 1.0, Double(availableWidth)) ?? naturalLine
        } else {
            return naturalLine
        }
    }

    /// Returns true when the text is predominantly CJK (Chinese / Japanese / Korean),
    /// meaning CJK codepoints outnumber Latin letters + digits.
    static func isCJKDominant(_ text: String) -> Bool {
        var cjk = 0
        var latin = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3400...0x4DBF,   // CJK Unified Ideographs Extension A
                 0x4E00...0x9FFF,   // CJK Unified Ideographs
                 0x3040...0x30FF,   // Hiragana + Katakana
                 0xAC00...0xD7AF:   // Hangul Syllables
                cjk += 1
            case 0x0041...0x005A,   // A-Z
                 0x0061...0x007A,   // a-z
                 0x0030...0x0039:   // 0-9
                latin += 1
            default:
                continue
            }
        }
        return cjk > latin
    }
}
