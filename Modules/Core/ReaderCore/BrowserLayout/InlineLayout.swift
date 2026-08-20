import CoreText
import Foundation
import UIKit

/// One unit of inline content. `text` arrives ALREADY whitespace-collapsed by
/// `BoxTreeBuilder` (per `WhiteSpaceMode`); `sourceRange` is the run's span in
/// the chapter `sourceText`; `atomic` non-nil means a replaced element (image).
struct InlineRun {
    let text: String
    let style: ComputedStyle
    let sourceRange: NSRange
    let nodeID: Int
    let linkTarget: String?
    /// True for `<br>`: the text is "\n" and must survive all whitespace modes.
    let isHardBreak: Bool
    let atomic: AtomicInline?

    init(
        text: String,
        style: ComputedStyle,
        sourceRange: NSRange = NSRange(location: 0, length: 0),
        nodeID: Int = -1,
        linkTarget: String? = nil,
        isHardBreak: Bool = false,
        atomic: AtomicInline? = nil
    ) {
        self.text = text
        self.style = style
        self.sourceRange = sourceRange
        self.nodeID = nodeID
        self.linkTarget = linkTarget
        self.isHardBreak = isHardBreak
        self.atomic = atomic
    }
}

/// Inline formatting: builds the attributed string from pre-collapsed runs,
/// shapes text via CoreText (CoreTextLineBreaker), and stacks line boxes under
/// the CSS line-height model. Runs carry source ranges; line-run slices keep
/// them so fragments can trace back to the source text.
enum InlineLayout {

