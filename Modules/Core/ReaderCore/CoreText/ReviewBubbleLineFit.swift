import CoreText
import UIKit

/// Keeps a 段評 bubble on the line its text ends on by squeezing that line's full-width
/// punctuation, as 起点 and 微信讀書 squeeze theirs.
///
/// The bubble is glued to the character before it (`NodeAttributedStringRenderer
/// .textSizedImageGlue`), so a bubble that does not fit brings that character down with it,
/// together with every mark that cannot start a line. The line above ends short although its
/// text would have fit: 「“你这和尚，是给你师兄送人」 over 「罢。”(9)」 (feedback #62) and
/// 「迅速解决，稳定Z市的局」 over 「势。(2)」 (feedback #67). A full-width mark's em box is half
/// blank; taking up to half an em of that blank from each mark on the line usually makes room
/// for the bubble. When it does not, the line is left as CoreText broke it, and
/// `CoreTextHorizontalLineDrawer` draws the short line at its natural width.
///
/// Runs once per chapter build, over the finished string, at the column the chapter is laid out
/// in: pages and scroll chunks typeset that same string at that same width, so every view of
/// the chapter breaks the squeezed line the same way. Only `.kern` changes, never the text, so
/// character offsets — reading positions, highlights, selection — are untouched.
enum ReviewBubbleLineFit {
    /// The blank a mark always keeps, in ems, so squeezed marks never touch their neighbours.
    private static let keptBlank: CGFloat = 0.08
    /// The most a mark gives up, in ems: half its box, the CJK half-width form.
    private static let maximumSqueeze: CGFloat = 0.5
    /// Squeezed this much beyond the bare overflow, so rounding never leaves the line a hair over.
    private static let margin: CGFloat = 0.5

    /// Marks whose blank trails the glyph; the squeeze is their own `.kern`.
    private static let trailingBlank: Set<Character> = [
        "，", "。", "、", "；", "：", "！", "？", "”", "’", "」", "』", "）", "】", "》", "〉", "〕", "］", "｝",
    ]
    /// Marks whose blank leads the glyph; the squeeze is the `.kern` of the character before.
    private static let leadingBlank: Set<Character> = [
        "“", "‘", "「", "『", "（", "【", "《", "〈", "〔", "［", "｛",
    ]

    /// Squeezes the line before every bubble whose glue took its paragraph's tail down, where
    /// squeezing makes room. Returns how many bubbles it kept up.
    @discardableResult
    static func fit(_ string: NSMutableAttributedString, lineWidth: CGFloat) -> Int {
        let text = string.string as NSString
        let marker = NodeAttributedStringRenderer.textSizedImageGlue + "\u{FFFC}"
        var kept = 0
        var searchFrom = 0
        while searchFrom < text.length {
            let found = text.range(of: marker, range: NSRange(location: searchFrom, length: text.length - searchFrom))
            guard found.location != NSNotFound else { break }
            if keepUp(bubble: NSMaxRange(found) - 1, in: string, text: text, lineWidth: lineWidth) {
                kept += 1
            }
            searchFrom = NSMaxRange(found)
        }
        return kept
    }

    private static func keepUp(bubble: Int, in string: NSMutableAttributedString, text: NSString, lineWidth: CGFloat) -> Bool {
        let paragraph = text.paragraphRange(for: NSRange(location: bubble, length: 1))
        let style = string.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle
        let lines = lineRanges(of: paragraph, in: string, style: style, lineWidth: lineWidth)
        guard let bubbleLine = lines.firstIndex(where: { NSLocationInRange(bubble, $0) }), bubbleLine > 0 else {
            return false
        }
        let lineStart = lines[bubbleLine - 1].location
        let joined = NSRange(location: lineStart, length: bubble + 1 - lineStart)
        let available = availableWidth(lineStart: lineStart, paragraph: paragraph, style: style, lineWidth: lineWidth)
        // Only a tail the bubble took down. Where the text alone overruns the line, the same
        // paragraph without a bubble breaks there too, and squeezing would set this one
        // tighter than the text around it.
        let textAlone = CTLineCreateWithAttributedString(
            string.attributedSubstring(from: NSRange(location: lineStart, length: bubble - 1 - lineStart))
        )
        guard CGFloat(CTLineGetTypographicBounds(textAlone, nil, nil, nil)) <= available else { return false }
        let natural = CTLineCreateWithAttributedString(string.attributedSubstring(from: joined))
        let overflow = CGFloat(CTLineGetTypographicBounds(natural, nil, nil, nil)) - available + margin
        guard overflow > 0 else { return false }

        let squeezes = squeezableBlanks(of: natural, lineStart: lineStart, glue: bubble - 1, in: string)
        let room = squeezes.reduce(0) { $0 + $1.amount }
        guard room >= overflow else { return false }

        let previous = squeezes.map { (index: $0.kernIndex, kern: kern(at: $0.kernIndex, in: string)) }
        let share = overflow / room
        for squeeze in squeezes {
            let index = squeeze.kernIndex
            string.addAttribute(.kern, value: kern(at: index, in: string) - squeeze.amount * share, range: NSRange(location: index, length: 1))
        }
        // The typesetter has the last word: keep the squeeze only where it now breaks after the bubble.
        let refit = lineRanges(of: paragraph, in: string, style: style, lineWidth: lineWidth)
        if refit.contains(where: { $0.location == lineStart && NSLocationInRange(bubble, $0) }) {
            return true
        }
        for (index, kern) in previous {
            if kern == 0 {
                string.removeAttribute(.kern, range: NSRange(location: index, length: 1))
            } else {
                string.addAttribute(.kern, value: kern, range: NSRange(location: index, length: 1))
            }
        }
        AppLogger.render("reviewBubbleLineFit: squeeze did not keep the bubble up", context: [
            "location": bubble,
            "overflow": Double(overflow),
            "room": Double(room),
        ])
        return false
    }

