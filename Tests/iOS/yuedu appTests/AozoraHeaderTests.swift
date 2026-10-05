import Foundation
import Testing
@testable import yuedu_app

@Suite("Aozora header")
struct AozoraHeaderTests {
    @Test("two lines: title and author")
    func twoLines() {
        #expect(AozoraHeaderParser.parse(headerLines: ["山の話", "山田太郎"])
                == AozoraHeader(title: "山の話", author: "山田太郎"))
    }

    @Test("two lines: an anthology credits its editor, not an author")
    func twoLinesEditor() {
        #expect(AozoraHeaderParser.parse(headerLines: ["日本童話集", "山田太郎編"])
                == AozoraHeader(title: "日本童話集", editor: "山田太郎編"))
    }

    @Test("three lines: a line in the original script is the original title")
    func threeLinesOriginalTitle() {
        #expect(AozoraHeaderParser.parse(headerLines: ["大鴉", "The Raven", "エドガー・アラン・ポー"])
                == AozoraHeader(title: "大鴉", originalTitle: "The Raven", author: "エドガー・アラン・ポー"))
    }

    @Test("three lines: subtitle and author")
    func threeLinesSubtitle() {
        #expect(AozoraHeaderParser.parse(headerLines: ["山の話", "――続・野の話", "山田太郎"])
                == AozoraHeader(title: "山の話", subtitle: "――続・野の話", author: "山田太郎"))
    }

    @Test("three lines: a translation keeps the author and the translator apart")
    func threeLinesTranslation() {
        #expect(AozoraHeaderParser.parse(headerLines: ["変身", "フランツ・カフカ", "原田義人訳"])
                == AozoraHeader(title: "変身", author: "フランツ・カフカ", translator: "原田義人訳"))
    }

    @Test("three lines: 編訳 is one person editing and translating")
    func threeLinesHenyaku() {
        #expect(AozoraHeaderParser.parse(headerLines: ["昔話集", "グリム兄弟", "山田太郎編訳"])
                == AozoraHeader(title: "昔話集", author: "グリム兄弟", henyaku: "山田太郎編訳"))
    }

    @Test("four lines: original title in Cyrillic, author and translator")
    func fourLines() {
        #expect(AozoraHeaderParser.parse(headerLines: [
            "罪と罰", "Преступление и наказание", "ドストエフスキー", "中村白葉訳",
        ]) == AozoraHeader(title: "罪と罰", originalTitle: "Преступление и наказание",
                           author: "ドストエフスキー", translator: "中村白葉訳"))
    }

    @Test("four lines: a second subtitle line replaces the first, as in aozora2html")
    func fourLinesSubtitles() {
        #expect(AozoraHeaderParser.parse(headerLines: ["山の話", "上巻", "第一部", "山田太郎"])
                == AozoraHeader(title: "山の話", subtitle: "第一部", author: "山田太郎"))
    }

    @Test("five lines: original title, subtitle, author and translator")
    func fiveLines() {
        #expect(AozoraHeaderParser.parse(headerLines: [
            "大鴉", "The Raven", "――一八四五年", "エドガー・アラン・ポー", "山田太郎訳",
        ]) == AozoraHeader(title: "大鴉", originalTitle: "The Raven", subtitle: "――一八四五年",
                           author: "エドガー・アラン・ポー", translator: "山田太郎訳"))
    }

    @Test("five lines: a second author line keeps the first author")
    func fiveLinesSecondAuthor() {
        #expect(AozoraHeaderParser.parse(headerLines: ["題", "Title", "副題", "山田太郎", "鈴木花子"])?.author
                == "山田太郎")
    }

    @Test("six lines: every field")
    func sixLines() {
        #expect(AozoraHeaderParser.parse(headerLines: [
            "大鴉", "The Raven", "――一八四五年", "A Poem", "エドガー・アラン・ポー", "山田太郎訳",
        ]) == AozoraHeader(title: "大鴉", originalTitle: "The Raven", subtitle: "――一八四五年",
                           originalSubtitle: "A Poem", author: "エドガー・アラン・ポー",
                           translator: "山田太郎訳"))
    }

    @Test("one line or more than six keeps only the title; no lines is no header")
    func otherLengths() {
        #expect(AozoraHeaderParser.parse(headerLines: ["題"]) == AozoraHeader(title: "題"))
        #expect(AozoraHeaderParser.parse(headerLines: (1...7).map { "行\($0)" }) == AozoraHeader(title: "行1"))
        #expect(AozoraHeaderParser.parse(headerLines: []) == nil)
    }

    @Test("header lines stop at the first blank line and drop ruby")
    func headerLinesFromText() {
        let text = "めくらぶどうと｜虹《にじ》\r\n宮沢賢治\r\n\u{3000}\r\n本文"
        #expect(AozoraHeaderParser.headerLines(of: text) == ["めくらぶどうと虹", "宮沢賢治"])
    }
}