    /// Shared whitespace collapse for one text node. `\n` (from `<br>` or
    /// preserved newlines) is never collapsed away. Collapsing per CSS mode:
    /// - normal / nowrap: all whitespace runs (incl. `\n`) → single space
    /// - pre / preWrap: verbatim
    /// - preLine: horizontal whitespace runs → single space, `\n` preserved
    static func collapseText(_ text: String, mode: WhiteSpaceMode) -> String {
        switch mode {
        case .normal, .nowrap:
            // CSS Text §4.1 — ONLY space, tab, line feed, carriage return and
            // form feed are collapsible. `\s` is wrong here: ICU expands it to
            // \p{Z}, which swallows U+00A0 NO-BREAK SPACE. A page whose only
            // content is `<p>&#160;</p>` (the 掌阅 full-screen background-image
            // page: 36+ chapters in 红楼梦) then produced zero runs, zero lines
            // and zero pages, so its body background-image never got a page to
            // paint on and the chapter was reported empty-renderable-content.
            return text.replacingOccurrences(of: #"[ \t\n\r\f]+"#, with: " ", options: .regularExpression)
        case .pre, .preWrap:
            return text
        case .preLine:
            return text.replacingOccurrences(of: #"[ \t\r\f]+"#, with: " ", options: .regularExpression)
        }
    }

    static func layoutLines(
        runs: [InlineRun],
        maxWidth: CGFloat,
        rootFontSize: CGFloat,
        lineHeight: CGFloat?,
        writingMode: ReaderWritingMode = .horizontal,
        sourceText: String,
        fontResolver: (([String], Int, Bool, CGFloat) -> UIFont?)? = nil,
        floatContext: FloatContext? = nil,
        blockOffsetY: CGFloat = 0
    ) -> [LayoutLine] {
        guard !runs.isEmpty else { return [] }

        func resolveFont(_ style: ComputedStyle) -> UIFont {
            font(for: style, resolver: fontResolver)
        }

        // Build the attributed string mirroring the runs. Atomic runs become
        // U+FFFC with a CTRunDelegate sized to the image so the line breaker
        // treats them as atomic, unbreakable boxes.
        let attributed = NSMutableAttributedString()
        var runAttributedStart: [Int] = []   // attributed-string offset per run
        var attributedCursor = 0
        var delegateBoxes: [AtomicInlineBox] = []
        for run in runs {
            runAttributedStart.append(attributedCursor)
            if let atomic = run.atomic {
                // CSS 2.1 §10.8.1: an inline replaced element with
                // `vertical-align: baseline` sits with its BOTTOM margin edge ON
                // the baseline — ascent = its full height, descent = 0.
                let box = AtomicInlineBox(width: atomic.usedSize.width,
                                          ascent: atomic.usedSize.height,
                                          descent: 0)
                delegateBoxes.append(box)
                var callbacks = AtomicInlineBox.callbacks
                let delegate = CTRunDelegateCreate(&callbacks, Unmanaged.passRetained(box).toOpaque())
                attributed.append(NSAttributedString(string: "\u{FFFC}", attributes: [
                    kCTRunDelegateAttributeName as NSAttributedString.Key: delegate as Any,
                    .font: resolveFont(run.style),
                ]))
            } else {
                attributed.append(NSAttributedString(string: run.text, attributes: [
                    .font: resolveFont(run.style),
                    .foregroundColor: run.style.color ?? .black,
                ]))
            }
            attributedCursor += (run.atomic != nil ? 1 : (run.text as NSString).length)
        }

        let cssHeight = lineHeight ?? runs.first?.style.lineHeight
        func makeLayoutLine(
            _ breakInfo: CoreTextLineBreaker.LineBreak,
            interval: InlineInterval,
            yTop: CGFloat
        ) -> LayoutLine {
            let lineRange = breakInfo.range
            let lineEnd = lineRange.location + lineRange.length

            // Attribute runs intersecting this line's char range, by offset.
            var lineRuns: [LineRun] = []
            var xCursor: CGFloat = 0
            for (index, run) in runs.enumerated() {
                let runStart = runAttributedStart[index]
                let runLen = run.atomic != nil ? 1 : (run.text as NSString).length
                let runEnd = runStart + runLen
                let intersectStart = max(lineRange.location, runStart)
                let intersectEnd = min(lineEnd, runEnd)
                guard intersectEnd > intersectStart else { continue }

                // Source range of this slice: shift by the run's source offset.
                let sliceLen = run.atomic != nil ? 0 : (intersectEnd - intersectStart)
                let sourceOffset = run.sourceRange.location + max(0, intersectStart - runStart)
                let sliceSource = NSRange(location: sourceOffset, length: sliceLen)

                let width: CGFloat
                if let atomic = run.atomic {
                    width = atomic.usedSize.width
                } else {
                    let sub = attributed.attributedSubstring(
                        from: NSRange(location: intersectStart, length: intersectEnd - intersectStart)
                    )
                    let subLine = CTLineCreateWithAttributedString(sub)
                    width = CTLineGetTypographicBounds(subLine, nil, nil, nil)
                }

                lineRuns.append(LineRun(
                    sourceRange: sliceSource,
                    x: xCursor,
                    width: width,
                    style: run.style,
                    font: resolveFont(run.style),
                    nodeID: run.nodeID,
                    linkTarget: run.linkTarget,
                    atomic: run.atomic
                ))
                xCursor += width
            }

            // The breaker's measured line width (≤ maxWidth) is authoritative.
            if let last = lineRuns.last, last.atomic == nil {
                let clampedWidth: CGFloat
                if lineRuns.count == 1 {
                    clampedWidth = breakInfo.width
                } else {
                    let sumOthers = lineRuns.dropLast().reduce(CGFloat(0)) { $0 + $1.width }
                    clampedWidth = max(0, breakInfo.width - sumOthers)
                }
                lineRuns[lineRuns.count - 1] = LineRun(
                    sourceRange: last.sourceRange,
                    x: last.x,
                    width: clampedWidth,
                    style: last.style, font: last.font,
                    nodeID: last.nodeID, linkTarget: last.linkTarget, atomic: last.atomic
                )
            }

            // Collapsing whitespace modes remove leading whitespace at the
            // START of a rendered line (e.g. after a <br> or pre-line newline).
            trimLineLeadingWhitespace(from: &lineRuns, sourceText: sourceText)

            // The FINAL line of the whole text stream also trims trailing whitespace.
            if breakInfo.range.location + breakInfo.range.length >= attributed.length {
                trimLineTrailingWhitespace(from: &lineRuns, sourceText: sourceText)
            }

            let contentHeight = breakInfo.ascent + breakInfo.descent
            let height = max(cssHeight ?? contentHeight, contentHeight)
            let extraLeading = max(0, height - contentHeight)
            let baselineOffset = extraLeading / 2 + breakInfo.ascent
            let top = yTop
            let alignSlack = alignmentOffset(
                alignment: lineRuns.first?.style.textAlign ?? .natural,
                lineWidth: breakInfo.width,
                maxWidth: interval.lineWidth
            )
            let contentX = interval.lineX + alignSlack
            return LayoutLine(
                runs: lineRuns,
                height: height,
                ascent: breakInfo.ascent,
                descent: breakInfo.descent,
                top: top,
                baseline: yTop + baselineOffset,
                contentX: contentX,
                ctLine: breakInfo.line
            )
        }

        let breaker = CoreTextLineBreaker()
        let noExclusion = InlineInterval(
            lineX: 0,
            lineWidth: maxWidth,
            leftIntrusion: 0,
            rightIntrusion: 0
        )

        // Preserve the pre-float pipeline byte-for-byte when no exclusion is
        // active: CoreText computes the complete break list before run slicing
        // or line construction. Only float-affected boxes take the band-aware
        // incremental path below.
        if floatContext?.activeFloats.isEmpty != false {
            let effectiveMaxWidth = (runs.contains { $0.style.whiteSpace == .nowrap })
                ? CGFloat.greatestFiniteMagnitude
                : maxWidth
            let breaks = breaker.breakLines(
                attributed: attributed,
                maxWidth: effectiveMaxWidth
            )
            var yTop: CGFloat = 0
            let lines = breaks.map { breakInfo in
                let line = makeLayoutLine(breakInfo, interval: noExclusion, yTop: yTop)
                yTop += line.height
                return line
            }
            _ = delegateBoxes
            return lines
        }

        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let nsString = attributed.string as NSString
        var result: [LayoutLine] = []
        var charIndex = 0
        var yTop: CGFloat = 0
        var loopCount = 0

        while charIndex < attributed.length {
            loopCount += 1
            if loopCount > 10_000 { break }

            let globalY = blockOffsetY + yTop
            let lineStart = charIndex
            var queryHeight: CGFloat = 0.1
            var resolvedInterval: InlineInterval?
            var resolvedBreak: CoreTextLineBreaker.LineBreak?
            var resolvedNextIndex = lineStart
            var advancedBelowFloats = false

            // The exclusion interval is a property of the ACTUAL line band,
            // not a fixed 20pt guess. Shape tentatively, expand the queried
            // band to the measured line-box height, then re-break at the final
            // interval. queryHeight only grows, so this converges instead of
            // oscillating when a tall inline image moves to the next line.
            for _ in 0..<8 {
                let interval = floatContext?.availableInterval(y: globalY, height: queryHeight)
                    ?? noExclusion

                if let fc = floatContext, interval.lineWidth <= 0 {
                    let upcomingBottoms = fc.activeFloats.map(\.bottom).filter { $0 > globalY }
                    if let nextY = upcomingBottoms.min() {
                        yTop = nextY - blockOffsetY
                        advancedBelowFloats = true
                    }
                    break
                }

                let effectiveMaxWidth = (runs.contains { $0.style.whiteSpace == .nowrap })
                    ? CGFloat.greatestFiniteMagnitude
                    : interval.lineWidth
                var trialIndex = lineStart
                guard let candidate = breaker.breakNextLine(
                    typesetter: typesetter,
                    charIndex: &trialIndex,
                    maxWidth: effectiveMaxWidth,
                    attributed: attributed,
                    nsString: nsString,
                    total: attributed.length,
                    recordMemory: false
                ) else {
                    break
                }

                let contentHeight = candidate.ascent + candidate.descent
                let actualHeight = max(cssHeight ?? contentHeight, contentHeight)
                if actualHeight > queryHeight + 0.001 {
                    queryHeight = actualHeight
                    continue
                }

                resolvedInterval = interval
                resolvedBreak = candidate
                resolvedNextIndex = trialIndex
                break
            }

            if advancedBelowFloats { continue }
            guard let interval = resolvedInterval, let breakInfo = resolvedBreak else { break }
            charIndex = resolvedNextIndex
            MemoryTracker.record(.ctLineRun, bytes: 192)

            let line = makeLayoutLine(breakInfo, interval: interval, yTop: yTop)
            result.append(line)
            yTop += line.height
        }

        // The attributed string (and its delegates) go out of scope here; the
        // delegate callbacks' dealloc releases each AtomicInlineBox.
        _ = delegateBoxes
        return result
    }

    /// Removes leading whitespace from the first run of a line when the run's
    /// whitespace mode collapses spaces (normal/nowrap/preLine).
    private static func trimLineLeadingWhitespace(from runs: inout [LineRun], sourceText: String) {
        let ns = sourceText as NSString
        while var first = runs.first {
            if first.atomic != nil { return }
            let mode = first.style.whiteSpace
            guard mode == .normal || mode == .nowrap || mode == .preLine else { return }
            guard first.sourceRange.location >= 0,
                  first.sourceRange.location + first.sourceRange.length <= ns.length else { return }
            var advance = 0
            while advance < first.sourceRange.length {
                let c = ns.character(at: first.sourceRange.location + advance)
                if c == 0x20 || c == 0x09 { advance += 1 } else { break }
            }
            guard advance > 0 else { return }
            let spaceWidth: CGFloat = {
                let space = NSAttributedString(string: String(repeating: " ", count: advance),
                                               attributes: [.font: first.font])
                let spaceLine = CTLineCreateWithAttributedString(space)
                return CTLineGetTypographicBounds(spaceLine, nil, nil, nil)
            }()
            let newLength = first.sourceRange.length - advance
            if newLength > 0 {
                first = LineRun(
                    sourceRange: NSRange(location: first.sourceRange.location + advance, length: newLength),
                    x: first.x + spaceWidth,
                    width: first.width - spaceWidth,
                    style: first.style, font: first.font,
                    nodeID: first.nodeID, linkTarget: first.linkTarget, atomic: first.atomic
                )
                runs[0] = first
                return
            }
            // The first run was entirely whitespace: drop it and re-check.
            runs.removeFirst()
        }
    }

    /// Removes trailing whitespace from the last run of a line for collapsing whitespace modes.
    private static func trimLineTrailingWhitespace(from runs: inout [LineRun], sourceText: String) {
        guard var last = runs.last, last.atomic == nil else { return }
        let mode = last.style.whiteSpace
        guard mode == .normal || mode == .nowrap || mode == .preLine else { return }
        let ns = sourceText as NSString
        guard last.sourceRange.location >= 0,
              last.sourceRange.location + last.sourceRange.length <= ns.length else { return }
        var tail = 0
        while tail < last.sourceRange.length {
            let c = ns.character(at: last.sourceRange.location + last.sourceRange.length - 1 - tail)
            if c == 0x20 || c == 0x09 { tail += 1 } else { break }
        }
        guard tail > 0 else { return }
        let newLength = last.sourceRange.length - tail
        if newLength > 0 {
            last = LineRun(
                sourceRange: NSRange(location: last.sourceRange.location, length: newLength),
                x: last.x, width: last.width, style: last.style, font: last.font,
                nodeID: last.nodeID, linkTarget: last.linkTarget, atomic: last.atomic
            )
            runs[runs.count - 1] = last
        } else {
            runs.removeLast()
        }
    }

    private static func alignmentOffset(alignment: NSTextAlignment, lineWidth: CGFloat, maxWidth: CGFloat) -> CGFloat {
        let slack = max(0, maxWidth - lineWidth)
        switch alignment {
        case .center: return slack / 2
        case .right: return slack
        default: return 0
        }
    }

    static func font(for style: ComputedStyle, resolver: (([String], Int, Bool, CGFloat) -> UIFont?)? = nil) -> UIFont {
        if let resolver,
           let resolved = resolver(style.fontFamilies, style.fontWeight, style.isItalic, style.fontSize) {
            return resolved
        }
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

/// Retained by the CTRunDelegate; freed by the delegate's dealloc callback.
private final class AtomicInlineBox {
    let width: CGFloat
    let ascent: CGFloat
    let descent: CGFloat
    init(width: CGFloat, ascent: CGFloat, descent: CGFloat) {
        self.width = width
        self.ascent = ascent
        self.descent = descent
    }

    static let callbacks: CTRunDelegateCallbacks = {
        var callbacks = CTRunDelegateCallbacks(
            version: kCTRunDelegateVersion1,
            dealloc: { ptr in
                _ = Unmanaged<AtomicInlineBox>.fromOpaque(ptr).takeRetainedValue()
            },
            getAscent: { ptr in
                Unmanaged<AtomicInlineBox>.fromOpaque(ptr).takeUnretainedValue().ascent
            },
            getDescent: { ptr in
                Unmanaged<AtomicInlineBox>.fromOpaque(ptr).takeUnretainedValue().descent
            },
            getWidth: { ptr in
                Unmanaged<AtomicInlineBox>.fromOpaque(ptr).takeUnretainedValue().width
            }
        )
        return callbacks
    }()
}
