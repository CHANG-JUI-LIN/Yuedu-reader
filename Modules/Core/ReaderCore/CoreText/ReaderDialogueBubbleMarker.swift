import CoreText
import UIKit

/// Lays quoted dialogue out as a chat bubble for 對話氣泡: this pass owns the
/// block geometry (which side, how wide, how far from the column edge) and
/// leaves the skin to `ReaderDialogueBubbleRenderer`, which paints it behind the
/// glyphs.
///
/// Speech buried in a narrated paragraph (`他說「好」，轉身走了`) is pulled out
/// into its own bubble, which means **inserting paragraph breaks into the built
/// string**. That is safe here because every index derived from a chapter is
/// derived *after* this pass: anchors are collected from the finished attributed
/// string, and attribute ranges (footnotes, attachments, highlights) move with
/// the text. The one visible cost is that a reading position stored while the
/// setting was off points a little earlier once it is on.
enum ReaderDialogueBubbleMarker {
    static let attributeKey = NSAttributedString.Key("YDDialogueBubble")

    /// Characters allowed to sit between two quoted spans and still leave them
    /// one bubble (`「甲」，「乙」`).
    private static let connectors = CharacterSet(charactersIn: "，。！？、；：…—－-·　 \t\u{3000}")
        .union(.whitespacesAndNewlines)

    static func apply(
        style: ReaderDialogueBubbleStyle,
        columnWidth: CGFloat,
        bodyFontSize: CGFloat,
        writingMode: ReaderWritingMode = .horizontal,
        to attr: NSMutableAttributedString
    ) {
        // Vertical writing has no chat-bubble geometry: "left" and "right"
        // become top and bottom and the tail points the wrong way. Marking there
        // would only indent the paragraph with nothing drawn behind it, so
        // vertical keeps the inline 對話 decoration instead.
        guard style.isEnabled,
              !writingMode.isVertical,
              columnWidth.isFinite, columnWidth > 0,
              bodyFontSize.isFinite, bodyFontSize > 0,
              attr.length > 0 else {
            return
        }

        let plan = plan(style: style, in: attr)
        guard !plan.isEmpty else { return }

        // Applied back to front so that an edit never invalidates the offsets of
        // the paragraphs still to be processed.
        for paragraph in plan.reversed() {
            apply(
                paragraph,
                style: style,
                columnWidth: columnWidth,
                bodyFontSize: bodyFontSize,
                to: attr
            )
        }
    }

    // MARK: - Planning

    private struct PlannedSegment {
        let range: NSRange
        let side: ReaderDialogueBubbleSide?
        var speaker: String?
        var index: Int = 0
    }

    private struct PlannedParagraph {
        let segments: [PlannedSegment]
        /// True when the paragraph is one bubble already — no break to insert.
        var isWholeParagraph: Bool {
            segments.count == 1 && segments[0].side != nil
        }
    }

