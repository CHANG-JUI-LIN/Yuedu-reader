import Foundation
import Testing
import UIKit
@testable import yuedu_app

@Suite("Dialogue bubble marker")
struct ReaderDialogueBubbleMarkerTests {
    private static let columnWidth: CGFloat = 340
    private static let fontSize: CGFloat = 18

    @Test("marks whole-paragraph speech and leaves narration alone")
    func marksWholeParagraphSpeech() {
        let attr = make([
            "他推開門走了進來。",
            "「你今天怎麼這麼早？」",
            "屋裡沒有人回答。",
        ])

        apply(style(), to: attr)

        #expect(mark(in: attr, paragraph: 0) == nil)
        #expect(mark(in: attr, paragraph: 1) != nil)
        #expect(mark(in: attr, paragraph: 2) == nil)
    }

    /// Speech inside narration is pulled into its own bubble, which means
    /// breaking the paragraph apart — the reason this pass may only run where
    /// every derived index is computed afterwards.
    @Test("splits speech out of the narration around it")
    func splitsEmbeddedSpeech() throws {
        let attr = make(["他說「好」，然後轉身走了。"])

        apply(style(), to: attr)

        #expect(attr.string == "他說\n「好」\n，然後轉身走了。")
        #expect(mark(in: attr, paragraph: 0) == nil)
        #expect(mark(in: attr, paragraph: 1)?.side == .right)
        #expect(mark(in: attr, paragraph: 2) == nil)
    }

    /// Two speakers in one paragraph are two bubbles, alternating, with the
    /// attribution between them left as narration.
    @Test("alternates two utterances inside one paragraph")
    func alternatesWithinAParagraph() {
        let attr = make(["「甲。」張三道。「乙。」李四道。"])

        apply(style(), to: attr)

        #expect(mark(in: attr, paragraph: 0)?.side == .right)
        #expect(mark(in: attr, paragraph: 1) == nil)
        #expect(mark(in: attr, paragraph: 2)?.side == .left)
        #expect(mark(in: attr, paragraph: 3) == nil)
    }

    /// Narration between two quotes does not restart the alternation: with the
    /// attribution split onto its own line, consecutive bubbles are still
    /// consecutive utterances.
    @Test("keeps alternating across narration paragraphs")
    func keepsAlternatingAcrossNarration() {
        let attr = make(["「甲。」", "張三沉默了很久。", "「乙。」"])

        apply(style(), to: attr)

        #expect(mark(in: attr, paragraph: 0)?.side == .right)
        #expect(mark(in: attr, paragraph: 1) == nil)
        #expect(mark(in: attr, paragraph: 2)?.side == .left)
    }

    /// Inserted breaks must not disturb the paragraphs before them.
    @Test("splits every paragraph without shifting the earlier ones")
    func splitsMultipleParagraphs() {
        let attr = make([
            "他說「好」。",
            "她說「不好」。",
        ])

        apply(style(), to: attr)

        #expect(attr.string == "他說\n「好」\n。\n她說\n「不好」\n。")
    }

    @Test("alternates sides from the configured starting side")
    func alternatesSides() {
        let attr = make([
            "「第一句。」",
            "「第二句。」",
            "他沉默了一會。",
            "「第三句。」",
        ])

        apply(style(), to: attr)

        #expect(mark(in: attr, paragraph: 0)?.side == .right)
        #expect(mark(in: attr, paragraph: 1)?.side == .left)
        #expect(mark(in: attr, paragraph: 2) == nil)
        #expect(mark(in: attr, paragraph: 3)?.side == .right)
    }

    @Test("keeps every bubble on one side when alternating is off")
    func honorsFixedSide() {
        let attr = make(["「第一句。」", "「第二句。」"])
        var fixed = style()
        fixed.alternatesSides = false
        fixed.startSide = .left

        apply(fixed, to: attr)

        #expect(mark(in: attr, paragraph: 0)?.side == .left)
        #expect(mark(in: attr, paragraph: 1)?.side == .left)
    }

    /// Merging decides whether `「甲。」，「乙。」` is one utterance or two: on, it
    /// stays a single bubble; off, it becomes two bubbles on opposite sides.
    @Test("merges two quotes separated by punctuation only when asked")
    func honorsMergeSetting() {
        let text = ["「甲。」，「乙。」"]

        let merging = make(text)
        apply(style(), to: merging)
        #expect(merging.string == text[0])
        #expect(mark(in: merging, paragraph: 0) != nil)
        #expect(mark(in: merging, paragraph: 1) == nil)

        let strict = make(text)
        var noMerge = style()
        noMerge.mergesAdjacent = false
        apply(noMerge, to: strict)
        #expect(strict.string == "「甲。」\n，\n「乙。」")
        #expect(mark(in: strict, paragraph: 0)?.side == .right)
        #expect(mark(in: strict, paragraph: 2)?.side == .left)
    }

