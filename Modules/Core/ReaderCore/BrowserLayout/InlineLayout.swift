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
    let ruby: RubyInlineUnit?
    /// Shared immutable chapter attributes, indexed by source UTF-16 offsets.
    var attributedSource: NSAttributedString? = nil

    init(
        text: String,
        style: ComputedStyle,
        sourceRange: NSRange = NSRange(location: 0, length: 0),
        nodeID: Int = -1,
        linkTarget: String? = nil,
        isHardBreak: Bool = false,
        atomic: AtomicInline? = nil,
        ruby: RubyInlineUnit? = nil
    ) {
        self.text = text
        self.style = style
        self.sourceRange = sourceRange
        self.nodeID = nodeID
        self.linkTarget = linkTarget
        self.isHardBreak = isHardBreak
        self.atomic = atomic
        self.ruby = ruby
        assert(atomic == nil || ruby == nil, "inline image and ruby payloads are mutually exclusive")
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
        context: InlineFormattingContext
    ) -> [LayoutLine] {
        guard !runs.isEmpty else { return [] }
        let maxWidth = context.containingInlineSize
        let lineHeight = context.lineHeight
        let sourceText = context.sourceText
        let fontResolver = context.fontResolver
        let floatContext = context.floatContext
        let blockOffsetY = context.blockOffsetY

        func resolveFont(_ style: ComputedStyle) -> UIFont {
            resolvedFont(for: style, resolver: fontResolver)
        }

        // Build the attributed string mirroring the runs. Atomic runs become
        // U+FFFC with a CTRunDelegate sized to the image so the line breaker
        // treats them as atomic, unbreakable boxes.
        let attributed = NSMutableAttributedString()
        var runAttributedStart: [Int] = []   // attributed-string offset per run
        var attributedCursor = 0
        var delegateBoxes: [AtomicInlineBox] = []
        var measuredRuby: [Int: RubyBox] = [:]
        var rubyDelegateBoxes: [RubyRunDelegateBox] = []
        for (index, run) in runs.enumerated() {
            runAttributedStart.append(attributedCursor)
            if let unit = run.ruby {
                let ruby = RubyInlineLayout.measure(unit: unit, fontResolver: fontResolver, attributedSource: run.attributedSource)
                measuredRuby[index] = ruby
                let box = RubyRunDelegateBox(ruby)
                rubyDelegateBoxes.append(box)
                var callbacks = RubyRunDelegateBox.callbacks
                let delegate = CTRunDelegateCreate(
                    &callbacks,
                    Unmanaged.passRetained(box).toOpaque()
                )
                var attributes: [NSAttributedString.Key: Any] = [
                    kCTRunDelegateAttributeName as NSAttributedString.Key: delegate as Any,
                    .font: resolveFont(run.style),
                ]
                // Ruby is atomic in the parent string, but a regex line-height
                // on its base still contributes to that parent's line box.
                var requestedHeight: CGFloat = 0
                run.attributedSource?.enumerateAttribute(.paragraphStyle, in: run.sourceRange) { value, _, _ in
                    if let paragraph = value as? NSParagraphStyle {
                        requestedHeight = max(requestedHeight, paragraph.minimumLineHeight)
                    }
                }
                if requestedHeight > 0 {
                    let paragraph = NSMutableParagraphStyle()
                    paragraph.minimumLineHeight = requestedHeight
                    attributes[.paragraphStyle] = paragraph
                }
                attributed.append(NSAttributedString(string: "\u{FFFC}", attributes: attributes))
            } else if let atomic = run.atomic {
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
                if let source = run.attributedSource {
                    attributed.append(source.attributedSubstring(from: run.sourceRange))
                } else {
                    attributed.append(NSAttributedString(
                        string: run.text,
                        attributes: textAttributes(for: run.style, resolver: fontResolver)
                    ))
                }
            }
            attributedCursor += shapedLength(of: run)
        }

        let cssHeight = lineHeight ?? runs.first?.style.lineHeight
        let lineSpacing = runs.first?.style.configLineSpacing ?? 0
        func usedHeight(_ info: CoreTextLineBreaker.LineBreak) -> CGFloat {
            var requested = cssHeight ?? 0
            attributed.enumerateAttribute(.paragraphStyle, in: info.range) { value, _, _ in
                if let paragraph = value as? NSParagraphStyle {
                    requested = max(requested, paragraph.minimumLineHeight)
                }
            }
            let spacing = NSMaxRange(info.range) < attributed.length ? lineSpacing : 0
            return max(requested, info.ascent + info.descent) + spacing
        }
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
                let runLen = shapedLength(of: run)
                let runEnd = runStart + runLen
                let intersectStart = max(lineRange.location, runStart)
                let intersectEnd = min(lineEnd, runEnd)
                guard intersectEnd > intersectStart else { continue }

                // Source range of this slice: shift by the run's source offset.
                let sliceLen: Int
                let sourceOffset: Int
                if run.atomic != nil {
                    sliceLen = 0
                    sourceOffset = run.sourceRange.location
                } else if run.ruby != nil {
                    sliceLen = run.sourceRange.length
                    sourceOffset = run.sourceRange.location
                } else {
                    sliceLen = intersectEnd - intersectStart
                    sourceOffset = run.sourceRange.location + max(0, intersectStart - runStart)
                }
                let sliceSource = NSRange(location: sourceOffset, length: sliceLen)

                let width: CGFloat
                if let atomic = run.atomic {
                    width = atomic.usedSize.width
                } else if let ruby = measuredRuby[index] {
                    width = ruby.advance
                } else {
                    let sub = attributed.attributedSubstring(
                        from: NSRange(location: intersectStart, length: intersectEnd - intersectStart)
                    )
                    let subLine = CTLineCreateWithAttributedString(sub)
                    width = CTLineGetTypographicBounds(subLine, nil, nil, nil)
                }

                lineRuns.append(LineRun(
                    sourceRange: sliceSource,
                    shapedRange: NSRange(
                        location: intersectStart,
                        length: intersectEnd - intersectStart
                    ),
                    x: xCursor,
                    width: width,
                    style: run.style,
                    font: resolveFont(run.style),
                    nodeID: run.nodeID,
                    linkTarget: run.linkTarget,
                    atomic: run.atomic,
                    ruby: measuredRuby[index]
                ))
                xCursor += width
            }

            // The breaker's measured line width (≤ maxWidth) is authoritative.
            if let last = lineRuns.last, last.atomic == nil, last.ruby == nil {
                let clampedWidth: CGFloat
                if lineRuns.count == 1 {
                    clampedWidth = breakInfo.width
                } else {
                    let sumOthers = lineRuns.dropLast().reduce(CGFloat(0)) { $0 + $1.width }
                    clampedWidth = max(0, breakInfo.width - sumOthers)
                }
                lineRuns[lineRuns.count - 1] = LineRun(
                    sourceRange: last.sourceRange,
                    shapedRange: last.shapedRange,
                    x: last.x,
                    width: clampedWidth,
                    style: last.style, font: last.font,
                    nodeID: last.nodeID,
                    linkTarget: last.linkTarget,
                    atomic: last.atomic,
                    ruby: last.ruby
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
            let height = usedHeight(breakInfo)
            let trailingSpacing = NSMaxRange(breakInfo.range) < attributed.length ? lineSpacing : 0
            let extraLeading = max(0, height - contentHeight - trailingSpacing)
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
        let noExclusion = context.baseInterval
        let needsPerLineIntervals = context.firstLineConstraint.isActive
            || context.floatContext?.activeFloats.isEmpty == false

        // Preserve the pre-float pipeline byte-for-byte when no exclusion is
        // active: CoreText computes the complete break list before run slicing
        // or line construction. Only float-affected boxes take the band-aware
        // incremental path below.
        if !needsPerLineIntervals {
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
            _ = rubyDelegateBoxes
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
                let baseInterval = context.baseAvailableInterval(
                    y: globalY,
                    height: queryHeight
                )

                if let fc = floatContext, baseInterval.lineWidth <= 0 {
                    let upcomingBottoms = fc.activeFloats.map(\.bottom).filter { $0 > globalY }
                    if let nextY = upcomingBottoms.min() {
                        yTop = nextY - blockOffsetY
                        advancedBelowFloats = true
                    }
                    break
                }

                let interval = result.isEmpty
                    ? context.firstLineConstraint.apply(to: baseInterval)
                    : baseInterval

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

                let actualHeight = usedHeight(candidate)
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
        _ = rubyDelegateBoxes
        return result
    }

    /// Removes leading whitespace from the first run of a line when the run's
    /// whitespace mode collapses spaces (normal/nowrap/preLine).
    private static func trimLineLeadingWhitespace(from runs: inout [LineRun], sourceText: String) {
        let ns = sourceText as NSString
        while var first = runs.first {
            if first.atomic != nil || first.ruby != nil { return }
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
                    shapedRange: first.shapedRange.map {
                        NSRange(location: $0.location + advance, length: max(0, $0.length - advance))
                    },
                    x: first.x + spaceWidth,
                    width: first.width - spaceWidth,
                    style: first.style, font: first.font,
                    nodeID: first.nodeID,
                    linkTarget: first.linkTarget,
                    atomic: first.atomic,
                    ruby: first.ruby
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
        guard var last = runs.last, last.atomic == nil, last.ruby == nil else { return }
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
                shapedRange: last.shapedRange.map {
                    NSRange(location: $0.location, length: max(0, $0.length - tail))
                },
                x: last.x, width: last.width, style: last.style, font: last.font,
                nodeID: last.nodeID,
                linkTarget: last.linkTarget,
                atomic: last.atomic,
                ruby: last.ruby
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

    private static func shapedLength(of run: InlineRun) -> Int {
        run.atomic != nil || run.ruby != nil ? 1 : (run.text as NSString).length
    }

    static func resolvedFont(
        for style: ComputedStyle,
        resolver: (([String], Int, Bool, CGFloat) -> UIFont?)? = nil
    ) -> UIFont {
        let weight = style.configBold ? max(700, style.fontWeight) : style.fontWeight
        let resolved = resolver?(style.fontFamilies, weight, style.isItalic, style.fontSize)
        let base = resolved
            ?? (style.fontFamilies.isEmpty ? ["PingFangSC-Regular"] : style.fontFamilies)
                .compactMap { UIFont(name: $0, size: style.fontSize) }.first
            ?? UIFont.systemFont(ofSize: style.fontSize)
        var font = base
        if style.fontWeight >= 600 || style.configBold {
            font = UserReaderFontResolver.boldVersion(of: font, size: style.fontSize)
        }
        font = ReaderFontCascade.preservingPrimary(
            font, size: style.fontSize, isBoldRequested: weight >= 600
        )
        if style.isItalic, !font.fontDescriptor.symbolicTraits.contains(.traitItalic) {
            var traits = font.fontDescriptor.symbolicTraits
            traits.insert(.traitItalic)
            if let descriptor = font.fontDescriptor.withSymbolicTraits(traits),
               descriptor.symbolicTraits.contains(.traitItalic) {
                font = UIFont(descriptor: descriptor, size: style.fontSize)
            } else {
                // CJK and regular-only embedded families have no italic face.
                // Use the shared oblique transform until these fonts expose a
                // native italic variant; keep the already-resolved bold face.
                font = HTMLAttributedStringBuilder.synthesizedObliqueFont(from: font)
            }
        }
        return font
    }

    static func textAttributes(
        for style: ComputedStyle,
        resolver: (([String], Int, Bool, CGFloat) -> UIFont?)? = nil
    ) -> [NSAttributedString.Key: Any] {
        let font = resolvedFont(for: style, resolver: resolver)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: style.color ?? UIColor.black,
        ]
        if style.configLetterSpacing != 0 {
            attributes[.kern] = style.configLetterSpacing
        }
        attributes.merge(UserReaderFontResolver.syntheticBoldAttributes(
            for: font, isBoldRequested: style.configBold || style.fontWeight >= 600
        )) { _, new in new }
        return attributes
    }

    static func font(
        for style: ComputedStyle,
        resolver: (([String], Int, Bool, CGFloat) -> UIFont?)? = nil
    ) -> UIFont {
        resolvedFont(for: style, resolver: resolver)
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