    /// Walks the chapter once, forward, deciding what becomes a bubble and on
    /// which side.
    ///
    /// Sides alternate per *utterance*, which is only meaningful because speech
    /// is split out of its narration first: `「甲。」張三道。「乙。」李四道。`
    /// yields two bubbles with their attributions between them, so flipping
    /// sides tracks the two speakers. Nothing here identifies who is talking —
    /// 左右交替 can be switched off to keep every bubble on one side.
    private static func plan(
        style: ReaderDialogueBubbleStyle,
        in attr: NSAttributedString
    ) -> [PlannedParagraph] {
        let ns = attr.string as NSString
        let dialogueRanges = DialogueHighlighter.dialogueRanges(in: ns)
        guard !dialogueRanges.isEmpty else { return [] }

        var result: [PlannedParagraph] = []
        var side = style.startSide
        var bubbleIndex = 0
        // One speaker, one side, for the whole chapter — the reason a name is
        // read out of the narration at all.
        var sidesBySpeaker: [String: ReaderDialogueBubbleSide] = [:]
        ns.enumerateSubstrings(
            in: NSRange(location: 0, length: ns.length),
            options: [.byParagraphs]
        ) { _, paragraphRange, _, _ in
            guard paragraphRange.length > 0 else { return }
            guard !carriesBlockContent(attr, in: paragraphRange) else { return }

            let segments = segments(
                of: paragraphRange,
                dialogueRanges: dialogueRanges,
                in: ns,
                mergesAdjacent: style.mergesAdjacent
            )
            guard segments.contains(where: { $0.isDialogue }) else { return }

            var planned: [PlannedSegment] = []
            for (offset, segment) in segments.enumerated() {
                guard segment.isDialogue else {
                    planned.append(PlannedSegment(range: segment.range, side: nil))
                    continue
                }
                let sharedBeat = isSharedBeat(before: offset, in: segments, ns: ns)
                let speaker = style.showsSpeakerName || style.sidesFollowSpeaker
                    ? ReaderDialogueSpeakerDetector.speaker(
                        before: narration(
                            before: offset,
                            in: segments,
                            ns: ns,
                            includingSharedBeat: sharedBeat
                        ),
                        after: narration(after: offset, in: segments, ns: ns),
                        beforeIsSharedBeat: sharedBeat,
                        afterIsSharedBeat: isSharedBeat(
                            before: offset + 2,
                            in: segments,
                            ns: ns
                        )
                    )
                    : nil

                let resolvedSide: ReaderDialogueBubbleSide
                if style.sidesFollowSpeaker, let speaker {
                    if let known = sidesBySpeaker[speaker] {
                        resolvedSide = known
                    } else {
                        resolvedSide = side
                        sidesBySpeaker[speaker] = side
                        if style.alternatesSides { side = side.opposite }
                    }
                } else {
                    resolvedSide = side
                    if style.alternatesSides { side = side.opposite }
                }

                planned.append(
                    PlannedSegment(
                        range: segment.range,
                        side: resolvedSide,
                        speaker: speaker,
                        index: bubbleIndex
                    )
                )
                bubbleIndex += 1
            }
            result.append(PlannedParagraph(segments: planned))
        }
        return result
    }

    private struct Segment {
        let range: NSRange
        let isDialogue: Bool
    }

    /// Splits one paragraph into alternating narration / speech runs.
    ///
    /// Narration that is only whitespace is dropped rather than becoming an
    /// empty paragraph, and two quotes separated by nothing but punctuation
    /// merge into a single bubble when 合併同段相鄰對話 is on.
    private static func segments(
        of paragraphRange: NSRange,
        dialogueRanges: [NSRange],
        in ns: NSString,
        mergesAdjacent: Bool
    ) -> [Segment] {
        let spans = dialogueRanges
            .filter {
                $0.location >= paragraphRange.location
                    && NSMaxRange($0) <= NSMaxRange(paragraphRange)
            }
            .sorted { $0.location < $1.location }
        guard !spans.isEmpty else { return [] }

        var merged: [NSRange] = []
        for span in spans {
            if mergesAdjacent, let last = merged.last {
                let gap = NSRange(
                    location: NSMaxRange(last),
                    length: span.location - NSMaxRange(last)
                )
                if gap.length >= 0, isConnective(ns.substring(with: gap)) {
                    merged[merged.count - 1] = NSUnionRange(last, span)
                    continue
                }
            }
            merged.append(span)
        }

        var result: [Segment] = []
        var cursor = paragraphRange.location
        for span in merged {
            if span.location > cursor {
                let narration = NSRange(
                    location: cursor,
                    length: span.location - cursor
                )
                if !isBlank(narration, in: ns) {
                    result.append(Segment(range: narration, isDialogue: false))
                }
            }
            result.append(Segment(range: span, isDialogue: true))
            cursor = NSMaxRange(span)
        }
        if cursor < NSMaxRange(paragraphRange) {
            let tail = NSRange(
                location: cursor,
                length: NSMaxRange(paragraphRange) - cursor
            )
            if !isBlank(tail, in: ns) {
                result.append(Segment(range: tail, isDialogue: false))
            }
        }
        return result
    }

