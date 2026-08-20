import CoreFoundation
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
        let line: CTLine            // the shaped line, retained for precise
                                    // string-index → typographic-offset mapping
    }

    func breakLines(attributed: NSAttributedString, maxWidth: CGFloat) -> [LineBreak] {
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let nsString = attributed.string as NSString
        var lines: [LineBreak] = []
        var charIndex = 0
        let total = attributed.length
        var index = 0
        while charIndex < total {
            guard let lineBreak = breakNextLine(
                typesetter: typesetter,
                charIndex: &charIndex,
                maxWidth: maxWidth,
                attributed: attributed,
                nsString: nsString,
                total: total
            ) else {
                break
            }
            lines.append(lineBreak)
            index += 1
            if index > 10_000 { break } // defensive: never infinite-loop on glyph-less input
        }
        return lines
    }

    func breakNextLine(
        typesetter: CTTypesetter,
        charIndex: inout Int,
        maxWidth: CGFloat,
        attributed: NSAttributedString,
        nsString: NSString,
        total: Int,
        recordMemory: Bool = true
    ) -> LineBreak? {
        guard charIndex < total else { return nil }
        if recordMemory {
            MemoryTracker.record(.ctLineRun, bytes: 192)  // ~192B per retained CTLine (estimate)
        }
        var count = CTTypesetterSuggestLineBreak(typesetter, charIndex, maxWidth)

        // CTTypesetter can suggest a break inside a grapheme cluster
        // (emoji ZWJ sequences, combining marks) when the cluster is wider
        // than maxWidth. Snap the suggested count DOWN to the cluster
        // boundary so lines never cut a cluster.
        count = snapToCluster(nsString, count: count, charIndex: charIndex)
        if count <= 0 {
            // Nothing (or no whole cluster) fits: force the first grapheme
            // cluster onto the line — overflow accepted (CSS overflow).
            let cluster = nsString.rangeOfComposedCharacterSequence(at: charIndex)
            count = min(cluster.location + cluster.length, total) - charIndex
            guard count > 0 else { return nil }
            let line = CTTypesetterCreateLine(typesetter, CFRange(location: charIndex, length: count))
            let (width, ascent, descent) = metrics(for: line)
            charIndex += count
            return LineBreak(
                range: NSRange(location: charIndex - count, length: count),
                width: width, ascent: ascent, descent: descent,
                line: line
            )
        }

        var line = CTTypesetterCreateLine(typesetter, CFRange(location: charIndex, length: count))
        var (width, ascent, descent) = metrics(for: line)
        // CTTypesetterSuggestLineBreak fits glyphs up to the last
        // non-whitespace glyph, but the returned count can include a
        // trailing space whose advance pushes CTLineGetTypographicBounds
        // past maxWidth (measured 103.6 at maxWidth 100 for SF 16pt).
        // Trim until the line truly fits: the breaker's contract is that
        // returned lines never exceed maxWidth.
        let originalCount = count
        while width > maxWidth && count > 1 {
            count -= 1
            line = CTTypesetterCreateLine(typesetter, CFRange(location: charIndex, length: count))
            (width, ascent, descent) = metrics(for: line)
        }
        // The trim above can land inside a grapheme cluster — snap down again.
        let snapped = snapToCluster(nsString, count: count, charIndex: charIndex)
        if snapped <= 0 {
            // The trim cut into a cluster wider than the line: force the
            // whole cluster onto the line (overflow accepted).
            let cluster = nsString.rangeOfComposedCharacterSequence(at: charIndex)
            count = min(cluster.location + cluster.length, total) - charIndex
            guard count > 0 else { return nil }
            line = CTTypesetterCreateLine(typesetter, CFRange(location: charIndex, length: count))
            (width, ascent, descent) = metrics(for: line)
        } else if snapped != count {
            count = snapped
            line = CTTypesetterCreateLine(typesetter, CFRange(location: charIndex, length: count))
            (width, ascent, descent) = metrics(for: line)
        }
        // If the trim removed ONLY trailing whitespace, keep it in the
        // RANGE (the space is part of the line's rendered advance and keeps
        // source parity exact) — WITHOUT re-measuring, so the width stays
        // within maxWidth.
        if count < originalCount {
            let removed = nsString.substring(
                with: NSRange(location: charIndex + count, length: originalCount - count)
            )
            if removed.allSatisfy({ $0 == " " || $0 == "\t" }) {
                count = originalCount
            }
        }
        guard count > 0 else { return nil }
        charIndex += count
        return LineBreak(
            range: NSRange(location: charIndex - count, length: count),
            width: width, ascent: ascent, descent: descent,
            line: line
        )
    }

    /// Snaps a (suggested or trimmed) line length down to a grapheme-cluster
    /// boundary. Returns <= 0 when the last kept character sits inside a
    /// cluster that starts at or before `charIndex` (nothing kept whole).
    private func snapToCluster(_ ns: NSString, count: Int, charIndex: Int) -> Int {
        guard count >= 1 else { return count }
        let lineEnd = charIndex + count
        let cluster = ns.rangeOfComposedCharacterSequence(at: lineEnd - 1)
        if cluster.location + cluster.length > lineEnd {
            return cluster.location - charIndex
        }
        return count
    }

    private func metrics(for line: CTLine) -> (CGFloat, CGFloat, CGFloat) {
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        return (width, ascent, descent)
    }
}
