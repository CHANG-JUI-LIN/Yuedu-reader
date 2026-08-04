import CoreText
import Foundation
import UIKit

/// The ONLY place the browser engine touches CoreText for text in Phase 1:
/// shaping + line breaking + typographic metrics. Glyph drawing is explicitly
/// out of scope (DisplayList carries text ranges; a future draw phase renders them).
final class CoreTextLineBreaker {

    struct LineBreak {
        let range: NSRange          // into the input attributed string
        let width: CGFloat          // typographic width (max coordinate)
        let ascent: CGFloat
        let descent: CGFloat
    }

    func breakLines(attributed: NSAttributedString, maxWidth: CGFloat) -> [LineBreak] {
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        var lines: [LineBreak] = []
        var charIndex = 0
        let total = attributed.length
        var index = 0
        while charIndex < total {
            var count = CTTypesetterSuggestLineBreak(typesetter, charIndex, maxWidth)
            guard count > 0 else { break }
            var line = CTTypesetterCreateLine(typesetter, CFRange(location: charIndex, length: count))
            var (width, ascent, descent) = metrics(for: line)
            // CTTypesetterSuggestLineBreak fits glyphs up to the last
            // non-whitespace glyph, but the returned count can include a
            // trailing space whose advance pushes CTLineGetTypographicBounds
            // past maxWidth (measured 103.6 at maxWidth 100 for SF 16pt).
            // Trim until the line truly fits: the breaker's contract is that
            // returned lines never exceed maxWidth.
            while width > maxWidth && count > 1 {
                count -= 1
                line = CTTypesetterCreateLine(typesetter, CFRange(location: charIndex, length: count))
                (width, ascent, descent) = metrics(for: line)
            }
            lines.append(LineBreak(range: NSRange(location: charIndex, length: count),
                                   width: width, ascent: ascent, descent: descent))
            charIndex += count
            index += 1
            if index > 10_000 { break } // defensive: never infinite-loop on glyph-less input
        }
        return lines
    }

    private func metrics(for line: CTLine) -> (CGFloat, CGFloat, CGFloat) {
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        return (width, ascent, descent)
    }
}
