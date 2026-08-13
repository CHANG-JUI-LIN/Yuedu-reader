import Foundation
import Testing
import UIKit
@testable import yuedu_app

private let shuqiReaderLiveTestsEnabled =
    ProcessInfo.processInfo.environment["RUN_SHUQI_READER_LIVE_TESTS"] == "1"
        || ProcessInfo.processInfo.environment["TEST_RUNNER_RUN_SHUQI_READER_LIVE_TESTS"] == "1"

@Suite("Shuqi reader live regression", .serialized)
@MainActor
struct ShuqiReaderLiveRegressionTests {
    private static let sourcePath =
        "/Users/zhangruilin/Desktop/Test document/RULE/书旗（同人）.json"

    @Test("TOC list variables stay book-scoped and chapter deltas stay isolated")
    func tocRuntimeVariablesAreCompactedByScope() throws {
        let sharedValue = String(repeating: "book-map-entry;", count: 1_500)
        let sharedLiteral = try #require(jsonStringLiteral(sharedValue))
        var source = BookSource()
        source.bookSourceName = "TOC runtime scope fixture"
        source.bookSourceUrl = "toc-runtime-scope-\(UUID().uuidString)"
        source.ruleToc.chapterList = """
        <js>
        java.put("sharedMap", \(sharedLiteral));
        [{"title":"First","url":"/1"},{"title":"Second","url":"/2"}]
        </js>
        """
        source.ruleToc.chapterName = """
        title@js:
        java.put("chapterOnly", String(result));
        result
        """
        source.ruleToc.chapterUrl = "url"
        source.ruleContent.content = "@js:java.get('sharedMap') + '|' + java.get('chapterOnly')"

        let result = try BookSourceParsingPipeline().parseTOCResult(
            html: "{}",
            baseURL: "https://example.com/catalog",
            source: source
        )

        #expect(result.runtimeVariables?["sharedMap"] == sharedValue)
        #expect(result.chapters.map { $0.runtimeVariables?["chapterOnly"] } == ["First", "Second"])
        #expect(result.chapters.allSatisfy { $0.runtimeVariables?["sharedMap"] == nil })
        let freshBridge = ModernParserBridge(source: source)
        #expect(freshBridge.evaluateSourceScript("java.get('chapterOnly')") == "")
        #expect(freshBridge.evaluateSourceScript("java.get('sharedMap')") == "")

        var merged = result.runtimeVariables ?? [:]
        for (key, value) in result.chapters[1].runtimeVariables ?? [:] {
            merged[key] = value
        }
        let parsed = try ModernParserBridge(source: source).parseChapterResult(
            html: "seed",
            baseURL: result.chapters[1].url,
            source: source,
            runtimeVariables: merged,
            chapterRef: result.chapters[1]
        )
        #expect(parsed.content == sharedValue + "|Second")

        let package = TOCPackage(
            sourceId: source.id,
            sourceName: source.bookSourceName,
            tocURL: "https://example.com/catalog",
            runtimeVariables: result.runtimeVariables,
            chapters: result.chapters,
            rawHTMLFilename: nil,
            savedAt: Date()
        )
        #expect(try JSONEncoder().encode(package).count < sharedValue.utf8.count * 2)
    }

