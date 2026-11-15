import CoreText
import Foundation
import Testing
import UIKit
@testable import yuedu_app

@Suite("Reader translation layout")
struct ReaderTranslationLayoutTests {

    private let source = "第一段。\n第二段。\n第三段。"
    private let translations = ["第一段。": "Para one.", "第三段。": "Para three."]

    private func splice(_ mode: ReaderTranslationPresentation.Mode, text: String? = nil,
                        translations: [String: String]? = nil) -> (display: NSAttributedString, layout: ReaderTranslationLayout)? {
        let table = translations ?? self.translations
        return ReaderTranslationLayout.splice(NSAttributedString(string: text ?? source), mode: mode) { table[$0] }
    }

    // MARK: - Splicing

    @Test("side by side puts each translation after its paragraph, the last one on a line of its own")
    func bilingualSplice() throws {
        let spliced = try #require(splice(.bilingual))
        #expect(spliced.display.string == "第一段。\nPara one.\n第二段。\n第三段。\nPara three.")
        #expect(spliced.layout.sourceText == source)
        let first = try #require(spliced.layout.blocks.first)
        #expect((spliced.display.string as NSString).substring(with: first.translation) == "Para one.")
        #expect(spliced.display.attribute(ReaderTranslationLayout.attribute, at: first.translation.location, effectiveRange: nil) as? Bool == true)
        #expect(spliced.display.attribute(ReaderTranslationLayout.attribute, at: 0, effectiveRange: nil) == nil)
    }

    @Test("translation only puts each translation in its paragraph's place")
    func translationOnlySplice() throws {
        let spliced = try #require(splice(.translationOnly))
        #expect(spliced.display.string == "Para one.\n第二段。\nPara three.")
    }

    @Test("a chapter without translations, or with translation off, keeps its document")
    func nothingToSplice() {
        #expect(splice(.bilingual, translations: [:]) == nil)
        #expect(splice(.off) == nil)
    }

    @Test("indentation and attachments are not part of the text a translation is stored under")
    func paragraphKeys() {
        let paragraphs = ReaderTranslationText.paragraphs(in: "\u{3000}\u{3000}他笑了。\n\u{FFFC}\n……\n")
        #expect(paragraphs.map(\.key) == ["他笑了。"])
        #expect(ReaderTranslationText.storageKey("他笑了。") == ReaderTranslationText.storageKey("他笑了。"))
        #expect(ReaderTranslationText.storageKey("他笑了。").count == 32)
    }

    // MARK: - Look

    private let body = UIFont.systemFont(ofSize: 18)

    private func translationAttributes(_ spliced: (display: NSAttributedString, layout: ReaderTranslationLayout),
                                       block: Int) -> [NSAttributedString.Key: Any] {
        spliced.display.attributes(at: spliced.layout.blocks[block].translation.location, effectiveRange: nil)
    }

    @Test("a heading drawn white on an inline box keeps its box; the text after it keeps its own look")
    func inlineBoxHeading() throws {
        // 诡秘之主: <p class="bt1"><span class="look">关于穿越后：</span></p>, white on orange.
        let box = HTMLAttributedStringBuilder.InlineBorderBoxStyle(
            borderColor: .orange, borderWidth: 1, cornerRadius: 3, fillColor: .orange,
            paddingHorizontal: 8, paddingVertical: 6)
        let chapter = NSMutableAttributedString(string: "关于穿越后：", attributes: [
            .font: UIFont.systemFont(ofSize: 11), .foregroundColor: UIColor.white,
            HTMLAttributedStringBuilder.cssSpecifiedForegroundColorAttribute: UIColor.white,
            HTMLAttributedStringBuilder.inlineBorderBoxAttribute: box,
        ])
        chapter.append(NSAttributedString(string: "\n原主多年专注读书。", attributes: [.font: body, .foregroundColor: UIColor.black]))
        let table = ["关于穿越后：": "After crossing over:", "原主多年专注读书。": "He had long buried himself in books."]
        for mode in [ReaderTranslationPresentation.Mode.bilingual, .translationOnly] {
            let spliced = try #require(ReaderTranslationLayout.splice(chapter, mode: mode) { table[$0] })
            let heading = translationAttributes(spliced, block: 0)
            #expect(heading[HTMLAttributedStringBuilder.inlineBorderBoxAttribute] as? HTMLAttributedStringBuilder.InlineBorderBoxStyle != nil)
            #expect(heading[.foregroundColor] as? UIColor == .white)
            #expect(heading[HTMLAttributedStringBuilder.cssSpecifiedForegroundColorAttribute] as? UIColor == .white)
            let text = translationAttributes(spliced, block: 1)
            #expect(text[HTMLAttributedStringBuilder.inlineBorderBoxAttribute] == nil)
            #expect(text[.foregroundColor] as? UIColor == .black)
        }
    }