    @Test("reserves the bubble's padding and tail in the paragraph indents")
    func reservesPaddingInIndents() throws {
        let attr = make(["「你今天怎麼這麼早？」"])
        let configured = style()

        apply(configured, to: attr)

        let bubble = try #require(mark(in: attr, paragraph: 0))
        let paragraph = try #require(
            attr.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        )
        let near = bubble.metrics.nearTextInset
        let allowance = bubble.metrics.maxWidth - 2 * bubble.metrics.horizontalPadding
        // What the indents leave for the text is the measured width of the line.
        let textWidth = Self.columnWidth - paragraph.headIndent - near

        #expect(paragraph.alignment == .right)
        #expect(abs(paragraph.tailIndent + near) < 0.001)
        // The box hugs: one short line must not reserve the whole allowance.
        #expect(textWidth > 0)
        #expect(textWidth < allowance)
        // The near inset has to clear the tail's overhang, not just the margin.
        #expect(near >= bubble.metrics.horizontalPadding)
    }

    /// The quote marks are collapsed, never deleted: reading positions, TTS
    /// anchors and annotations are all stored as offsets into this string.
    @Test("collapses quote marks without changing the string")
    func collapsesQuotesWithoutEditingText() throws {
        let source = "「你今天怎麼這麼早？」"
        let attr = make([source])

        apply(style(), to: attr)

        #expect(attr.string == source)  // whole-paragraph speech inserts nothing
        let openingFont = try #require(
            attr.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        )
        let bodyFont = try #require(
            attr.attribute(.font, at: 1, effectiveRange: nil) as? UIFont
        )
        #expect(openingFont.pointSize < 1)
        #expect(bodyFont.pointSize == Self.fontSize)
    }

    @Test("does nothing when the style is off")
    func respectsDisabledStyle() {
        let attr = make(["「你今天怎麼這麼早？」"])
        var disabled = style()
        disabled.isEnabled = false

        apply(disabled, to: attr)

        #expect(mark(in: attr, paragraph: 0) == nil)
    }

    /// `「甲，」齊源老道面露無奈，「乙。」` is one person speaking twice with his own
    /// attribution in between — both halves must land on the same side, or the
    /// avatar switches character mid-sentence.
    @Test("keeps a split quotation on one side")
    func keepsSplitQuotationTogether() {
        let attr = make([
            "「師兄好厲害！」",
            "「若說遁法，你師兄確實厲害，」齊源老道面露無奈，「若是他肯多花心思就好了。」",
        ])

        apply(style(), to: attr)

        var sides: [ReaderDialogueBubbleSide] = []
        var names: [String?] = []
        attr.enumerateAttribute(
            ReaderDialogueBubbleMarker.attributeKey,
            in: NSRange(location: 0, length: attr.length),
            options: []
        ) { value, _, _ in
            guard let mark = value as? ReaderDialogueBubbleMark else { return }
            sides.append(mark.side)
            names.append(mark.metrics.name)
        }

        #expect(sides.count == 3)
        #expect(sides[1] == sides[2])
        #expect(sides[0] != sides[1])
        // 老道 is part of the name, not the speech verb `道`.
        #expect(names[1] == "齊源老道")
        #expect(names[2] == "齊源老道")
    }

    // MARK: - Helpers

    private func style() -> ReaderDialogueBubbleStyle {
        ReaderDialogueBubbleStyle(isEnabled: true)
    }

    private func apply(
        _ style: ReaderDialogueBubbleStyle,
        to attr: NSMutableAttributedString
    ) {
        ReaderDialogueBubbleMarker.apply(
            style: style,
            columnWidth: Self.columnWidth,
            bodyFontSize: Self.fontSize,
            to: attr
        )
    }

    private func make(_ paragraphs: [String]) -> NSMutableAttributedString {
        NSMutableAttributedString(
            string: paragraphs.joined(separator: "\n"),
            attributes: [
                .font: UIFont.systemFont(ofSize: Self.fontSize),
                .paragraphStyle: NSParagraphStyle.default,
            ]
        )
    }

    private func mark(
        in attr: NSAttributedString,
        paragraph index: Int
    ) -> ReaderDialogueBubbleMark? {
        let paragraphs = attr.string.components(separatedBy: "\n")
        guard paragraphs.indices.contains(index) else { return nil }
        var location = 0
        for offset in 0..<index {
            location += (paragraphs[offset] as NSString).length + 1
        }
        guard location < attr.length else { return nil }
        return attr.attribute(
            ReaderDialogueBubbleMarker.attributeKey,
            at: location,
            effectiveRange: nil
        ) as? ReaderDialogueBubbleMark
    }
}
