import Foundation
import CoreGraphics
import Testing
@testable import yuedu_app

@Suite("TXTMetadataProbe", .serialized)
struct TXTMetadataProbeTests {

    @Test("detects Traditional Chinese title and author labels")
    func detectsTraditionalChineseLabels() throws {
        let url = try writeTemporaryTXT("書名：射鵰英雄傳\n作者：金庸\n第一章 風雪驚變")

        let metadata = try TXTMetadataProbe.probe(url: url, fallbackTitle: "fallback")

        #expect(metadata.title == "射鵰英雄傳")
        #expect(metadata.author == "金庸")
    }

    @Test("detects Simplified Chinese metadata labels")
    func detectsSimplifiedChineseLabels() throws {
        let url = try writeTemporaryTXT("书名: 三体\n作者: 刘慈欣\n第一章")

        let metadata = try TXTMetadataProbe.probe(url: url, fallbackTitle: "fallback")

        #expect(metadata.title == "三体")
        #expect(metadata.author == "刘慈欣")
    }

    @Test("detects English metadata labels")
    func detectsEnglishLabels() throws {
        let url = try writeTemporaryTXT("Title: Pride and Prejudice\nAuthor: Jane Austen\nChapter 1")

        let metadata = try TXTMetadataProbe.probe(url: url, fallbackTitle: "fallback")

        #expect(metadata.title == "Pride and Prejudice")
        #expect(metadata.author == "Jane Austen")
    }

    @Test("uses line before standalone author credit as title")
    func detectsStandaloneAuthorCredit() throws {
        let url = try writeTemporaryTXT("射鵰英雄傳\n金庸 著\n第一章 風雪驚變")

        let metadata = try TXTMetadataProbe.probe(url: url, fallbackTitle: "fallback")

        #expect(metadata.title == "射鵰英雄傳")
        #expect(metadata.author == "金庸")
    }

    @Test("falls back to filename and nil author when metadata is absent")
    func fallsBackWhenMetadataIsAbsent() throws {
        let url = try writeTemporaryTXT("第一章\n這裡只有正文。")

        let metadata = try TXTMetadataProbe.probe(url: url, fallbackTitle: "檔名書名")

        #expect(metadata.title == "檔名書名")
        #expect(metadata.author == nil)
    }

    @Test("rejects a long body line as an inferred title")
    func rejectsLongBodyLineAsTitle() throws {
        let longBody = String(repeating: "這是一段正文內容，", count: 20)
        let url = try writeTemporaryTXT("\(longBody)\n王小明 著\n第一章")

        let metadata = try TXTMetadataProbe.probe(url: url, fallbackTitle: "安全檔名")

        #expect(metadata.title == "安全檔名")
        #expect(metadata.author == "王小明")
    }

    @Test("decodes GB18030 metadata using TXTFileReader rules")
    func decodesGB18030Metadata() throws {
        let text = "书名：活着\n作者：余华\n第一章"
        let data = try #require(text.data(using: TXTFileReader.gb18030Encoding))
        let url = try writeTemporaryTXT(data)

        let metadata = try TXTMetadataProbe.probe(url: url, fallbackTitle: "fallback")

        #expect(metadata.title == "活着")
        #expect(metadata.author == "余华")
    }

    @Test("reads a web novel's first line, 《書名》作者：某某 (万古神帝.txt, GB18030 with CRLF)")
    func readsBookTitleAuthorLine() throws {
        let text = "\u{3000}\u{3000}《万古神帝》作者：飞天鱼\r\n\r\n\u{3000}\u{3000}文案：\r\n\u{3000}\u{3000}天地初开，太古混乱。\r\n"
        let data = try #require(text.data(using: TXTFileReader.gb18030Encoding))
        let metadata = try TXTMetadataProbe.probe(url: try writeTemporaryTXT(data), fallbackTitle: "檔名")
        #expect(metadata.title == "万古神帝")
        #expect(metadata.author == "飞天鱼")

        for (line, title, author) in [("《斗罗大陆》 作者: 唐家三少", "斗罗大陆", "唐家三少"),
                                      ("《雪中悍刀行》（作者：烽火戏诸侯）", "雪中悍刀行", "烽火戏诸侯"),
                                      ("《詭秘之主》著者：愛潛水的烏賊", "詭秘之主", "愛潛水的烏賊")] {
            let found = TXTMetadataProbe.infer(from: line + "\n第一章 開始", fallbackTitle: "檔名")
            #expect(found.title == title, "\(line)")
            #expect(found.author == author, "\(line)")
        }
        let labelled = TXTMetadataProbe.infer(from: "《别名》作者：甲\n书名：正名\n作者：乙", fallbackTitle: "檔名")
        #expect(labelled.title == "正名" && labelled.author == "乙", "explicit 书名／作者 lines still win")
        let quoted = TXTMetadataProbe.infer(from: "他说：《三体》作者是刘慈欣。\n第一章", fallbackTitle: "檔名")
        #expect(quoted.author == nil, "a sentence mentioning a book is no credit line")
    }