    /// The narration run immediately before / after a dialogue segment, which is
    /// where Chinese fiction puts the attribution.
    /// True when the narration before this segment sits between two quotes of
    /// the same paragraph *and* does not end a sentence — one speech interrupted
    /// by its own attribution (`「甲，」齊源老道面露無奈，「乙。」`). Both halves
    /// belong to that speaker.
    ///
    /// The trailing punctuation is what separates that from two people taking
    /// turns (`「甲。」張三道。「乙。」李四道。`), where the beat closes with a full
    /// stop and belongs only to the quote before it.
    private static func isSharedBeat(
        before offset: Int,
        in segments: [Segment],
        ns: NSString
    ) -> Bool {
        // Called for the segment *after* the beat as well, so the index can run
        // past the end — both bounds have to be checked, not just the lower one.
        guard offset >= 2, offset - 1 < segments.count,
              !segments[offset - 1].isDialogue,
              segments[offset - 2].isDialogue else {
            return false
        }
        let beat = ns.substring(with: segments[offset - 1].range)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = beat.last else { return false }
        return continuations.contains(last)
    }

    /// Punctuation that leaves a sentence open.
    private static let continuations: Set<Character> = ["，", ",", "、", "；", ";", "：", ":"]

    private static func narration(
        before offset: Int,
        in segments: [Segment],
        ns: NSString,
        includingSharedBeat: Bool
    ) -> String {
        guard offset > 0, !segments[offset - 1].isDialogue else { return "" }
        // A beat between two quotes attributes both of them, but only as a beat:
        // read as a plain lead-in it would hand the previous speaker's *verb* to
        // this line (`「甲。」張三道。「乙。」李四道。` must not make 張三 say 乙).
        if offset >= 2, segments[offset - 2].isDialogue, !includingSharedBeat {
            return ""
        }
        return ns.substring(with: segments[offset - 1].range)
    }

    private static func narration(
        after offset: Int,
        in segments: [Segment],
        ns: NSString
    ) -> String {
        let next = offset + 1
        guard next < segments.count, !segments[next].isDialogue else { return "" }
        return ns.substring(with: segments[next].range)
    }