    /// The lines CoreText breaks `paragraph` into: the same breaks the framesetter makes,
    /// with the paragraph's first-line, head and tail indents taken off the column.
    private static func lineRanges(
        of paragraph: NSRange,
        in string: NSAttributedString,
        style: NSParagraphStyle?,
        lineWidth: CGFloat
    ) -> [NSRange] {
        let typesetter = CTTypesetterCreateWithAttributedString(string.attributedSubstring(from: paragraph))
        var lines: [NSRange] = []
        var start = 0
        while start < paragraph.length {
            let width = availableWidth(lineStart: paragraph.location + start, paragraph: paragraph, style: style, lineWidth: lineWidth)
            let count = CTTypesetterSuggestLineBreak(typesetter, start, Double(max(1, width)))
            guard count > 0 else { break }
            lines.append(NSRange(location: paragraph.location + start, length: count))
            start += count
        }
        return lines
    }

    private static func availableWidth(
        lineStart: Int,
        paragraph: NSRange,
        style: NSParagraphStyle?,
        lineWidth: CGFloat
    ) -> CGFloat {
        guard let style else { return lineWidth }
        let head = lineStart == paragraph.location ? style.firstLineHeadIndent : style.headIndent
        let trailingEdge = style.tailIndent > 0 ? style.tailIndent : lineWidth + style.tailIndent
        return trailingEdge - head
    }

    /// Each mark's blank on `line` beyond what it keeps, measured from the glyph CoreText set,
    /// in the font it fell back to: a Traditional Chinese face centres 。 and ， in their box
    /// and has less to give than a Simplified one, which sets them flush left.
    private static func squeezableBlanks(
        of line: CTLine,
        lineStart: Int,
        glue: Int,
        in string: NSAttributedString
    ) -> [(kernIndex: Int, amount: CGFloat)] {
        let text = string.string as NSString
        var squeezes: [(kernIndex: Int, amount: CGFloat)] = []
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let count = CTRunGetGlyphCount(run)
            guard count > 0,
                  let font = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont?
            else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &indices)
            var advances = [CGSize](repeating: .zero, count: count)
            var bounds = [CGRect](repeating: .zero, count: count)
            CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, count)
            CTFontGetBoundingRectsForGlyphs(font, .horizontal, glyphs, &bounds, count)
            let em = CTFontGetSize(font)
            for slot in 0..<count {
                let index = lineStart + indices[slot]
                guard index < glue, !bounds[slot].isEmpty else { continue }
                let character = Character(text.substring(with: text.rangeOfComposedCharacterSequence(at: index)))
                let blank: CGFloat
                let kernIndex: Int
                if trailingBlank.contains(character) {
                    blank = advances[slot].width - bounds[slot].maxX
                    kernIndex = index
                } else if leadingBlank.contains(character), index > lineStart {
                    blank = bounds[slot].minX
                    kernIndex = index - 1
                } else {
                    continue
                }
                let amount = min(blank - keptBlank * em, maximumSqueeze * em)
                if amount > 0 { squeezes.append((kernIndex, amount)) }
            }
        }
        return squeezes
    }

    private static func kern(at index: Int, in string: NSAttributedString) -> CGFloat {
        (string.attribute(.kern, at: index, effectiveRange: nil) as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
    }
}
