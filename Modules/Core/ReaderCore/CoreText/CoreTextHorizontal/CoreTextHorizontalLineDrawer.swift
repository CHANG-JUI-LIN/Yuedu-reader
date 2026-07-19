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

            // Determine paragraph-last-line (never justified). CoreText folds the trailing
            // paragraph break INTO this line's range, so the break sits at lineEnd-1, NOT at
            // lineEnd. Checking only the char *after* the line misses it, and the paragraph's last
            // line gets wrongly stretched (spraying huge gaps between its glyphs). Check the line's
            // own last char as well as the one after it, covering both range conventions.
            let isParagraphLastLine: Bool
            if lineEnd >= stringLength {
                isParagraphLastLine = true
            } else {
                let lastInLine = lineEnd > lineStart ? nsString.character(at: lineEnd - 1) : 0
                let afterLine = nsString.character(at: lineEnd)
                isParagraphLastLine =
                    lastInLine == 0x000A || lastInLine == 0x2028 || lastInLine == 0x2029
                    || afterLine == 0x000A || afterLine == 0x2028 || afterLine == 0x2029
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

            // Dialogue background box ("對話底色框"): filled behind the glyphs so the dialogue
            // text (optionally tinted) sits on top.
            drawDialogueBoxIfNeeded(
                line: line,
                origin: origin,
                lineStart: lineStart,
                lineLength: lineRange.length,
                attrStr: attrStr,
                stringLength: stringLength,
                in: ctx
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
            drawTextUnderlineDecorationIfNeeded(
                line: lineToDraw,
                origin: origin,
                lineStart: lineStart,
                attrStr: attrStr,
                stringLength: stringLength,
                in: ctx
            )
        }
    }

    // MARK: - Reader decoration underline

    private static func drawTextUnderlineDecorationIfNeeded(
        line: CTLine,
        origin: CGPoint,
        lineStart: Int,
        attrStr: NSAttributedString,
        stringLength: Int,
        in ctx: CGContext
    ) {
        guard GlobalSettings.shared.readerTextUnderlineDecorationEnabled,
              stringLength > 0,
              lineStart >= 0,
              lineStart < stringLength
        else { return }

        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
            - CGFloat(CTLineGetTrailingWhitespaceWidth(line))
        guard width > 2 else { return }

        let nsString = attrStr.string as NSString
        let lineRange = CTLineGetStringRange(line)
        let nsRange = NSRange(location: max(0, lineRange.location), length: max(0, lineRange.length))
        guard nsRange.location < stringLength else { return }
        let boundedRange = NSIntersectionRange(nsRange, NSRange(location: 0, length: stringLength))
        guard boundedRange.length > 0,
              nsString.substring(with: boundedRange).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else { return }

        let settings = GlobalSettings.shared
        let color = GlobalSettings.uiColor(
            rgbHex: settings.readerTextUnderlineDecorationColorHex
        ).withAlphaComponent(0.45)
        let thickness = CGFloat(settings.readerTextUnderlineThickness)
        let offset = CGFloat(settings.readerTextUnderlineOffset)
        let underlineY = origin.y - max(1, offset)

        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(thickness)
        switch settings.readerTextUnderlineStyle {
        case .solid:
            ctx.setLineCap(.round)
            ctx.setLineDash(phase: 0, lengths: [])
        case .dashed:
            ctx.setLineCap(.butt)
            let dash = max(thickness * 3, 2)
            let gap = max(thickness * 2, 1.5)
            let lengths: [CGFloat] = [dash, gap]
            ctx.setLineDash(phase: 0, lengths: lengths)
        case .dotted:
            ctx.setLineCap(.round)
            // Round-cap zero-length dashes render as circular dots; spacing scales with thickness.
            let spacing = max(thickness * 2.5, 2)
            let lengths: [CGFloat] = [0, spacing]
            ctx.setLineDash(phase: 0, lengths: lengths)
        }
        ctx.move(to: CGPoint(x: origin.x, y: underlineY))
        ctx.addLine(to: CGPoint(x: origin.x + width, y: underlineY))
        ctx.strokePath()
        ctx.restoreGState()
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

            // The chip hugs the run's own font box, not the line's: a small badge on a
            // line with larger text (`.chapter1 span` next to its heading) must not
            // balloon to the tallest glyph's height, matching a browser's inline
            // background box.
            let runAscent: CGFloat
            let runDescent: CGFloat
            if let runFont = attrStr.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont {
                runAscent = runFont.ascender
                runDescent = -runFont.descender
            } else {
                runAscent = ascent
                runDescent = descent
            }
            let rect = CGRect(
                x: x0 - style.paddingHorizontal,
                y: origin.y - runDescent - style.paddingVertical,
                width: (x1 - x0) + 2 * style.paddingHorizontal,
                height: (runAscent + runDescent) + 2 * style.paddingVertical
            )

            ctx.saveGState()
            if let fill = style.fillColor {
                let radius = max(0, min(style.cornerRadius, min(rect.width, rect.height) / 2))
                ctx.setFillColor(fill.cgColor)
                ctx.addPath(UIBezierPath(roundedRect: rect, cornerRadius: radius).cgPath)
                ctx.fillPath()
            }
            if !style.edges.isEmpty, style.borderWidth > 0 {
                ctx.setStrokeColor(style.borderColor.cgColor)
                ctx.setLineWidth(style.borderWidth)
                if !style.dash.isEmpty {
                    ctx.setLineDash(phase: 0, lengths: style.dash)
                }
                if style.edges == .all {
                    let radius = max(0, min(style.cornerRadius, min(rect.width, rect.height) / 2))
                    ctx.addPath(UIBezierPath(roundedRect: rect, cornerRadius: radius).cgPath)
                } else {
                    // Partial borders draw as bare edge lines (CG y-up: minY is the visual
                    // bottom). `.underline { border-bottom }` = an underline per fragment,
                    // matching CSS box-decoration-break: slice.
                    let path = CGMutablePath()
                    if style.edges.contains(.bottom) {
                        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
                        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                    }
                    if style.edges.contains(.top) {
                        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
                        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                    }
                    if style.edges.contains(.left) {
                        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
                        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                    }
                    if style.edges.contains(.right) {
                        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
                        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                    }
                    ctx.addPath(path)
                }
                ctx.strokePath()
            }
            ctx.restoreGState()
        }
    }

    // MARK: - Dialogue background box

    /// Fills a rounded background box behind quoted dialogue marked with
    /// `DialogueHighlighter.boxColorAttribute` (the "對話底色框" decoration). Drawn before the
    /// glyphs so the (optionally tinted) dialogue text sits on top. Offsets are read from the
    /// original line, matching `drawInlineBorderBoxes`; dialogue on a justified line may sit a
    /// hair inside the stretched glyphs.
    private static func drawDialogueBoxIfNeeded(
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

        var lineAscent: CGFloat = 0
        var lineDescent: CGFloat = 0
        CTLineGetTypographicBounds(line, &lineAscent, &lineDescent, nil)

        let boxStyle = CoreTextDialogueBox.currentStyle

        attrStr.enumerateAttribute(
            DialogueHighlighter.boxColorAttribute,
            in: NSRange(location: lineStart, length: length),
            options: []
        ) { value, range, _ in
            guard let color = value as? UIColor, range.length > 0 else { return }

            let startOffset = CTLineGetOffsetForStringIndex(line, range.location, nil)
            let endOffset = CTLineGetOffsetForStringIndex(line, range.location + range.length, nil)
            let x0 = origin.x + min(startOffset, endOffset)
            let x1 = origin.x + max(startOffset, endOffset)
            guard x1 > x0 else { return }

            // Hug the dialogue run's own font box rather than the line's tallest glyph.
            let ascent: CGFloat
            let descent: CGFloat
            if let runFont = attrStr.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont {
                ascent = runFont.ascender
                descent = -runFont.descender
            } else {
                ascent = lineAscent
                descent = lineDescent
            }

            let padH: CGFloat = 1.5
            let padV: CGFloat = 1.0
            let rect = CGRect(
                x: x0 - padH,
                y: origin.y - descent - padV,
                width: (x1 - x0) + 2 * padH,
                height: (ascent + descent) + 2 * padV
            )
            CoreTextDialogueBox.fill(rect: rect, baseColor: color, style: boxStyle, in: ctx)
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
        // Non-justified paragraphs (centered heading, right-aligned, natural): draw CoreText's own
        // line untouched — its origin already encodes the alignment.
        guard isJustified else { return line }

        // Rebuild the line from its own substring instead of reusing `line`. This is the crux of
        // the "声。 / 是！ sprayed across the whole column" regression: with a `.justified` paragraph
        // style the CTFramesetter can hand back a CTLine it has ALREADY stretched to the column
        // width — a paragraph's last line included, depending on iOS version and how the trailing
        // "\n" folds into the range. Returning that frame line for a last line (the old
        // `guard …, !isParagraphLastLine else { return line }` early-out did exactly this) draws it
        // pre-stretched no matter what we decide below. A line freshly built from the substring is
        // always at its natural width, so WE own the stretching, never the framesetter.
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

        // A paragraph's last line is NEVER justified — return it at its natural width. Built from
        // the substring above, so it is guaranteed un-stretched regardless of what the framesetter
        // did to `line`.
        if isParagraphLastLine { return naturalLine }

        // Measure without the trailing whitespace: a Latin line almost always ends at the space it
        // wrapped on, and CoreText does not stretch that space anyway. Counting it makes the line
        // look "already full", which would skip justification and leave English ragged.
        let naturalWidth = CTLineGetTypographicBounds(naturalLine, nil, nil, nil)
            - CTLineGetTrailingWhitespaceWidth(naturalLine)
        let coverage = naturalWidth / Double(availableWidth)

        if coverage < 0.7 {
            return naturalLine // skip justification for very short lines (e.g. a <br>-clipped tail)
        }

        // Never justify a line that already meets or exceeds the target width. At factor 1.0
        // CTLineCreateJustifiedLine does not merely stretch — it also COMPRESSES to hit the target,
        // and the first things it squeezes are CJK punctuation (（ ） ？ ，), which then visibly
        // overlap each other. Justification means distributing space that is left over; when there
        // is none, leave the line as CoreText laid it out.
        guard coverage < 1.0 else { return naturalLine }

        // Justify EVERY qualifying line — CJK, Latin, and mixed alike. We used to gate this to
        // CJK-dominant lines (`isCJKDominant && coverage > 0.85`), which left Latin and mixed lines
        // ragged on the right edge; the gate is gone.
        //
        // The distribution is hand-rolled rather than CTLineCreateJustifiedLine. That API is
        // unusable here: while stretching a CJK line it ALSO squeezes full-width punctuation
        // (（ ） ？ ，) per CJK convention, and squeezes hard enough that the glyphs visibly overlap.
        // The compression is internal to the API — no parameter suppresses it. Legado hits the same
        // wall and distributes the residual by hand; this is that algorithm on CoreText.
        return manuallyJustifiedLine(
            justifiable,
            naturalWidth: naturalWidth,
            availableWidth: availableWidth
        ) ?? naturalLine
    }

    /// Spreads the leftover width across a line by ADDING spacing only — never compressing.
    ///
    /// Latin lines take the space on their word gaps (prying letters apart inside a word reads
    /// wrong); CJK lines take it between grapheme clusters, which is what CJK justification means.
    /// The final cluster never receives spacing: `.kern` is advance placed AFTER a glyph, so
    /// spacing the last one would push the line past the right margin.
    private static func manuallyJustifiedLine(
        _ attributed: NSAttributedString,
        naturalWidth: Double,
        availableWidth: CGFloat
    ) -> CTLine? {
        let residual = Double(availableWidth) - naturalWidth
        guard residual > 0.5 else { return nil }

        let nsString = attributed.string as NSString
        guard nsString.length > 1 else { return nil }

        // Walk grapheme clusters: an emoji or combining sequence must stay one unit, otherwise the
        // added advance lands *inside* it and tears the glyph apart.
        var clusters: [NSRange] = []
        var index = 0
        while index < nsString.length {
            let range = nsString.rangeOfComposedCharacterSequence(at: index)
            clusters.append(range)
            index = range.location + range.length
        }
        let gaps = clusters.dropLast() // every cluster but the last can carry trailing space
        guard !gaps.isEmpty else { return nil }

        let spaces = gaps.filter { nsString.substring(with: $0) == " " }
        let targets: [NSRange]
        if spaces.count > 1 {
            targets = spaces // Latin: all of it goes on the word spaces
        } else {
            // CJK: spread between characters, but NEVER around punctuation. A full-width CJK mark
            // (（ ） ？ ，) already carries half a character of built-in blank, so letter spacing
            // added there is exactly what blows 「（？）」 apart — while the paragraph's last line,
            // which is never justified, stays tight. CLREQ (and Legado's postPanc/prePanc tables)
            // treat punctuation as the thing you COMPRESS first, never the thing you stretch.
            let letters = gaps.indices.filter { index in
                if isCJKPunctuation(nsString.substring(with: gaps[index])) { return false }
                let next = index + 1
                if next < clusters.count,
                   isCJKPunctuation(nsString.substring(with: clusters[next])) {
                    return false
                }
                return true
            }.map { gaps[$0] }
            // A line that is mostly punctuation has too few letter gaps to absorb the residual —
            // cramming it into one or two would look worse than spreading it everywhere.
            targets = letters.count >= max(1, gaps.count / 3) ? letters : Array(gaps)
        }

        let extra = CGFloat(residual / Double(targets.count))
        let mutable = NSMutableAttributedString(attributedString: attributed)
        for cluster in targets {
            // Attach to the cluster's final unit so a multi-unit cluster is not pried open inside.
            let tail = NSRange(location: cluster.location + cluster.length - 1, length: 1)
            let existing = (mutable.attribute(.kern, at: tail.location, effectiveRange: nil) as? CGFloat) ?? 0
            mutable.addAttribute(.kern, value: existing + extra, range: tail)
        }
        return CTLineCreateWithAttributedString(mutable)
    }

    /// CJK punctuation, mirroring the postPanc / prePanc tables in Legado's ZhLayout.
    ///
    /// These glyphs take a full-width advance but are only half-inked — the blank is baked into the
    /// glyph itself. Letter spacing added around them double-counts that blank, which is what makes
    /// justified CJK punctuation look scattered.
    private static let cjkPunctuation: Set<String> = [
        "，", "。", "、", "：", "；", "？", "！", "…", "—", "·", "～",
        "）", "》", "】", "」", "』", "”", "’",
        "（", "《", "【", "「", "『", "“", "‘",
    ]

    private static func isCJKPunctuation(_ text: String) -> Bool {
        cjkPunctuation.contains(text)
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
