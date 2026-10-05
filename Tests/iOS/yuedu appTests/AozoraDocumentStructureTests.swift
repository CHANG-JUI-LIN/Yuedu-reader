import Foundation
import Testing
@testable import yuedu_app

@Suite("Aozora document structure")
struct AozoraDocumentStructureTests {
    private static let notation = """
        -------------------------------------------------------
        【テキスト中に現れる記号について】

        《》：ルビ
        （例）雨《あめ》
        -------------------------------------------------------
        """

    @Test("header, notation block, body and colophon")
    func withNotationBlock() {
        let text = "山の話\n山田太郎\n\n\(Self.notation)\n\n　雨が降る。\n\n底本：「山の話」架空書房\n入力：誰か\n"
        let document = AozoraDocumentParser.parse(text)
        #expect(document.structure == AozoraDocumentStructure(
            header: 0..<2, notationBlock: 3...8, body: 9..<12, colophon: 12..<15))
        #expect(document.header == AozoraHeader(title: "山の話", author: "山田太郎"))
        #expect(document.diagnostics.isEmpty)
    }

    @Test("without a notation block the body starts at the blank line")
    func withoutNotationBlock() {
        let text = "山の話\n山田太郎\n\n　雨が降る。\n底本：「山の話」架空書房"
        #expect(AozoraDocumentParser.parse(text).structure == AozoraDocumentStructure(
            header: 0..<2, notationBlock: nil, body: 2..<4, colophon: 4..<5))
    }

    @Test("an unclosed notation block leaves the rest as body and is diagnosed")
    func unclosedNotationBlock() {
        let text = "山の話\n山田太郎\n\n-------------------------------------------------------\n【テキスト中に現れる記号について】\n　雨が降る。\n"
        let document = AozoraDocumentParser.parse(text)
        #expect(document.structure == AozoraDocumentStructure(
            header: 0..<2, notationBlock: nil, body: 2..<7, colophon: 7..<7))
        #expect(document.diagnostics[.unclosedNotationBlock] == 1)
    }

    @Test("hyphen lines fencing body text do not make a notation block")
    func fencedBodyTextStays() {
        let text = "詩集\n山田太郎\n\n----------------------------------------\n\n序\n\n　詩を書き初めたころ。\n----------------------------------------\n　一\n"
        #expect(AozoraDocumentParser.parse(text).structure == AozoraDocumentStructure(
            header: 0..<2, notationBlock: nil, body: 2..<11, colophon: 11..<11))
    }

    @Test("a notation block must open within five lines of the header")
    func lateHyphenLineIsBody() {
        let text = "題\n著者\n\n\n\n\n\n\(Self.notation)\n本文"
        #expect(AozoraDocumentParser.parse(text).structure.notationBlock == nil)
    }

    @Test("a file without a colophon is all body after the header")
    func noColophon() {
        let text = "題\n著者\n\n本文\n"
        #expect(AozoraDocumentParser.parse(text).structure == AozoraDocumentStructure(
            header: 0..<2, notationBlock: nil, body: 2..<5, colophon: 5..<5))
    }

    @Test("the public-domain download: two header lines, body from line 16, colophon from line 43")
    func publicDomainFixture() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/TXTEncodings/aozora-neko-jijo.txt")
        let document = AozoraDocumentParser.parse(try TXTFileReader.readTextFile(url: fixture))
        #expect(document.structure.header == 0..<2)
        #expect(document.structure.notationBlock == 3...15)
        #expect(document.structure.body.lowerBound == 16)
        #expect(document.structure.colophon.lowerBound == 43)
        #expect(document.header == AozoraHeader(title: "『吾輩は猫である』中篇自序", author: "夏目漱石"))
        #expect(document.bibliography == AozoraBibliography(
            source: "「筑摩全集類聚版　夏目漱石全集第十巻」筑摩書房\n1972（昭和47）年1月10日第1刷発行",
            firstPublished: nil, input: "Nana ohbe", proofreading: "米田進"))
        #expect(document.diagnostics.isEmpty)
    }

    @Test("colophon fields keep their continuation lines")
    func bibliographyFields() {
        let lines = ["底本：「架空全集」架空書房", "　　　1999年1月1日発行", "初出：「架空」", "入力：誰か",
                     "校正：別の誰か", "2002年5月10日作成", "　これは続きではない"]
        #expect(AozoraDocumentParser.bibliography(of: lines) == AozoraBibliography(
            source: "「架空全集」架空書房\n1999年1月1日発行", firstPublished: "「架空」",
            input: "誰か", proofreading: "別の誰か"))
    }
}