    private static func isBlank(_ range: NSRange, in ns: NSString) -> Bool {
        ns.substring(with: range)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    private static func isConnective(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy(connectors.contains)
    }

    /// Paragraphs that already carry a drawn block — an image attachment, an HR,
    /// the structured chapter title — are never bubbles: their line box is a
    /// placeholder whose glyph extent means nothing.
    private static func carriesBlockContent(
        _ attr: NSAttributedString,
        in range: NSRange
    ) -> Bool {
        var found = false
        for key in [
            NSAttributedString.Key.attachment,
            ChapterTitleAttributedBuilder.designRenderPlanAttribute,
        ] {
            attr.enumerateAttribute(key, in: range, options: []) { value, _, stop in
                if value != nil {
                    found = true
                    stop.pointee = true
                }
            }
            if found { return true }
        }
        return false
    }

    // MARK: - Applying

    private static func apply(
        _ paragraph: PlannedParagraph,
        style: ReaderDialogueBubbleStyle,
        columnWidth: CGFloat,
        bodyFontSize: CGFloat,
        to attr: NSMutableAttributedString
    ) {
        // Break the paragraph apart from the back: inserting before segment *k*
        // leaves segments 0…k-1 exactly where they were.
        if !paragraph.isWholeParagraph {
            for index in stride(from: paragraph.segments.count - 1, through: 1, by: -1) {
                insertBreak(at: paragraph.segments[index].range.location, in: attr)
            }
        }

        for (index, segment) in paragraph.segments.enumerated() {
            guard let side = segment.side else {
                // Narration that continues after a bubble starts with the
                // punctuation that closed the quote (`「好」，然後…`). Left alone
                // it opens a line with a comma, so it is collapsed the same way
                // the quote marks are — hidden, never deleted.
                if index > 0, paragraph.segments[index - 1].side != nil {
                    let shift = paragraph.isWholeParagraph ? 0 : index
                    hideLeadingConnectives(
                        of: NSRange(
                            location: segment.range.location + shift,
                            length: segment.range.length
                        ),
                        in: attr
                    )
                }
                continue
            }
            // Each preceding segment contributed exactly one inserted break.
            let shift = paragraph.isWholeParagraph ? 0 : index
            let range = NSRange(
                location: segment.range.location + shift,
                length: segment.range.length
            )
            guard NSMaxRange(range) <= attr.length else { continue }
            let text = (attr.string as NSString).substring(with: range)
            // Palette and sticker are per utterance, derived from the line's own
            // text so the same line always looks the same.
            let variant = ReaderDialogueBubbleVariantResolver.variant(
                style.side(side).variants,
                text: text,
                index: segment.index
            )
            var resolved = style.side(side)
            if let variant {
                resolved.fillHex = variant.fillHex
                resolved.borderHex = variant.borderHex ?? resolved.borderHex
                resolved.textHex = variant.textHex ?? resolved.textHex
            }
            let decoration = ReaderDialogueBubbleVariantResolver.decoration(
                resolved.decoration,
                kindOverride: variant?.decorationKind,
                text: text,
                index: segment.index
            )
            mark(
                range,
                side: side,
                sideStyle: resolved,
                style: style,
                metrics: ReaderDialogueBubbleMetrics(
                    sideStyle: resolved,
                    style: style,
                    side: side,
                    columnWidth: columnWidth,
                    bodyFontSize: bodyFontSize,
                    speakerName: style.showsSpeakerName
                        ? (segment.speaker ?? resolved.name)
                        : nil,
                    decoration: decoration
                ),
                in: attr
            )
        }
    }

    /// The break carries the attributes of the character it follows, so the
    /// narration it ends keeps its own typography instead of inheriting the
    /// bubble's.
    private static func insertBreak(at location: Int, in attr: NSMutableAttributedString) {
        guard location > 0, location <= attr.length else { return }
        let attributes = attr.attributes(at: location - 1, effectiveRange: nil)
        attr.insert(
            NSAttributedString(string: "\n", attributes: attributes),
            at: location
        )
    }

    private static func mark(
        _ range: NSRange,
        side: ReaderDialogueBubbleSide,
        sideStyle: ReaderDialogueBubbleSideStyle,
        style: ReaderDialogueBubbleStyle,
        metrics: ReaderDialogueBubbleMetrics,
        in attr: NSMutableAttributedString
    ) {
        attr.addAttribute(
            attributeKey,
            value: ReaderDialogueBubbleMark(side: side, style: sideStyle, metrics: metrics),
            range: range
        )

        if let textHex = sideStyle.textHex {
            attr.addAttribute(
                .foregroundColor,
                value: GlobalSettings.uiColor(rgbHex: textHex),
                range: range
            )
        }
        applyTypography(sideStyle, metrics: metrics, to: attr, in: range)
        applyParagraphStyle(
            side: side,
            sideStyle: sideStyle,
            metrics: metrics,
            textWidth: measuredWidth(of: range, in: attr, metrics: metrics),
            to: attr,
            in: range
        )

        if style.removesQuotes {
            hideEnclosingQuotes(of: range, in: attr)
        }
    }

    /// Bubble typography, resolved against the reading font size so the bubble
    /// still tracks 字級.
    private static func applyTypography(
        _ sideStyle: ReaderDialogueBubbleSideStyle,
        metrics: ReaderDialogueBubbleMetrics,
        to attr: NSMutableAttributedString,
        in range: NSRange
    ) {
        let size = metrics.bodyFontSize * CGFloat(sideStyle.fontSizeMultiplier)
        let isBold = (sideStyle.fontWeight ?? 400) >= 600
        let hasFontOverride = sideStyle.fontPostScriptName != nil
            || sideStyle.fontSizeMultiplier != 1
            || sideStyle.fontWeight != nil
        if hasFontOverride {
            let font = sideStyle.fontPostScriptName
                .flatMap { UIFont(name: $0, size: size) }
                ?? UserReaderFontResolver.bodyFont(size: size, isBold: isBold)
            attr.addAttribute(.font, value: font, range: range)
            attr.addAttributes(
                UserReaderFontResolver.syntheticBoldAttributes(
                    for: font,
                    isBoldRequested: isBold
                ),
                range: range
            )
        }
        if sideStyle.letterSpacingEm != 0 {
            attr.addAttribute(
                .kern,
                value: (size * CGFloat(sideStyle.letterSpacingEm)) as NSNumber,
                range: range
            )
        }
    }

    /// How wide this bubble's text actually is, so the box can hug it.
    ///
    /// Measured against a neutral paragraph style: the indents about to be
    /// computed from this number must not feed back into it. Without the
    /// measurement the paragraph would always occupy the full allowance, and a
    /// multi-line bubble could only hug its text by right-aligning every line.
    private static func measuredWidth(
        of range: NSRange,
        in attr: NSAttributedString,
        metrics: ReaderDialogueBubbleMetrics
    ) -> CGFloat {
        let allowance = max(1, metrics.maxWidth - 2 * metrics.horizontalPadding)
        guard range.length > 0, NSMaxRange(range) <= attr.length else { return allowance }
        let substring = NSMutableAttributedString(
            attributedString: attr.attributedSubstring(from: range)
        )
        let paragraph = NSMutableParagraphStyle()
        if let existing = substring.attribute(
            .paragraphStyle,
            at: 0,
            effectiveRange: nil
        ) as? NSParagraphStyle {
            paragraph.minimumLineHeight = existing.minimumLineHeight
            paragraph.maximumLineHeight = existing.maximumLineHeight
            paragraph.lineHeightMultiple = existing.lineHeightMultiple
            paragraph.lineSpacing = existing.lineSpacing
        }
        substring.addAttribute(
            .paragraphStyle,
            value: paragraph,
            range: NSRange(location: 0, length: substring.length)
        )
        let framesetter = CTFramesetterCreateWithAttributedString(substring)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: substring.length),
            nil,
            CGSize(width: allowance, height: .greatestFiniteMagnitude),
            nil
        )
        guard size.width.isFinite, size.width > 1 else { return allowance }
        // One point of slack: a width rounded down re-wraps the very line it
        // was measured from.
        return min(ceil(size.width) + 1, allowance)
    }

    private static func applyParagraphStyle(
        side: ReaderDialogueBubbleSide,
        sideStyle: ReaderDialogueBubbleSideStyle,
        metrics: ReaderDialogueBubbleMetrics,
        textWidth: CGFloat,
        to attr: NSMutableAttributedString,
        in range: NSRange
    ) {
        attr.enumerateAttribute(.paragraphStyle, in: range, options: []) { value, subrange, _ in
            let paragraph = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
                ?? NSMutableParagraphStyle()
            paragraph.alignment = (sideStyle.textAlignment ?? (side == .left ? .left : .right))
                .nsTextAlignment
            // Indents position the *text*; the skin is drawn around it. The near
            // edge therefore has to reserve the bubble's own padding — plus the
            // tail's overhang and the avatar — or the drawn bubble runs off the
            // column.
            let near = metrics.nearTextInset
            let text = max(1, min(textWidth, metrics.maxWidth - 2 * metrics.horizontalPadding))
            let far = max(0, metrics.columnWidth - near - text)
            if side == .left {
                paragraph.firstLineHeadIndent = near
                paragraph.headIndent = near
                paragraph.tailIndent = -far
            } else {
                paragraph.firstLineHeadIndent = far
                paragraph.headIndent = far
                paragraph.tailIndent = -near
            }
            // The skin is drawn outside the glyph box, so the padding has to be
            // reserved as paragraph spacing or the next paragraph sits on it.
            let gap = metrics.spacing + metrics.verticalPadding + metrics.nameHeight
            paragraph.paragraphSpacingBefore = max(paragraph.paragraphSpacingBefore, gap)
            paragraph.paragraphSpacing = max(paragraph.paragraphSpacing, gap)
            attr.addAttribute(.paragraphStyle, value: paragraph, range: subrange)
        }
    }

    private static func hideLeadingConnectives(
        of range: NSRange,
        in attr: NSMutableAttributedString
    ) {
        guard NSMaxRange(range) <= attr.length else { return }
        let ns = attr.string as NSString
        for index in range.location..<NSMaxRange(range) {
            let scalar = Unicode.Scalar(ns.character(at: index))
            guard let scalar, connectors.contains(scalar), scalar != "\n" else { return }
            collapse(NSRange(location: index, length: 1), in: attr)
        }
    }

    private static func collapse(_ range: NSRange, in attr: NSMutableAttributedString) {
        attr.addAttribute(.font, value: UIFont.systemFont(ofSize: 0.01), range: range)
        attr.addAttribute(.foregroundColor, value: UIColor.clear, range: range)
        attr.addAttribute(.kern, value: 0 as NSNumber, range: range)
    }

    /// Collapses the quote marks instead of deleting them.
    ///
    /// The bubble already says "this is speech", so the marks are noise inside
    /// it. Shrinking them to a hairline keeps the string — and therefore
    /// selection, copy, search and TTS — reading exactly as the author wrote it.
    private static func hideEnclosingQuotes(
        of range: NSRange,
        in attr: NSMutableAttributedString
    ) {
        let ns = attr.string as NSString
        for index in range.location..<NSMaxRange(range) {
            guard DialogueHighlighter.isQuoteMark(ns.character(at: index)) else { continue }
            collapse(NSRange(location: index, length: 1), in: attr)
        }
    }
}

