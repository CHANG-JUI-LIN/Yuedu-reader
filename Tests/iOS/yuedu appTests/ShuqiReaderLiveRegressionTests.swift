import Foundation
import Testing
import UIKit
@testable import yuedu_app

private let shuqiReaderLiveTestsEnabled =
    ProcessInfo.processInfo.environment["RUN_SHUQI_READER_LIVE_TESTS"] == "1"

@Suite("Shuqi reader live regression", .serialized)
@MainActor
struct ShuqiReaderLiveRegressionTests {
    private static let sourcePath =
        "/Users/zhangruilin/Desktop/Test document/RULE/书旗（同人）.json"

    @Test("nested ajax does not replace the enclosing JavaScript result")
    func nestedAjaxKeepsEnclosingResult() throws {
        var source = BookSource()
        source.bookSourceName = "Nested ajax fixture"
        source.bookSourceUrl = "https://example.com"
        source.ruleContent.content = #"@js:(function () { var text = '正文'; java.ajax('data:text/plain;base64,e30=,{\"method\":\"GET\"}'); return text; })();"#

        let payload = try ModernParserBridge(source: source).parseChapterResult(
            html: "seed",
            baseURL: "https://example.com/chapter",
            source: source
        )

        #expect(payload.content == "正文")
    }

    @Test("comment decoration failure keeps the decoded chapter result")
    func commentAPIFailureKeepsChapterResult() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: Self.sourcePath))
        let source = try #require(JSONDecoder().decode([BookSource].self, from: data).first)
        LoginManager.shared.storeLoginInfo(
            sourceUrl: source.bookSourceUrl,
            info: ["段评开关": "✅", "章评开关": "✅"]
        )
        defer { LoginManager.shared.clearLogin(sourceUrl: source.bookSourceUrl) }

        let plainText = "第一段正文。<br>第二段正文。"
        var fixtureSource = source
        fixtureSource.jsLib += "\nsqPost = function () { return { ok: false, error: 'fixture' }; };"
        fixtureSource.ruleContent.content =
            "@js:sqDecorateContent.call(this, String(src), '1', '2', '测试章节')"
        let payload = try ModernParserBridge(source: fixtureSource).parseChapterResult(
            html: plainText,
            baseURL: "https://example.com/chapter?sqBid=1&sqCid=2",
            source: fixtureSource
        )

        #expect(payload.content == plainText)
    }

    @Test(
        "live comment API failure keeps the enclosing source-script result",
        .enabled(
            if: shuqiReaderLiveTestsEnabled,
            "Set RUN_SHUQI_READER_LIVE_TESTS=1 to run external source requests"
        )
    )
    func liveCommentAPIKeepsContent() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: Self.sourcePath))
        let source = try #require(JSONDecoder().decode([BookSource].self, from: data).first)
        LoginManager.shared.storeLoginInfo(
            sourceUrl: source.bookSourceUrl,
            info: ["段评开关": "✅", "章评开关": "✅"]
        )
        defer { LoginManager.shared.clearLogin(sourceUrl: source.bookSourceUrl) }

        let result = ModernParserBridge(source: source).evaluateSourceScript(
            "sqDecorateContent.call(this,'第一段正文。<br>第二段正文。','8961399','2158269','第一章')"
        )

        #expect(result == "第一段正文。<br>第二段正文。")
    }

    @Test(
        "first chapter survives the production CoreText reader pipeline",
        .enabled(
            if: shuqiReaderLiveTestsEnabled,
            "Set RUN_SHUQI_READER_LIVE_TESTS=1 to run external source requests"
        )
    )
    func firstChapterReaderPipeline() async throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: Self.sourcePath))
        var source = try #require(JSONDecoder().decode([BookSource].self, from: data).first)
        source.id = UUID()
        source.lastUpdateTime = Int64(Date().timeIntervalSince1970 * 1_000)
        LoginManager.shared.storeLoginInfo(
            sourceUrl: source.bookSourceUrl,
            info: ["段评开关": "✅", "章评开关": "✅"]
        )
        defer { LoginManager.shared.clearLogin(sourceUrl: source.bookSourceUrl) }

        let fetcher = BookSourceFetcher.shared
        let books = try await fetcher.search(query: "斗罗大陆", in: source)
        let book = try #require(books.first)
        let info = try await fetcher.fetchBookInfoPackage(
            url: book.bookUrl,
            source: source,
            runtimeVariables: book.runtimeVariables
        )
        let tocURL = info.tocUrl.isEmpty ? book.bookUrl : info.tocUrl
        let toc = try await fetcher.fetchTOCPackage(
            tocUrl: tocURL,
            source: source,
            runtimeVariables: info.runtimeVariables,
            onFirstPageReady: nil,
            forceRefresh: true
        )
        var chapter = try #require(toc.chapters.first {
            $0.hasLoadableContentURL && !$0.shouldRenderAsVolumeSeparator
        })
        if let runtimeVariables = toc.runtimeVariables ?? info.runtimeVariables,
           !runtimeVariables.isEmpty {
            var merged = runtimeVariables
            for (key, value) in chapter.runtimeVariables ?? [:] {
                merged[key] = value
            }
            chapter.runtimeVariables = merged
        }

        let bookID = UUID()
        defer { fetcher.clearAllChapterCache(bookId: bookID) }
        let package = try await fetcher.fetchChapterPackage(
            ref: chapter,
            bookId: bookID,
            source: source,
            chapterReferer: tocURL
        )
        let normalizedHTML = try #require(fetcher.loadNormalizedChapterHTMLSync(
            bookId: bookID,
            chapterIndex: chapter.index,
            expectedSourceURL: chapter.url,
            expectedTOCTitle: chapter.title
        ))

        let provider = ShuqiFixedContentProvider(payload: ChapterContentPayload(
            index: 0,
            title: chapter.title,
            plainText: package.content,
            body: .html(normalizedHTML),
            sourceHref: chapter.url
        ))
        let size = CGSize(width: 390, height: 844)
        let settings = ReaderRenderSettings(
            theme: "test",
            textColor: .label,
            backgroundColor: .systemBackground,
            fontSize: 18,
            lineHeightMultiple: 1.5,
            lineSpacing: 0,
            paragraphSpacing: 8,
            letterSpacing: 0,
            marginH: 20,
            marginV: 16,
            footerHeight: 0,
            contentInsets: UIEdgeInsets(top: 16, left: 20, bottom: 16, right: 20),
            writingMode: .horizontal
        )
        let rendered = try await OnlineProviderAttributedStringBuilder(
            provider: provider,
            renderSize: size
        ).buildChapter(
            at: 0,
            settings: settings,
            themeTextColor: .label,
            themeBackgroundColor: .systemBackground
        )
        let layout = await CoreTextPaginator().paginate(
            spineIndex: 0,
            attrStr: rendered.attributedString,
            renderSize: size,
            fontSize: settings.fontSize,
            contentInsets: settings.contentInsets
        )

        #expect(!package.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(rendered.attributedString.length > 0)
        #expect(!layout.pageRanges.isEmpty)
    }
}

private final class ShuqiFixedContentProvider: BookContentProvider {
    let payload: ChapterContentPayload

    init(payload: ChapterContentPayload) {
        self.payload = payload
    }

    var totalChapters: Int { 1 }
    func chapterTitle(at index: Int) -> String { payload.title }
    func contentForChapter(index: Int) async throws -> ChapterContentPayload { payload }
}