    @Test("a translation takes the look of most of its paragraph, not a bold lead-in or a hidden quote mark")
    func mainTextLook() throws {
        let hidden: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 0.01), .foregroundColor: UIColor.clear]
        let chapter = NSMutableAttributedString(string: "周明瑞：", attributes: [.font: UIFont.boldSystemFont(ofSize: 18)])
        chapter.append(NSAttributedString(string: "眸子深棕，黑发较短。\n", attributes: [.font: body, .foregroundColor: UIColor.darkGray]))
        chapter.append(NSAttributedString(string: "“", attributes: hidden))
        chapter.append(NSAttributedString(string: "好。", attributes: [.font: body, .foregroundColor: UIColor.blue]))
        chapter.append(NSAttributedString(string: "”", attributes: hidden))
        let table = ["周明瑞：眸子深棕，黑发较短。": "Zhou Mingrui: dark brown eyes, short black hair.", "“好。”": "“Fine.”"]
        let spliced = try #require(ReaderTranslationLayout.splice(chapter, mode: .bilingual) { table[$0] })
        let described = translationAttributes(spliced, block: 0)
        #expect(described[.font] as? UIFont == body)
        #expect(described[.foregroundColor] as? UIColor == .darkGray)
        let spoken = translationAttributes(spliced, block: 1)
        #expect(spoken[.font] as? UIFont == body)
        #expect(spoken[.foregroundColor] as? UIColor == .blue)
    }

    @Test("a designed chapter title is left as drawn")
    func designedTitle() throws {
        // What ChapterTitleAttributedBuilder.compileDesignBlock emits: clear placeholder
        // characters the render plan is drawn over.
        let chapter = NSMutableAttributedString(string: "第一章 初入江湖\n", attributes: [
            .font: UIFont.systemFont(ofSize: 1), .foregroundColor: UIColor.clear,
            ChapterTitleAttributedBuilder.designRenderPlanAttribute: NSObject(),
        ])
        chapter.append(NSAttributedString(string: "他走进了城门。", attributes: [.font: body]))
        let table = ["第一章 初入江湖": "Chapter One", "他走进了城门。": "He walked through the gate."]
        for mode in [ReaderTranslationPresentation.Mode.bilingual, .translationOnly] {
            let spliced = try #require(ReaderTranslationLayout.splice(chapter, mode: mode) { table[$0] })
            #expect(spliced.layout.blocks.count == 1)
            #expect(spliced.display.string.hasPrefix("第一章 初入江湖\n"))
        }
    }

    @Test("a translation is drawn inside its paragraph's block and container boxes")
    func blockBoxes() throws {
        let chapter = NSAttributedString(string: "人物形象", attributes: [
            .font: body, .foregroundColor: UIColor.white,
            HTMLAttributedStringBuilder.blockBackgroundColorAttribute: UIColor.brown,
            HTMLAttributedStringBuilder.blockRenderIDAttribute: "heading",
            HTMLAttributedStringBuilder.containerBlockRenderIDAttribute: "container-aside",
        ])
        for mode in [ReaderTranslationPresentation.Mode.bilingual, .translationOnly] {
            let spliced = try #require(ReaderTranslationLayout.splice(chapter, mode: mode) { _ in "Appearance" })
            let translation = translationAttributes(spliced, block: 0)
            #expect(translation[HTMLAttributedStringBuilder.blockRenderIDAttribute] as? String == "heading")
            #expect(translation[HTMLAttributedStringBuilder.containerBlockRenderIDAttribute] as? String == "container-aside")
            #expect(translation[HTMLAttributedStringBuilder.blockBackgroundColorAttribute] as? UIColor == .brown)
            #expect(translation[.foregroundColor] as? UIColor == .white)
        }
    }

    @Test("a highlighted paragraph's translation takes the book's own colour, not the highlight's")
    func highlightedParagraph() throws {
        let chapter = NSMutableAttributedString(string: "“走吧，天快黑了。”他说。", attributes: [.font: body, .foregroundColor: UIColor.black])
        DialogueHighlighter.apply(textColor: .red, boxColor: .yellow, to: chapter)
        #expect(chapter.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? UIColor != .black)
        let spliced = try #require(ReaderTranslationLayout.splice(chapter, mode: .bilingual) { _ in "“Let's go,” he said." })
        let translation = translationAttributes(spliced, block: 0)
        #expect(translation[.foregroundColor] as? UIColor == .black)
        #expect(translation[RegexHighlightEngine.decorationAttributeKey] == nil)
    }

    @Test("a translation of a dialogue bubble is a bubble of its own, fitted to its own text")
    func dialogueBubble() throws {
        let chapter = NSMutableAttributedString(string: "“好。”\n他点点头。", attributes: [.font: body, .foregroundColor: UIColor.black])
        ReaderDialogueBubbleMarker.apply(style: ReaderDialogueBubbleStyle(isEnabled: true), columnWidth: 320,
                                         bodyFontSize: 18, to: chapter)
        let key = ReaderDialogueBubbleMarker.attributeKey
        let source = try #require(chapter.attribute(key, at: 1, effectiveRange: nil) as? ReaderDialogueBubbleMark)
        let spliced = try #require(ReaderTranslationLayout.splice(chapter, mode: .bilingual) { key in
            key.hasPrefix("“") ? "“All right, then — let's do it your way.”" : nil
        })
        let block = try #require(spliced.layout.blocks.first)
        let bubble = try #require(spliced.display.attribute(key, at: block.translation.location, effectiveRange: nil) as? ReaderDialogueBubbleMark)
        #expect(bubble !== source)
        #expect(bubble.side == source.side)

        func textWidth(at location: Int, in string: NSAttributedString) throws -> CGFloat {
            let style = try #require(string.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle)
            return source.metrics.columnWidth - style.headIndent + style.tailIndent
        }
        #expect(try textWidth(at: block.translation.location, in: spliced.display) > textWidth(at: 1, in: chapter))
    }

    // MARK: - Positions

    @Test("every display offset maps to a position that maps straight back", arguments: [
        ReaderTranslationPresentation.Mode.bilingual, .translationOnly,
    ])
    func positionsRoundTrip(mode: ReaderTranslationPresentation.Mode) throws {
        let layout = try #require(splice(mode)).layout
        for offset in 0..<layout.displayLength {
            let position = layout.sourcePosition(displayOffset: offset)
            #expect(layout.displayOffset(charOffset: position.charOffset, translationOffset: position.translationOffset) == offset)
        }
    }

    @Test("side by side keeps every character of the book where the book has it")
    func bookTextStaysInPlace() throws {
        let spliced = try #require(splice(.bilingual))
        let display = spliced.display.string as NSString
        let original = source as NSString
        for offset in 0..<original.length {
            let mapped = spliced.layout.displayOffset(charOffset: offset, translationOffset: nil)
            #expect(display.character(at: mapped) == original.character(at: offset))
            let back = spliced.layout.sourcePosition(displayOffset: mapped)
            #expect(back.charOffset == offset && back.translationOffset == nil)
        }
    }

    @Test("a position inside a translation falls back to its book text once the translation is gone")
    func translationPositionWithoutTranslation() throws {
        let layout = try #require(splice(.bilingual)).layout
        let inside = layout.sourcePosition(displayOffset: layout.blocks[0].translation.location + 3)
        #expect(inside.translationOffset == 3)
        // The anchor is the paragraph's line break, so the reader resumes at that paragraph.
        #expect(inside.charOffset == 4)
    }

    // MARK: - Annotations and selections

    @Test("an annotation across a translation is drawn in pieces; a hidden one is not drawn")
    func annotationsAroundTranslations() throws {
        let bilingual = try #require(splice(.bilingual))
        let range = NSRange(location: 2, length: 5)  // 段。\n第二
        let pieces = bilingual.layout.displayRanges(forSource: range)
        #expect(pieces.map { (bilingual.display.string as NSString).substring(with: $0) } == ["段。\n", "第二"])

        let only = try #require(splice(.translationOnly))
        #expect(only.layout.displayRanges(forSource: NSRange(location: 0, length: 3)).isEmpty)
        #expect(only.layout.displayRanges(forSource: NSRange(location: 5, length: 3)).map {
            (only.display.string as NSString).substring(with: $0)
        } == ["第二段"])
    }

    @Test("a selection in a translation names no book text; one in the book names its own")
    func selections() throws {
        let spliced = try #require(splice(.bilingual))
        let layout = spliced.layout
        #expect(layout.sourceRange(forDisplay: layout.blocks[0].translation) == nil)
        #expect(layout.isTranslation(NSRange(location: layout.blocks[0].translation.location - 1, length: 3)))
        let second = (spliced.display.string as NSString).range(of: "第二段")
        #expect(layout.sourceRange(forDisplay: second) == NSRange(location: 5, length: 3))
    }

    // MARK: - Page turning

    private func chapterLayout(_ display: NSAttributedString, translation: ReaderTranslationLayout?, pageStarts: [Int],
                               spine: Int = 0) -> CoreTextPaginator.ChapterLayout {
        let ranges = pageStarts.enumerated().map { index, start -> CFRange in
            let end = index + 1 < pageStarts.count ? pageStarts[index + 1] : display.length
            return CFRangeMake(start, end - start)
        }
        var layout = CoreTextPaginator.ChapterLayout(
            spineIndex: spine, attributedString: display, framesetter: CoreTextChapterFramesetter(CTFramesetterCreateWithAttributedString(display), text: display),
            pageRanges: ranges, inlineAttachments: [:], inlineAnnotations: [:], blockAttachments: [:], blockRenderables: [:],
            pageKinds: Array(repeating: .text, count: ranges.count), pageBackgroundImage: nil, authoredBackgroundColor: nil,
            darkAuthoredBackgroundColor: nil, anchorOffsets: [:], renderSize: CGSize(width: 320, height: 480), fontSize: 18,
            backgroundColor: .systemBackground, contentInsets: .zero)
        layout.translation = translation
        return layout
    }

    /// Turns pages forward from the chapter start and back from its end, collecting where each
    /// turn lands; a turn that stays on its own page would repeat forever, so both are capped.
    private func walk(_ layout: CoreTextPaginator.ChapterLayout) -> (forward: [Int], backward: [Int]) {
        let layouts = [layout.spineIndex: layout]
        var forward: [Int] = []
        var position: CoreTextReadingPosition? = .chapterStart(layout.spineIndex)
        while let current = position, current.spineIndex == layout.spineIndex, forward.count <= layout.pageRanges.count {
            forward.append(CoreTextReadingPositionMapper.localPageIndex(for: current, in: layout))
            position = CoreTextReadingPositionMapper.positionAfter(current, layouts: layouts, chapterCount: 1)
        }
        var backward: [Int] = []
        position = layout.readingPosition(atDisplay: Int(layout.pageRanges[layout.pageRanges.count - 1].location))
        while let current = position, backward.count <= layout.pageRanges.count {
            backward.append(CoreTextReadingPositionMapper.localPageIndex(for: current, in: layout))
            position = CoreTextReadingPositionMapper.positionBefore(current, layouts: layouts, chapterCount: 1)
        }
        return (forward, backward)
    }

    @Test("pages starting inside a translation are turned past, forwards and backwards", arguments: [
        ReaderTranslationPresentation.Mode.bilingual, .translationOnly,
    ])
    func pageTurningThroughTranslations(mode: ReaderTranslationPresentation.Mode) throws {
        let spliced = try #require(splice(mode))
        let starts = Array(stride(from: 0, to: spliced.display.length, by: 3))
        let layout = chapterLayout(spliced.display, translation: spliced.layout, pageStarts: starts)
        let pages = Array(0..<starts.count)
        let result = walk(layout)
        #expect(result.forward == pages)
        #expect(result.backward == pages.reversed())
    }

    @Test("a chapter the paginator lays out with translations turns through every page once")
    func paginatedChapter() async throws {
        let paragraphs = (1...24).map { "第\($0)段，張若塵抬頭望向遠方的山，雲霧繚繞，一時說不出話來，只覺得心中有千言萬語。" }
        let text = paragraphs.joined(separator: "\n")
        let font = UIFont.systemFont(ofSize: 18)
        let source = NSAttributedString(string: text, attributes: [.font: font])
        let spliced = try #require(ReaderTranslationLayout.splice(source, mode: .bilingual) { key in
            "Paragraph \(key.count): Zhang Ruochen looked up at the distant mountain wrapped in cloud, and for a while could not say a word."
        })
        var layout = await CoreTextPaginator().paginate(spineIndex: 0, attrStr: spliced.display,
                                                        renderSize: CGSize(width: 320, height: 480), fontSize: 18,
                                                        contentInsets: UIEdgeInsets(top: 20, left: 20, bottom: 20, right: 20))
        layout.translation = spliced.layout
        #expect(layout.pageRanges.count > 3)
        #expect(layout.pageRanges.contains { spliced.layout.isTranslation(NSRange(location: Int($0.location), length: 0)) })
        let pages = Array(0..<layout.pageRanges.count)
        let result = walk(layout)
        #expect(result.forward == pages)
        #expect(result.backward == pages.reversed())
    }
}
