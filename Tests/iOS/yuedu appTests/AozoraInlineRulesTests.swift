import Foundation
import Testing
@testable import yuedu_app

@Suite("Aozora inline rules")
struct AozoraInlineRulesTests {
    // MARK: Ruby

    @Test("｜ fixes where the base starts")
    func explicitBase() {
        #expect(inlines("前の当時｜彼地《かのち》の") == [
            .text("前の当時"), ruby("彼地", "かのち"), .text("の"),
        ])
        #expect(inlines("｜Alice《アリス》と｜ひと《人》") == [
            ruby("Alice", "アリス"), .text("と"), ruby("ひと", "人"),
        ])
    }

    @Test("without ｜ the base is the run of one character class before 《", arguments: [
        ("稿を継《つ》", "継", "つ"),                       // kanji after hiragana
        ("これは日々《ひび》", "日々", "ひび"),                 // 々 counts as kanji
        ("その〆切《しめきり》", "〆切", "しめきり"),
        ("あのカタカナ《かたかな》", "カタカナ", "かたかな"),   // katakana after hiragana
        ("漢字ひらがな《ヒラガナ》", "ひらがな", "ヒラガナ"),
        ("第１２３《いちにさん》", "１２３", "いちにさん"),     // full-width digits after kanji
        ("見るCafe《カフェ》", "Cafe", "カフェ"),             // half-width letters
        ("あのMr.《ミスター》", "Mr.", "ミスター"),           // a half-width terminator ends the run
        ("の𠮷野《よしの》", "𠮷野", "よしの"),               // outside the BMP
    ])
    func implicitBase(text: String, base: String, reading: String) throws {
        let result = inlines(text)
        let last = try #require(result.last)
        #expect(last == ruby(base, reading))
        #expect(result.displayedText == text.replacingOccurrences(of: "《\(reading)》", with: ""))
    }

    @Test("every 《…》 is ruby in an Aozora document, kana or not")
    func noKanaGuard() {
        #expect(inlines("東京《Tokyo》") == [ruby("東京", "Tokyo")])
    }

    @Test("a ruby with nothing before it has an empty base")
    func emptyBase() {
        #expect(inlines("《よみ》") == [.ruby(base: [], reading: "よみ", side: .right)])
    }

    @Test("a ｜ that never meets a reading is shown as written")
    func unmatchedBar() {
        #expect(inlines("前｜後") == [.text("前｜後")])
        #expect(inlines("｜あ｜漢字《かんじ》") == [.text("｜あ"), ruby("漢字", "かんじ")])
    }

    @Test("a reading resolves its own gaiji")
    func readingWithGaiji() {
        #expect(inlines("漢《※［＃ローマ数字1、1-13-21］》") == [ruby("漢", "Ⅰ")])
    }

    // MARK: Gaiji

    @Test("a JIS X 0213 code resolves through the bundled table")
    func jisGaiji() {
        #expect(inlines("※［＃「てへん＋劣」、第3水準1-84-77］") == [
            .gaiji(AozoraGaiji(resolved: "\u{6318}", description: "てへん＋劣",
                               code: .jis(plane: 1, row: 84, cell: 77))),
        ])
    }

    @Test("a gaiji outside the BMP and a combining sequence")
    func wideGaiji() {
        #expect(inlines("※［＃「てへん＋劣」、第4水準2-1-1］").displayedText == "\u{20089}")
        #expect(inlines("※［＃半濁点付き平仮名か、1-4-87］").displayedText == "\u{304B}\u{309A}")
    }

    @Test("a U+ code resolves directly")
    func unicodeGaiji() {
        #expect(inlines("※［＃「口＋七」、U+20B9F、56-7］") == [
            .gaiji(AozoraGaiji(resolved: "\u{20B9F}", description: "口＋七", code: .unicode(0x20B9F))),
        ])
    }

    @Test("a gaiji described only by shape shows ※ and the description, page-line dropped")
    func descriptionOnlyGaiji() {
        let document = AozoraDocumentParser.parse("題\n\n前※［＃「口＋世」、ページ数-行数］後\n")
        #expect(lastInlines(document) == [
            .text("前"), .gaiji(AozoraGaiji(resolved: nil, description: "口＋世", code: nil)), .text("後"),
        ])
        #expect(document.body.last?.displayedText == "前※（口＋世）後")
        #expect(document.diagnostics[.unresolvedGaiji] == 1)
    }

    @Test("a gaiji counts as kanji for ruby")
    func gaijiTakesRuby() {
        #expect(inlines("僕ハ迚《とて》モ君ニ再会スル※［＃コト、1-2-24］《こと》ハ") == [
            .text("僕ハ"), ruby("迚", "とて"), .text("モ君ニ再会スル"),
            .ruby(base: [.gaiji(AozoraGaiji(resolved: "\u{30FF}", description: "コト",
                                            code: .jis(plane: 1, row: 2, cell: 24)))],
                  reading: "こと", side: .right),
            .text("ハ"),
        ])
    }

    @Test("the public-domain download: both gaiji become ヿ under their ruby")
    func publicDomainGaiji() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/TXTEncodings/aozora-neko-jijo.txt")
        let document = AozoraDocumentParser.parse(try TXTFileReader.readTextFile(url: fixture))
        let body = document.body.map(\.displayedText).joined(separator: "\n")
        #expect(body.contains("再会スルヿハ出来ヌ"))
        #expect(body.contains("書キタイヿハ多イガ"))
        for marker in ["《", "》", "［＃", "※", "｜"] {
            #expect(!body.contains(marker))
        }
        #expect(document.diagnostics[.unresolvedGaiji] == 0)
        #expect(document.diagnostics[.unmappedGaijiCode] == 0)
    }

    // MARK: Accents and くの字点

    @Test("an accent decomposition loses its brackets", arguments: [
        ("〔cafe'〕", "café"),
        ("〔AE&sop〕", "Æsop"),
        ("〔Henri De Re'gnier〕", "Henri De Régnier"),
        ("〔Go:ttliche〕", "Göttliche"),
        ("〔!@Que' tal?〕", "¡Qué tal?"),
    ])
    func accent(text: String, expected: String) {
        #expect(inlines(text) == [.text(expected)])
    }

    @Test("brackets without a decomposition stay as written")
    func plainBrackets() {
        #expect(inlines("〔注〕本文") == [.text("〔注〕本文")])
        #expect(inlines("〔l'Institut〕") == [.text("〔l'Institut〕")])
    }

    @Test("an unclosed accent bracket converts to its line end")
    func unclosedAccent() {
        #expect(inlines("〔Pardonnez a` mon") == [.text("Pardonnez à mon")])
        #expect(inlines("〔注の続き") == [.text("〔注の続き")])
    }

    @Test("ruby inside an accent bracket")
    func rubyInsideAccent() {
        #expect(inlines("〔｜Cafe'《カツフエ》〕") == [ruby("Café", "カツフエ")])
        #expect(inlines("〔Re'gnier《レニエ》〕") == [ruby("Régnier", "レニエ")])
    }

    @Test("くの字点 become their Unicode characters")
    func kunojiten() {
        #expect(inlines("かわる／＼").displayedText == "かわる\u{3033}\u{3035}")
        #expect(inlines("しげ／″＼と").displayedText == "しげ\u{3034}\u{3035}と")
        #expect(inlines("さま／゛＼の").displayedText == "さま\u{3034}\u{3035}の")
    }

    // MARK: Helpers

    private func ruby(_ base: String, _ reading: String) -> AozoraInline {
        .ruby(base: [.text(base)], reading: reading, side: .right)
    }

    /// The inline content of `line` read as the last body line of a document.
    private func inlines(_ line: String) -> [AozoraInline] {
        lastInlines(AozoraDocumentParser.parse("題\n\n" + line + "\n"))
    }

    private func lastInlines(_ document: AozoraDocument) -> [AozoraInline] {
        guard case .paragraph(let inlines, _)? = document.body.last else { return [] }
        return inlines
    }
}