/// One bubble's identity on the string. A reference type so equal-valued runs
/// still merge by identity and the painter can group a paragraph's lines by the
/// object it carries.
final class ReaderDialogueBubbleMark: NSObject {
    let side: ReaderDialogueBubbleSide
    let style: ReaderDialogueBubbleSideStyle
    let metrics: ReaderDialogueBubbleMetrics

    init(
        side: ReaderDialogueBubbleSide,
        style: ReaderDialogueBubbleSideStyle,
        metrics: ReaderDialogueBubbleMetrics
    ) {
        self.side = side
        self.style = style
        self.metrics = metrics
    }
}

/// A bubble's ratios resolved into points for one column width and body size.
struct ReaderDialogueBubbleMetrics: Equatable, Sendable {
    let columnWidth: CGFloat
    let bodyFontSize: CGFloat
    let maxWidth: CGFloat
    let sideInset: CGFloat
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let spacing: CGFloat
    let cornerRadius: CGFloat
    let borderWidth: CGFloat
    let tail: Tail?
    let avatar: Avatar?
    /// Speaker label above the bubble, already resolved to points.
    let name: String?
    let nameFontSize: CGFloat
    let decoration: Decoration?

    struct Decoration: Equatable, Sendable {
        let kind: ReaderDialogueBubbleDecorationKind
        let anchor: ReaderDialogueBubbleAnchor
        let size: CGFloat
        let offsetX: CGFloat
        let offsetY: CGFloat
        let jitter: CGFloat
        let rotationDegrees: CGFloat
        let colorHex: UInt32
        let opacity: CGFloat
        let isOutside: Bool
    }

