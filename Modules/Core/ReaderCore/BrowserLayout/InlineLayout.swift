import CoreText
import Foundation
import UIKit

struct InlineRun {
    let text: String
    let style: ComputedStyle
}

/// Inline formatting: collapses whitespace, shapes text via CoreText
/// (CoreTextLineBreaker), and stacks line boxes under the CSS line-height
/// model. Only fonts/colors are attached for metering; no glyph drawing.
enum InlineLayout {

    /// Collapses each run's whitespace runs to single spaces, trims, and drops
    /// empty runs. `\n` becomes a space (Phase 1: `<br>`/`white-space` support
    /// is deferred).
    static func collapseRuns(_ runs: [InlineRun]) -> [InlineRun] {
        var out: [InlineRun] = []
        for run in runs {
            var text = run.text
            text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            text = text.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { continue }
            out.append(InlineRun(text: text, style: run.style))
        }
        return out
    }

    static func layoutLines(runs: [InlineRun], maxWidth: CGFloat, rootFontSize: CGFloat, lineHeight: CGFloat?) -> [LayoutLine] {
        let collapsed = collapseRuns(runs)
        guard !collapsed.isEmpty else { return [] }

        // Build the attributed string mirroring the collapsed runs.
        let attributed = NSMutableAttributedString()
        for run in collapsed {
            attributed.append(NSAttributedString(string: run.text, attributes: [
                .font: font(for: run.style),
                .foregroundColor: run.style.color ?? .black,
            ]))
        }

        let breaks = CoreTextLineBreaker().breakLines(attributed: attributed, maxWidth: maxWidth)
        var result: [LayoutLine] = []
        var yTop: CGFloat = 0
        for breakInfo in breaks {
            let lineRange = breakInfo.range
            let lineEnd = lineRange.location + lineRange.length

            // Attribute runs intersecting this line's char range, by offset, not by search.
            var lineRuns: [LineRun] = []
            var xCursor: CGFloat = 0
            var runCursor = 0
            for run in collapsed {
                let runStart = runCursor
                let runEnd = runStart + (run.text as NSString).length
                runCursor = runEnd
                let intersectStart = max(lineRange.location, runStart)
                let intersectEnd = min(lineEnd, runEnd)
                guard intersectEnd > intersectStart else { continue }
                let sub = attributed.attributedSubstring(
                    from: NSRange(location: intersectStart, length: intersectEnd - intersectStart)
                )
                let subLine = CTLineCreateWithAttributedString(sub)
                let runWidth = CTLineGetTypographicBounds(subLine, nil, nil, nil)
                lineRuns.append(LineRun(
                    range: NSRange(location: intersectStart, length: intersectEnd - intersectStart),
                    x: xCursor,
                    width: runWidth,
                    style: run.style,
                    font: font(for: run.style)
                ))
                xCursor += runWidth
            }

            // Line-height resolution: reader override (param) wins, then the
            // run style's own line-height, then plain font metrics.
            let height = lineHeight
                ?? collapsed.first?.style.lineHeight
                ?? (breakInfo.ascent + breakInfo.descent)
            let extraLeading = max(0, height - (breakInfo.ascent + breakInfo.descent))
            let baselineOffset = extraLeading / 2 + breakInfo.ascent
            let contentX = alignmentOffset(alignment: lineRuns.first?.style.textAlign ?? .natural,
                                           lineWidth: breakInfo.width, maxWidth: maxWidth)
            result.append(LayoutLine(
                runs: lineRuns,
                height: height,
                ascent: breakInfo.ascent,
                descent: breakInfo.descent,
                top: yTop,
                baseline: yTop + baselineOffset,
                contentX: contentX
            ))
            yTop += height
        }
        return result
    }

    private static func alignmentOffset(alignment: NSTextAlignment, lineWidth: CGFloat, maxWidth: CGFloat) -> CGFloat {
        let slack = max(0, maxWidth - lineWidth)
        switch alignment {
        case .center: return slack / 2
        case .right: return slack
        default: return 0
        }
    }

    static func font(for style: ComputedStyle) -> UIFont {
        let family = style.fontFamilies.first ?? "PingFangSC-Regular"
        let base = UIFont(name: family, size: style.fontSize)
            ?? UIFont.systemFont(ofSize: style.fontSize)
        if style.isItalic && style.fontWeight >= 600 {
            if let d = base.fontDescriptor.withSymbolicTraits([.traitItalic, .traitBold]) {
                return UIFont(descriptor: d, size: style.fontSize)
            }
        }
        if style.isItalic {
            if let d = base.fontDescriptor.withSymbolicTraits(.traitItalic) {
                return UIFont(descriptor: d, size: style.fontSize)
            }
        }
        if style.fontWeight >= 600 {
            if let d = base.fontDescriptor.withSymbolicTraits(.traitBold) {
                return UIFont(descriptor: d, size: style.fontSize)
            }
        }
        return base
    }
}