    @Test("the four headers of the maintainer's TXT folder: title, author, 文案／内容简介 and 标签, banners skipped")
    func readsDownloadHeaders() {
        let wangu = TXTMetadataProbe.infer(from: """
        　　《万古神帝》作者：飞天鱼

        　　文案：
        　　天地初开，太古混乱。
        　　但，皆不可得长生……

        　　标签：重生 玄幻


        第一卷 云武王城【上】
        第1章 八百年后
        　　简介：这一行是正文。
        """, fallbackTitle: "万古神帝")
        #expect(wangu.title == "万古神帝" && wangu.author == "飞天鱼")
        #expect(wangu.intro == "天地初开，太古混乱。\n但，皆不可得长生……")
        #expect(wangu.tags == ["重生", "玄幻"])

        let xiuzhen = TXTMetadataProbe.infer(from: """
        ==========================================================
        本站发的所有小说都是校对全本-精校的无错TXT小说下载：http://www.freexiaoshuo.com/
        ==========================================================


        修真聊天群 作者：圣骑士的传说

        内容简介：
        　　某天，宋书航意外加入了一个仙侠中二病资深患者的交流群。
        　　啊啊啊啊，世界观在一夜间彻底崩碎啦！


        番外：《师父的新年礼物》
        　　黑龙世界，是一个有趣的魔法文明世界。
        """, fallbackTitle: "修真聊天群")
        #expect(xiuzhen.title == "修真聊天群" && xiuzhen.author == "圣骑士的传说")
        #expect(xiuzhen.intro == "某天，宋书航意外加入了一个仙侠中二病资深患者的交流群。\n啊啊啊啊，世界观在一夜间彻底崩碎啦！")

        let shixiong = TXTMetadataProbe.infer(from: """
        ==========================================================
        更多精校小说尽在精校吧下载：http://www.jingjiaoba.com
        ==========================================================
        我师兄实在太稳健了
        作者：言归正传


        内容简介：
        　　重生在封神大战之前的上古时代，李长寿成了一个小小的炼气士。


        第一章 小小灵娥
        """, fallbackTitle: "檔名")
        #expect(shixiong.title == "我师兄实在太稳健了" && shixiong.author == "言归正传")
        #expect(shixiong.intro == "重生在封神大战之前的上古时代，李长寿成了一个小小的炼气士。")

        let gou = TXTMetadataProbe.infer(from: """
        苟在武道世界成圣
        作者：在水中的纸老虎
        简介：
        　　简介：
        　　命格在手，苟道求生！

        第1章 乱世
        """, fallbackTitle: "檔名")
        #expect(gou.title == "苟在武道世界成圣" && gou.author == "在水中的纸老虎")
        #expect(gou.intro == "命格在手，苟道求生！", "the repeated 简介： is the label again")
        #expect(gou.tags.isEmpty)
    }

    @Test("a file's name: 《》, edition words and an author in it")
    func readsFileNames() {
        #expect(TXTMetadataProbe.fileNameParts("《万古神帝》（精校版全本）作者：飞天鱼") == ("万古神帝", "飞天鱼"))
        #expect(TXTMetadataProbe.fileNameParts("修真聊天群 作者：圣骑士的传说") == ("修真聊天群", "圣骑士的传说"))
        #expect(TXTMetadataProbe.fileNameParts("我师兄实在太稳健了【精校版】") == ("我师兄实在太稳健了", nil))
        #expect(TXTMetadataProbe.fileNameParts("斗罗大陆_全本精校") == ("斗罗大陆", nil))
        #expect(TXTMetadataProbe.fileNameParts("凡人修仙传(完结)") == ("凡人修仙传", nil))
        #expect(TXTMetadataProbe.fileNameParts("三体") == ("三体", nil))
        let named = TXTMetadataProbe.infer(from: "第一章\n只有正文。", fallbackTitle: "《雪中悍刀行》全本 作者：烽火戏诸侯")
        #expect(named.title == "雪中悍刀行" && named.author == "烽火戏诸侯", "the name is the fallback for both")
    }

    @Test("ignores metadata beyond the bounded sample")
    func ignoresMetadataBeyondSampleBoundary() throws {
        var data = Data(repeating: 0x61, count: TXTMetadataProbe.maximumSampleBytes)
        data.append(Data("\n作者：不應讀到\n".utf8))
        let url = try writeTemporaryTXT(data)

        let metadata = try TXTMetadataProbe.probe(url: url, fallbackTitle: "邊界測試")

        #expect(metadata.title == "邊界測試")
        #expect(metadata.author == nil)
    }

    @Test("reads the title and author of an Aozora Bunko download from its header")
    func readsAozoraHeader() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/TXTEncodings/aozora-neko-jijo.txt")