    /// Vertical room the label needs above the bubble, zero when there is none.
    var nameHeight: CGFloat { name == nil ? 0 : nameFontSize * 1.35 }

    struct Tail: Equatable, Sendable {
        let width: CGFloat
        let height: CGFloat
        let outside: CGFloat
        let bottomOffset: CGFloat
    }

    struct Avatar: Equatable, Sendable {
        let assetID: UUID
        let size: CGFloat
        let gap: CGFloat
        let offsetX: CGFloat
        let offsetY: CGFloat
        let cornerRadius: CGFloat
        let backgroundHex: UInt32?
        let borderHex: UInt32?
        let borderWidth: CGFloat
    }

    /// Distance from the bubble's own side of the column to the first glyph:
    /// the gap, the avatar, whatever the tail hangs outside, and the padding.
    var nearTextInset: CGFloat {
        // The avatar sits beside the bubble, the tail hangs off it; the sticker
        // may overhang too. Whatever needs room outside the box is reserved
        // here, because the paragraph indents are the only thing that can.
        let avatarInset = avatar.map { $0.size + $0.gap + max(0, $0.offsetX) } ?? 0
        let decorationInset = decoration.map { $0.isOutside ? $0.size * 0.62 : 0 } ?? 0
        return sideInset + avatarInset
            + max(max(0, tail?.outside ?? 0), decorationInset)
            + horizontalPadding
    }

