import Foundation
import Testing
@testable import yuedu_app

@Suite("Aozora document detector")
struct AozoraDocumentDetectorTests {
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/TXTEncodings")

    @Test("the public-domain Aozora download is detected")
    func detectsPublicDomainFixture() throws {
        let text = try TXTFileReader.readTextFile(
            url: Self.fixtures.appendingPathComponent("aozora-neko-jijo.txt"))
        #expect(AozoraDocumentDetector.isAozoraDocument(text))
    }

    @Test("a colophon plus one annotation is enough without a notation block")
    func detectsColophonAndAnnotation() {
        let text = """
        短い話
        山田太郎

        ［＃３字下げ］一
        　雨が降っていた。



        底本：「短い話」架空書房
        　　　2001（平成13）年1月1日第1刷発行
        入力：誰か
        校正：別の誰か
        """
        #expect(AozoraDocumentDetector.isAozoraDocument(text))
    }

    @Test("an explicit ruby bar counts as markup next to a colophon")
    func detectsColophonAndExplicitRuby() {
        let text = "題\n著者\n\n　当時｜彼地《かのち》の話。\n\n底本：「題」架空書房\n"
        #expect(AozoraDocumentDetector.isAozoraDocument(text))
    }

    @Test("Chinese book-title brackets without a colophon are not Aozora")
    func rejectsChineseBookTitles() {
        let text = """
        第一章 藏經閣
        　他翻開《九陽神功》，又取出《易筋經》與《洗髓經》對照，終於明白了《太玄經》的奧秘。
        　書中有云：「功法《九陽》，需以內力催動。」
        """
        #expect(!AozoraDocumentDetector.isAozoraDocument(text))
    }

    @Test("a readme bundled in a comic archive is not Aozora")
    func rejectsReadme() {
        let text = """
        readme.txt
        ------------------------------------------------------------
        Scanned pages 001-212. 《無断転載禁止》
        Please do not redistribute. ｜Thanks!
        ------------------------------------------------------------
        """
        #expect(!AozoraDocumentDetector.isAozoraDocument(text))
    }

    @Test("bare ruby markup without a colophon or notation block is not enough")
    func rejectsMarkupWithoutDocumentStructure() {
        #expect(!AozoraDocumentDetector.isAozoraDocument("　私は漢字《かんじ》を読む。［＃改ページ］\n"))
    }

    @Test("existing non-Aozora TXT fixtures are not detected", arguments: [
        "aozora-cp932", "aozora-euc-jp", "simplified-gbk", "simplified-gb18030",
        "traditional-big5", "korean-euc-kr",
    ])
    func rejectsExistingFixtures(name: String) throws {
        // The two aozora-* fixtures are markup samples with no header,
        // notation block or colophon; they exercise codecs, not documents.
        let text = try String(contentsOf: Self.fixtures.appendingPathComponent(name + ".utf8"),
                              encoding: .utf8)
        #expect(!AozoraDocumentDetector.isAozoraDocument(text))
    }

    @Test("a long document is judged from its ends")
    func longDocumentUsesPrefixAndSuffix() {
        let filler = String(repeating: "　吾輩は猫である。名前はまだ無い。\n", count: 20_000)
        let colophon = "\n底本：「架空全集」架空書房\n入力：誰か\n"
        #expect(AozoraDocumentDetector.isAozoraDocument("題\n著者\n\n［＃５字下げ］一\n" + filler + colophon))
        // Markup only in the unread middle does not count.
        #expect(!AozoraDocumentDetector.isAozoraDocument(
            "題\n著者\n\n" + filler + "［＃５字下げ］一\n" + filler + colophon))
    }
}
