import Foundation
import Testing
@testable import yuedu_app

@Suite("Aozora tokenizer")
struct AozoraTokenizerTests {
    @Test("each token kind")
    func eachKind() {
        let text = "前｜漢字《かんじ》、※［＃「口＋世」、ページ数-行数］〔cafe'〕／＼／″＼／゛＼［＃傍点］後\r\n次"
        #expect(describe(text) == [
            "text 前", "bar ｜", "text 漢字", "ruby 《かんじ》", "text 、",
            "gaiji ※［＃「口＋世」、ページ数-行数］", "accent 〔cafe'〕", "kunojiten ／＼",
            "kunojiten-voiced ／″＼", "kunojiten-voiced ／゛＼", "annotation ［＃傍点］", "text 後",
            "newline \r\n", "text 次",
        ])
    }

    @Test("content ranges hold what is between the delimiters")
    func contentRanges() {
        let text = "漢字《かんじ》※［＃コト、1-2-24］［＃傍点］〔e'te'〕〔open"
        let units = Array(text.utf16)
        let contents = AozoraTokenizer.tokenize(text)
            .filter { $0.kind != .text }
            .map { String(decoding: units[$0.content], as: UTF16.self) }
        #expect(contents == ["かんじ", "コト、1-2-24", "傍点", "e'te'", "open"])
    }

    @Test("unterminated annotations and readings stay text")
    func unterminatedMarkupStaysText() {
        #expect(describe("前［＃傍点の途中\n漢字《かんじ\n") == [
            "text 前［＃傍点の途中", "newline \n", "text 漢字《かんじ", "newline \n",
        ])
        #expect(describe("空《》と※と［普通の括弧］") == ["text 空《》と※と［普通の括弧］"])
        #expect(describe("二重《か《な》") == ["text 二重《か", "ruby 《な》"])
    }

    @Test("an annotation may span lines")
    func annotationSpansLines() {
        #expect(describe("前［＃入力者注：一行目\r\n二行目］後") == [
            "text 前", "annotation ［＃入力者注：一行目\r\n二行目］", "text 後",
        ])
    }

    @Test("only ［＃ nests; a plain ［ is a character")
    func nesting() {
        #expect(describe("X［＃「※［＃「口＋世」、ページ数-行数］」に傍点］Y") == [
            "text X", "annotation ［＃「※［＃「口＋世」、ページ数-行数］」に傍点］", "text Y",
        ])
        #expect(describe("［＃「［」は括弧］後") == ["annotation ［＃「［」は括弧］", "text 後"])
        #expect(describe("漢《※［＃「口＋世」、1-15-8］》") == [
            "text 漢", "ruby 《※［＃「口＋世」、1-15-8］》",
        ])
    }

    @Test("an accent bracket runs to its line end when it never closes")
    func unclosedAccent() {
        #expect(describe("〔Pardonnez a` mon\r\n次〕") == [
            "accent-open 〔Pardonnez a` mon", "newline \r\n", "text 次〕",
        ])
    }

    @Test("every newline form is one token")
    func newlines() {
        #expect(describe("a\rb\r\nc\n") == [
            "text a", "newline \r", "text b", "newline \r\n", "text c", "newline \n",
        ])
    }

    @Test("token ranges cover the source exactly once", arguments: [
        "", "前", "｜", "《》", "［＃", "※［＃］", "〔", "／″", "\r\n\r",
        "前｜漢字《かんじ》、※［＃「口＋世」、ページ数-行数］〔cafe'〕／＼［＃傍点］後\r\n𠮷《よし》",
    ])
    func coverage(text: String) {
        expectCoverage(text)
    }

    @Test("the public-domain fixture is covered exactly once")
    func fixtureCoverage() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/TXTEncodings/aozora-neko-jijo.txt")
        let text = try TXTFileReader.readTextFile(url: fixture)
        expectCoverage(text)
        let kinds = AozoraTokenizer.tokenize(text).map(\.kind)
        // Two gaiji in the body and one example in the notation block; the
        // block's two ruby examples are among the 72 readings.
        #expect(kinds.filter { $0 == .gaiji }.count == 3)
        #expect(kinds.filter { $0 == .ruby }.count == 72)
    }

    private func expectCoverage(_ text: String) {
        let tokens = AozoraTokenizer.tokenize(text)
        var cursor = 0
        for token in tokens {
            #expect(token.range.lowerBound == cursor)
            #expect(!token.range.isEmpty)
            cursor = token.range.upperBound
        }
        #expect(cursor == text.utf16.count)
    }

    private func describe(_ text: String) -> [String] {
        let units = Array(text.utf16)
        return AozoraTokenizer.tokenize(text).map { token in
            let name: String
            switch token.kind {
            case .text: name = "text"
            case .rubyBar: name = "bar"
            case .ruby: name = "ruby"
            case .annotation: name = "annotation"
            case .gaiji: name = "gaiji"
            case .accent(let closed): name = closed ? "accent" : "accent-open"
            case .kunojiten(let voiced): name = voiced ? "kunojiten-voiced" : "kunojiten"
            case .newline: name = "newline"
            }
            return name + " " + String(decoding: units[token.range], as: UTF16.self)
        }
    }
}