    /// Where the bubble's own near edge sits, measured from the column edge.
    var bubbleNearInset: CGFloat {
        nearTextInset - horizontalPadding
    }

    init(
        sideStyle: ReaderDialogueBubbleSideStyle,
        style: ReaderDialogueBubbleStyle,
        side: ReaderDialogueBubbleSide,
        columnWidth: CGFloat,
        bodyFontSize: CGFloat,
        speakerName: String? = nil,
        decoration resolvedDecoration: ReaderDialogueBubbleVariantResolver.ResolvedDecoration? = nil
    ) {
        let em = bodyFontSize
        self.columnWidth = columnWidth
        self.bodyFontSize = em
        sideInset = columnWidth * CGFloat(style.sideInsetRatio)
        maxWidth = columnWidth * CGFloat(style.maxWidthRatio)
        horizontalPadding = em * CGFloat(style.horizontalPaddingEm)
        verticalPadding = em * CGFloat(style.verticalPaddingEm)
        spacing = em * CGFloat(style.spacingEm)
        cornerRadius = em * CGFloat(sideStyle.cornerRadiusEm)
        borderWidth = em * CGFloat(sideStyle.borderWidthEm)
        tail = sideStyle.tail.map {
            Tail(
                width: em * CGFloat($0.widthEm),
                height: em * CGFloat($0.heightEm),
                outside: em * CGFloat($0.outsideEm),
                bottomOffset: em * CGFloat($0.bottomOffsetEm)
            )
        }
        name = speakerName
        nameFontSize = em * 0.75
        decoration = resolvedDecoration.map {
            Decoration(
                kind: $0.kind,
                anchor: $0.anchor,
                size: em * CGFloat($0.sizeEm),
                offsetX: em * CGFloat($0.offsetXEm),
                offsetY: em * CGFloat($0.offsetYEm),
                jitter: em * CGFloat($0.jitterEm),
                rotationDegrees: CGFloat($0.rotationDegrees),
                colorHex: $0.colorHex,
                opacity: CGFloat($0.opacity),
                isOutside: $0.isOutside
            )
        }
        avatar = sideStyle.avatar.map {
            Avatar(
                assetID: $0.assetID,
                size: em * CGFloat($0.sizeEm),
                gap: em * CGFloat($0.gapEm),
                offsetX: em * CGFloat($0.offsetXEm),
                offsetY: em * CGFloat($0.offsetYEm),
                cornerRadius: em * CGFloat($0.sizeEm) * CGFloat($0.cornerRadiusRatio),
                backgroundHex: $0.backgroundHex,
                borderHex: $0.borderHex,
                borderWidth: em * CGFloat($0.borderWidthEm)
            )
        }
    }
}