    @Test("ROT13 Base64 chapter payload survives the complete content rule")
    func rot13Base64ContentRule() throws {
        var source = BookSource()
        source.bookSourceName = "ROT13 chapter fixture"
        source.bookSourceUrl = "rot13-content-\(UUID().uuidString)"
        source.ruleContent.content = #"""
        @js:
        (function () {
          var raw = String(src || "").trim();
          if (/^https?:\/\//i.test(raw)) return "unexpected URL";
          var obj = JSON.parse(raw || "{}");
          function p(e) {
            return String(e || "").split("").map(function (ch) {
              return ch.match(/[A-Za-z]/)
                ? ((c = Math.floor(ch.charCodeAt(0) / 97),
                   k = (ch.toLowerCase().charCodeAt(0) - 83) % 26 || 26,
                   String.fromCharCode(k + (0 == c ? 64 : 96))))
                : ch;
            }).join("");
          }
          return java.base64Decode(p(obj.ChapterContent || ""));
        })();
        """#
        let encoded = "CTWlYm7aeXmxhVQad6QzenCzybp="
        let bridge = ModernParserBridge(source: source)

        let decoded = bridge.evaluateSourceScript(
            "java.base64Decode((function p(e) {"
                + "return String(e || '').split('').map(function (ch) {"
                + "return ch.match(/[A-Za-z]/) ? ((c = Math.floor(ch.charCodeAt(0) / 97),"
                + "k = (ch.toLowerCase().charCodeAt(0) - 83) % 26 || 26,"
                + "String.fromCharCode(k + (0 == c ? 64 : 96)))) : ch;"
                + "}).join('');})(\(try #require(jsonStringLiteral(encoded)))))"
        )
        #expect(decoded == "<br/>第一章正文")

        let responseData = try JSONSerialization.data(withJSONObject: [
            "message": "success",
            "ChapterContent": encoded,
        ])
        let response = try #require(String(data: responseData, encoding: .utf8))
        let payload = try bridge.parseChapterResult(
            html: response,
            baseURL: "https://example.com/chapter?bookId=1&chapterId=2",
            source: source,
            runtimeVariables: [:],
            chapterRef: OnlineChapterRef(
                index: 0,
                title: "第一章",
                url: "https://example.com/chapter?bookId=1&chapterId=2",
                isVolume: false,
                isVip: false,
                isPay: false
            )
        )
        #expect(payload.content == "<br/>第一章正文")
    }

    @Test("regex literal does not turn a nested return into a top-level return")
    func regexLiteralKeepsNestedReturnScope() {
        let engine = JSCoreEngine()
        let value = engine.evaluateIsolated(
            #"""
            (function () {
                if (/^https?:\/\//i.test("https://example.com")) {
                    return "正文";
                }
                return "错误";
            })();
            """#,
            bindings: [:]
        )

        #expect(value == "正文")
    }

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
        var loadedSource = try #require(JSONDecoder().decode([BookSource].self, from: data).first)
        loadedSource.id = UUID()
        loadedSource.lastUpdateTime = Int64(Date().timeIntervalSince1970 * 1_000)
        let source = loadedSource
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

    @Test(
        "discover detail and TOC follow the production detail-screen path",
        .enabled(
            if: shuqiReaderLiveTestsEnabled,
            "Set RUN_SHUQI_READER_LIVE_TESTS=1 to run external source requests"
        ),
        .timeLimit(.minutes(3))
    )
    func discoverDetailTOCPipeline() async throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: Self.sourcePath))
        var loadedSource = try #require(JSONDecoder().decode([BookSource].self, from: data).first)
        loadedSource.id = UUID()
        loadedSource.lastUpdateTime = Int64(Date().timeIntervalSince1970 * 1_000)
        let source = loadedSource

        let fetcher = BookSourceFetcher.shared
        let items = await fetcher.discoverItems(in: source)
        let discoverItem = try #require(items.first {
            !(($0.url ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        })
        let books = try await fetcher.discoverBooks(from: discoverItem, in: source)
        let book = try #require(books.first { !$0.bookUrl.isEmpty })
        print(
            "[ShuqiDiscoverDetail] book=\(book.name) bookUrl=\(book.bookUrl) "
                + "tocUrl=\(book.tocUrl) runtime=\(book.runtimeVariables ?? [:])"
        )

        let trimmedTOCURL = book.tocUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let runtimeVariables = book.runtimeVariables
        let resolved: (TOCPackage, BookInfoPackage)
        if !trimmedTOCURL.isEmpty,
           trimmedTOCURL != book.bookUrl {
            // This is the same concurrent fast path used by OnlineBookView when a
            // discover result already supplies a distinct TOC URL.
            async let tocTask = fetcher.fetchTOCPackage(
                tocUrl: trimmedTOCURL,
                source: source,
                runtimeVariables: runtimeVariables,
                onFirstPageReady: nil,
                forceRefresh: true
            )
            async let infoTask = fetcher.fetchBookInfoPackage(
                url: book.bookUrl,
                source: source,
                runtimeVariables: runtimeVariables
            )
            resolved = try await (tocTask, infoTask)
        } else {
            let info = try await fetcher.fetchBookInfoPackage(
                url: book.bookUrl,
                source: source,
                runtimeVariables: runtimeVariables
            )
            let tocURL = info.tocUrl.isEmpty ? book.bookUrl : info.tocUrl
            let toc = try await fetcher.fetchTOCPackage(
                tocUrl: tocURL,
                source: source,
                runtimeVariables: info.runtimeVariables,
                onFirstPageReady: nil,
                forceRefresh: true
            )
            resolved = (toc, info)
        }

        let (toc, info) = resolved
        let encoder = JSONEncoder()
        let chapterRuntimeBytes = try toc.chapters.map {
            try encoder.encode($0.runtimeVariables ?? [:]).count
        }
        let packageBytes = try encoder.encode(toc).count
        print(
            "[ShuqiDiscoverDetail] detailTOC=\(info.tocUrl) chapters=\(toc.chapters.count) "
                + "firstChapterRuntimeBytes=\(chapterRuntimeBytes.first ?? 0) "
                + "chapterRuntimeBytesTotal=\(chapterRuntimeBytes.reduce(0, +)) "
                + "tocPackageBytes=\(packageBytes)"
        )
        #expect(!toc.chapters.isEmpty)

        // Continue through the same bookshelf metadata encoder used by
        // OnlineBookView.applyFinal; fetch-only success cannot catch an OOM/watchdog
        // termination caused by serializing chapter metadata.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ShuqiDiscoverPersistence-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let metadataURL = directory.appendingPathComponent("books_meta.json")
        let store = BookStore(metadataFileURL: metadataURL)
        let shelfBook = store.addOnlineBook(
            name: book.name,
            author: book.author,
            sourceId: source.id,
            bookInfoURL: book.bookUrl,
            tocURL: info.tocUrl,
            runtimeVariables: book.runtimeVariables,
            chapters: []
        )
        store.updateOnlineChapters(
            bookId: shelfBook.id,
            chapters: toc.chapters,
            runtimeVariables: toc.runtimeVariables
        )
        store.replaceBooksFromSync(store.books)
        let persistedBytes = try Data(contentsOf: metadataURL).count
        let persisted = try #require(BookStore(metadataFileURL: metadataURL).books.first)
        print("[ShuqiDiscoverDetail] persistedBookStoreBytes=\(persistedBytes)")
        #expect(persisted.onlineChapters?.count == toc.chapters.count)
        #expect(persisted.runtimeVariables == toc.runtimeVariables)
        // The old bug copied a roughly 225 KB whole-book map into every chapter.
        // Use per-chapter bounds so a legitimately long 6,000+ chapter book does
        // not fail a fixed-size assertion merely because its ordinary titles and
        // URLs take more bytes. The compact runtime delta should remain tiny, and
        // the complete package/store should stay below 2 KB per chapter.
        #expect(chapterRuntimeBytes.allSatisfy { $0 < 512 })
        #expect(chapterRuntimeBytes.reduce(0, +) < toc.chapters.count * 512)
        #expect(packageBytes < max(5_000_000, toc.chapters.count * 2_048))
        #expect(persistedBytes < max(5_000_000, toc.chapters.count * 2_048))

        // Prove that compacting the TOC runtime does not merely avoid the
        // persistence spike: the variables stored once on ReadingBook must still
        // be merged into the chapter before the production content and CoreText
        // reader pipelines run.
        var chapter = try #require(toc.chapters.first {
            $0.hasLoadableContentURL && !$0.shouldRenderAsVolumeSeparator
        })
        var mergedRuntime = persisted.runtimeVariables ?? [:]
        for (key, value) in chapter.runtimeVariables ?? [:] {
            mergedRuntime[key] = value
        }
        chapter.runtimeVariables = mergedRuntime

        let chapterBookID = UUID()
        defer { fetcher.clearAllChapterCache(bookId: chapterBookID) }
        let chapterPackage = try await fetcher.fetchChapterPackage(
            ref: chapter,
            bookId: chapterBookID,
            source: source,
            chapterReferer: toc.tocURL
        )
        let normalizedHTML = try #require(fetcher.loadNormalizedChapterHTMLSync(
            bookId: chapterBookID,
            chapterIndex: chapter.index,
            expectedSourceURL: chapter.url,
            expectedTOCTitle: chapter.title
        ))
        let provider = ShuqiFixedContentProvider(payload: ChapterContentPayload(
            index: 0,
            title: chapter.title,
            plainText: chapterPackage.content,
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
        let contentBytes = chapterPackage.content.lengthOfBytes(using: .utf8)
        print(
            "[ShuqiDiscoverDetail] firstChapter=\(chapter.title) "
                + "contentBytes=\(contentBytes) readerCharacters=\(rendered.attributedString.length) "
                + "readerPages=\(layout.pageRanges.count)"
        )
        #expect(contentBytes > 0)
        #expect(rendered.attributedString.length > 0)
        #expect(!layout.pageRanges.isEmpty)
    }
}

private func jsonStringLiteral(_ value: String) -> String? {
    guard let data = try? JSONSerialization.data(withJSONObject: [value]),
          let array = String(data: data, encoding: .utf8),
          array.count >= 2 else { return nil }
    return String(array.dropFirst().dropLast())
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
