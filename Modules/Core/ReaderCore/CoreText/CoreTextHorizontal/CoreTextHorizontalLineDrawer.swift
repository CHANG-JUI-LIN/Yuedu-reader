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
        in ctx: CGContext
    ) {
        let lines = CTFrameGetLines(frame) as! [CTLine]
        guard !lines.isEmpty else { return }

        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRangeMake(0, lines.count), &origins)

        let nsString = attrStr.string as NSString
        let stringLength = attrStr.length

        if hrTraceCount < 25 {
            hrTraceCount += 1
            var hrAttrSpans = 0
            attrStr.enumerateAttribute(hrDividerKey, in: NSRange(location: 0, length: stringLength)) { v, _, _ in
                if v != nil { hrAttrSpans += 1 }
            }
            print("[HRTrace] drawLines lines=\(lines.count) strLen=\(stringLength) hrAttrSpans=\(hrAttrSpans) suppressed=\(suppressedRanges.count)")
        }

        // Phase 5A: distribute bottom space across paragraph gaps on non-last pages
        var extraSpacePerGap: CGFloat = 0
        var paragraphGapAfterLine: Set<Int> = []

        if !isLastPage && lines.count > 1 {
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

            // Get paragraph alignment
            let isJustified: Bool
            if lineRange.location < stringLength {
                let paraStyle = attrStr.attribute(.paragraphStyle, at: lineRange.location, effectiveRange: nil) as? NSParagraphStyle
                isJustified = paraStyle?.alignment == .justified
            } else {
                isJustified = false
            }

            origin.x = max(contentMinX, origin.x)
            let maxRightX = contentMinX + contentWidth
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

            debugTraceLine(
                text: nsString.substring(with: NSRange(location: lineStart, length: max(0, lineRange.length))),
                isJustified: isJustified,
                availableWidth: availableWidth,
                natural: line,
                drawn: lineToDraw
            )

            ctx.textPosition = origin
            CTLineDraw(lineToDraw, ctx)
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

        let strokeColor = (hr.color ?? .separator)
        let lineWidth = hr.lineWidth ?? 0.5
        if hrDrawTraceCount < 8 {
            hrDrawTraceCount += 1
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            strokeColor.getRed(&r, green: &g, blue: &b, alpha: &a)
            print(String(format: "[HRDraw] startX=%.1f y=%.1f ruleW=%.1f lineW=%.2f color=rgba(%.2f,%.2f,%.2f,%.2f) contentMinX=%.1f contentW=%.1f leftM=%.1f",
                         startX, origin.y, ruleWidth, lineWidth, r, g, b, a, contentMinX, contentWidth, leftMargin))
        }
        ctx.saveGState()
        ctx.setStrokeColor(strokeColor.cgColor)
        ctx.setLineWidth(lineWidth)
        ctx.move(to: CGPoint(x: startX, y: origin.y))
        ctx.addLine(to: CGPoint(x: startX + ruleWidth, y: origin.y))
        ctx.strokePath()
        ctx.restoreGState()
        return true
    }

    nonisolated(unsafe) private static var hrDrawTraceCount = 0
    nonisolated(unsafe) private static var hrTraceCount = 0

    // MARK: - Debug: trace digit↔CJK line spacing at draw time

    nonisolated(unsafe) private static var spaceTraceLineCount = 0

    /// For lines containing a digit adjacent to a Han character, logs whether the line is
    /// justified and how the drawn width compares to the natural width. If drawn > natural,
    /// the gaps come from justification (draw-time); if they're equal and the line still
    /// shows gaps, they live in the glyph advances / kern instead. Rate-limited.
    private static func debugTraceLine(
        text: String,
        isJustified: Bool,
        availableWidth: CGFloat,
        natural: CTLine,
        drawn: CTLine
    ) {
        guard spaceTraceLineCount < 8 else { return }
        let scalars = Array(text.unicodeScalars)
        var hasBoundary = false
        for i in 0 ..< max(0, scalars.count - 1) {
            let a = scalars[i].value, b = scalars[i + 1].value
            let aDigit = (0x30...0x39).contains(Int(a)), bDigit = (0x30...0x39).contains(Int(b))
            let aHan = (0x4E00...0x9FFF).contains(Int(a)), bHan = (0x4E00...0x9FFF).contains(Int(b))
            if (aDigit && bHan) || (aHan && bDigit) { hasBoundary = true; break }
        }
        guard hasBoundary else { return }
        spaceTraceLineCount += 1
        let natW = CTLineGetTypographicBounds(natural, nil, nil, nil)
        let drawW = CTLineGetTypographicBounds(drawn, nil, nil, nil)
        let preview = text.count > 32 ? String(text.prefix(32)) + "…" : text
        print(String(format: "[SpaceTrace][line] \"%@\" justified=%@ avail=%.0f naturalW=%.1f drawnW=%.1f stretched=%@",
                     preview, isJustified ? "Y" : "N", availableWidth, natW, drawW,
                     (drawW - natW > 0.5) ? "YES" : "no"))
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