        let metadata = try TXTMetadataProbe.probe(url: fixture, fallbackTitle: "neko_chuhen")

        #expect(metadata.title == "『吾輩は猫である』中篇自序")
        #expect(metadata.author == "夏目漱石")
    }

    @Test("keeps the author and the translator of an Aozora Bunko translation apart")
    func readsAozoraTranslationHeader() throws {
        let url = try writeTemporaryTXT("""
        変身
        フランツ・カフカ
        原田義人訳

        -------------------------------------------------------
        【テキスト中に現れる記号について】

        《》：ルビ
        （例）一匹の巨大な毒虫《どくむし》
        -------------------------------------------------------

        　ある朝、目をさますと虫になっていた。

        底本：「架空の文庫」架空書房
        """)

        let metadata = try TXTMetadataProbe.probe(url: url, fallbackTitle: "fallback")

        #expect(metadata.title == "変身")
        #expect(metadata.author == "フランツ・カフカ")
    }

    @Test("BookStore imports the original TXT and inferred metadata")
    func bookStoreImportsOriginalTXTAndMetadata() async throws {
        let sourceData = Data("書名：邊城\n作者：沈從文\n\n第一章\n原始內容保持不變。".utf8)
        let sourceURL = try writeTemporaryTXT(sourceData)
        let metadataURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        let store = BookStore(metadataFileURL: metadataURL)

        let book = try await store.importTxt(url: sourceURL)
        let importedURL = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent(book.contentFilename)
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: importedURL)
            try? FileManager.default.removeItem(at: metadataURL)
        }

        #expect(book.title == "邊城")
        #expect(book.author == "沈從文")
        #expect(book.contentPipelineKind == .txt)
        #expect(book.contentFilename.hasSuffix(".txt"))
        #expect(try Data(contentsOf: importedURL) == sourceData)
    }

    @Test("a TXT imported as 未知作者 gets the author its file names; an author the reader typed stays")
    @MainActor
    func bookStoreRecoversTXTAuthors() async throws {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let credited = "\(UUID().uuidString).txt", typed = "\(UUID().uuidString).txt"
        let data = try #require("　　《万古神帝》作者：飞天鱼\r\n\r\n　　文案：\r\n　　天地初开，太古混乱。\r\n\r\n　　标签：重生\r\n\r\n第1章 八百年后".data(using: TXTFileReader.gb18030Encoding))
        try data.write(to: documents.appendingPathComponent(credited))
        try data.write(to: documents.appendingPathComponent(typed))
        let metadataURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        defer {
            try? FileManager.default.removeItem(at: documents.appendingPathComponent(credited))
            try? FileManager.default.removeItem(at: documents.appendingPathComponent(typed))
            try? FileManager.default.removeItem(at: metadataURL)
        }
        var unknown = ReadingBook(title: "万古神帝", author: "未知作者", source: "local", contentFilename: credited)
        unknown.contentPipelineKind = .txt
        var edited = ReadingBook(title: "万古神帝", author: "我寫的", source: "local", contentFilename: typed)
        edited.contentPipelineKind = .txt
        let store = BookStore(metadataFileURL: metadataURL)
        store.replaceBooksFromSync([unknown, edited])

        await store.rereadTXTHeaders()

        #expect(store.books.first { $0.id == unknown.id }?.author == "飞天鱼")
        #expect(store.books.first { $0.id == edited.id }?.author == "我寫的")
        store.importedMetadata.waitForPendingWritesForTesting()
        let sidecar = try #require(store.importedMetadata.read(copyID: unknown.id))
        #expect(sidecar.values.first { $0.field == .intro }?.value == .text("天地初开，太古混乱。"))
        #expect(sidecar.values.first { $0.field == .tags }?.value == .texts(["重生"]))
    }

    @Test("BookStore keeps GB18030 bytes while decoded content remains readable")
    func bookStoreKeepsGB18030BytesAndReadableContent() async throws {
        let text = "书名：活着\n作者：余华\n\n第一章\n原始内容保持不变。"
        let sourceData = try #require(text.data(using: TXTFileReader.gb18030Encoding))
        let sourceURL = try writeTemporaryTXT(sourceData)
        let metadataURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        let store = BookStore(metadataFileURL: metadataURL)

        let book = try await store.importTxt(url: sourceURL)
        let importedURL = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent(book.contentFilename)
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: importedURL)
            try? FileManager.default.removeItem(at: metadataURL)
        }

        #expect(book.title == "活着")
        #expect(book.author == "余华")
        #expect(try Data(contentsOf: importedURL) == sourceData)
        #expect(store.content(for: book) == text)
    }

    private func writeTemporaryTXT(_ text: String) throws -> URL {
        try writeTemporaryTXT(Data(text.utf8))
    }

    private func writeTemporaryTXT(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        try data.write(to: url)
        return url
    }
}
