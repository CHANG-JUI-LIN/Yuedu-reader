import Foundation
import Testing
@testable import yuedu_app

/// `ruleToc.updateTime` (回饋 #85): the source's 更新時間 read per table-of-contents row and
/// shown under the chapter title.
@Suite("Chapter update time", .serialized)
struct ChapterUpdateTimeTests {

    private static func source(_ configure: (inout BookSource) -> Void) -> BookSource {
        var source = BookSource()
        source.bookSourceName = "update-time fixture"
        source.bookSourceUrl = "update-time-\(UUID().uuidString)"
        configure(&source)
        return source
    }

    // MARK: Parsing

    @Test("a CSS rule reads each row's time; a row without one has none")
    func cssRule() throws {
        let source = Self.source {
            $0.ruleToc.chapterList = "ul.toc li"
            $0.ruleToc.chapterName = "a@text"
            $0.ruleToc.chapterUrl = "a@href"
            $0.ruleToc.updateTime = "span.time@text"
        }
        let html = """
        <ul class="toc">
          <li><a href="/c/1">第一章</a><span class="time"> 第一卷 | 2026-10-01 </span></li>
          <li><a href="/c/2">第二章</a><span class="time">   </span></li>
          <li><a href="/c/3">第三章</a></li>
        </ul>
        """
        let chapters = try ModernParserBridge(source: source).parseTOC(
            html: html, baseURL: "https://toc.example/book/1", source: source
        )
        #expect(chapters.map(\.title) == ["第一章", "第二章", "第三章"])
        #expect(chapters.map(\.updateTime) == ["第一卷 | 2026-10-01", nil, nil])
    }

    @Test("a JSONPath rule reads each row's time")
    func jsonRule() throws {
        let source = Self.source {
            $0.ruleToc.chapterList = "$.chapters[*]"
            $0.ruleToc.chapterName = "$.name"
            $0.ruleToc.chapterUrl = "$.url"
            $0.ruleToc.updateTime = "$.time"
        }
        let json = #"{"chapters":[{"name":"一","url":"https://toc.example/1","time":"2026-10-01 08:00"},{"name":"二","url":"https://toc.example/2"}]}"#
        let chapters = try ModernParserBridge(source: source).parseTOC(
            html: json, baseURL: "https://toc.example/api/toc", source: source
        )
        #expect(chapters.map(\.updateTime) == ["2026-10-01 08:00", nil])
    }

    @Test("a JS chapter list's rows carry their time")
    func jsChapterList() throws {
        let source = Self.source {
            $0.ruleToc.chapterList = """
            <js>
            JSON.parse(result).list.map(o => ({ title: o.n, url: "https://toc.example/c/" + o.c, time: o.v + " | " + o.t }));
            </js>
            """
            $0.ruleToc.chapterName = "title"
            $0.ruleToc.chapterUrl = "url"
            $0.ruleToc.updateTime = "time"
        }
        let json = #"{"list":[{"c":1,"n":"第1章","v":"卷一","t":"10-01"},{"c":2,"n":"第2章","v":"卷一","t":"10-02"}]}"#
        let chapters = try ModernParserBridge(source: source).parseTOC(
            html: json, baseURL: "https://toc.example/api/toc", source: source
        )
        #expect(chapters.map(\.updateTime) == ["卷一 | 10-01", "卷一 | 10-02"])
    }

    @Test("a source without the rule leaves every row without a time")
    func noRule() throws {
        let source = Self.source {
            $0.ruleToc.chapterList = "ul.toc li"
            $0.ruleToc.chapterName = "a@text"
            $0.ruleToc.chapterUrl = "a@href"
        }
        let html = #"<ul class="toc"><li><a href="/c/1">第一章</a><span class="time">2026</span></li></ul>"#
        let chapters = try ModernParserBridge(source: source).parseTOC(
            html: html, baseURL: "https://toc.example/book/1", source: source
        )
        #expect(chapters.count == 1)
        #expect(chapters[0].updateTime == nil)
    }

    @Test("a following table-of-contents page reads its rows' times too")
    func followingPage() throws {
        let source = Self.source {
            $0.ruleToc.chapterList = "ul.toc li"
            $0.ruleToc.chapterName = "a@text"
            $0.ruleToc.chapterUrl = "a@href"
            $0.ruleToc.updateTime = "span.time@text"
            $0.ruleToc.nextTocUrl = "a.next@href"
        }
        let html = """
        <ul class="toc"><li><a href="/c/9">第九章</a><span class="time">10-09</span></li></ul>
        <a class="next" href="/book/1?page=3">下一頁</a>
        """
        let page = try ModernParserBridge(source: source).parseTOCPage(
            html: html, baseURL: "https://toc.example/book/1?page=2", source: source
        )
        #expect(page.chapters.map(\.updateTime) == ["10-09"])
        #expect(page.nextTocURLs == ["https://toc.example/book/1?page=3"])
    }

    // MARK: Storage

    @Test("a list saved before the field decodes without a time, and none encodes no key")
    func codingCompatibility() throws {
        let saved = #"{"index":0,"title":"第一章","url":"https://toc.example/1"}"#
        let decoded = try JSONDecoder().decode(OnlineChapterRef.self, from: Data(saved.utf8))
        #expect(decoded.updateTime == nil)

        let encoded = try #require(String(data: try JSONEncoder().encode(decoded), encoding: .utf8))
        #expect(!encoded.contains("updateTime"))

        var timed = decoded
        timed.updateTime = "2026-10-01"
        let roundTrip = try JSONDecoder().decode(
            OnlineChapterRef.self, from: try JSONEncoder().encode(timed)
        )
        #expect(roundTrip.updateTime == "2026-10-01")
    }

    @Test("the cached table of contents is rewritten when only a time changed")
    func fingerprintSeesTime() {
        let plain = [OnlineChapterRef(index: 0, title: "第一章", url: "https://toc.example/1")]
        var timed = plain
        timed[0].updateTime = "10-01"
        var later = plain
        later[0].updateTime = "10-02"
        let fingerprint = { BookSourceFetcher.tocFingerprint(chapters: $0, runtimeVariables: nil) }
        #expect(fingerprint(plain) != fingerprint(timed))
        #expect(fingerprint(timed) != fingerprint(later))
    }

    // MARK: Table of contents

    @Test("an online book's rows carry the time, indexed by position")
    func mapperCarriesTime() {
        let refs = [
            OnlineChapterRef(index: 7, title: "第一卷", url: "", isVolume: true),
            OnlineChapterRef(index: 8, title: "第一章", url: " https://toc.example/1 ", updateTime: "10-01"),
        ]
        let chapters = ReaderTOCChapterMapper.chapters(from: refs)
        #expect(chapters.map(\.index) == [0, 1])
        #expect(chapters.map(\.title) == ["第一卷", "第一章"])
        #expect(chapters.map(\.updateTime) == [nil, "10-01"])
        #expect(chapters[1].href == refs[1].sanitizedContentURL)
    }
}
