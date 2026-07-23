import Foundation
import Testing
@testable import yuedu_app

@Suite("Fanqie Sauce source compatibility", .serialized)
struct FanqieSauceSourceTests {

    static var jsonPath: String {
        ProcessInfo.processInfo.environment["FANQIE_SAUCE_SOURCE_JSON"]
            ?? ProcessInfo.processInfo.environment["TEST_RUNNER_FANQIE_SAUCE_SOURCE_JSON"]
            ?? "/Users/zhangruilin/Desktop/Test document/RULE/🌙 番茄酱.json"
    }

    static var runLiveTests: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["RUN_LIVE_FANQIE_SAUCE_TESTS"] == "1"
            || env["TEST_RUNNER_RUN_LIVE_FANQIE_SAUCE_TESTS"] == "1"
    }

    private func loadSource() throws -> BookSource? {
        guard FileManager.default.fileExists(atPath: Self.jsonPath) else { return nil }
        let data = try Data(contentsOf: URL(fileURLWithPath: Self.jsonPath))
        if let source = try? JSONDecoder().decode(BookSource.self, from: data) { return source }
        return try JSONDecoder().decode([BookSource].self, from: data)
            .first { $0.bookSourceName == "🌙 番茄酱" }
    }

    @Test("provided source buildRequest emits authorization")
    func buildRequestEmitsAuthorization() throws {
        guard let source = try loadSource() else { return }
        let engine = JSCoreEngine()
        engine.bookSource = source
        _ = engine.evaluate(source.jsLib, bindings: ["baseUrl": source.bookSourceUrl])
        #expect(engine.lastError == nil)
        #expect(engine.evaluate("typeof buildRequest") == "function")

        let request = try #require(engine.evaluate(
            """
            (function () {
                const value = buildRequest(
                    backend + '/fq/detail?book_id=7045187140329671720'
                );
                return typeof value === 'string' ? value : JSON.stringify(value);
            })()
            """
        ))
        let authorizationPattern = try NSRegularExpression(
            pattern: #""Authorization"\s*:\s*"[^"]+""#
        )
        let range = NSRange(request.startIndex..., in: request)
        #expect(authorizationPattern.firstMatch(in: request, range: range) != nil)
        #expect(engine.lastError == nil)
    }

    @Test("live source completes the basic reading flow")
    func liveBasicReadingFlow() async throws {
        guard Self.runLiveTests, let source = try loadSource() else { return }
        let fetcher = BookSourceFetcher.shared

        let books = try await fetcher.search(
            query: "重生医妃一睁眼，全京城排队抢亲",
            in: source
        )
        let book = try #require(
            books.first { $0.name.contains("重生医妃一睁眼") } ?? books.first
        )
        let info = try await fetcher.fetchBookInfoPackage(
            url: book.bookUrl,
            source: source,
            runtimeVariables: book.runtimeVariables
        )
        #expect(info.name.contains("重生医妃一睁眼"))

        let tocURL = info.tocUrl.isEmpty ? book.bookUrl : info.tocUrl
        let toc = try await fetcher.fetchTOCPackage(
            tocUrl: tocURL,
            source: source,
            runtimeVariables: info.runtimeVariables
        )
        let chapter = try #require(
            toc.chapters.first {
                $0.hasLoadableContentURL && !$0.shouldRenderAsVolumeSeparator
            }
        )
        #expect(chapter.title.contains("第1章"))

        let bookID = UUID()
        defer { fetcher.clearAllChapterCache(bookId: bookID) }
        let package = try await fetcher.fetchChapterPackage(
            ref: chapter,
            bookId: bookID,
            source: source,
            chapterReferer: tocURL
        )
        #expect(!package.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(!package.content.contains("请求失败"))
        #expect(!package.content.contains("undefined is not an object"))
    }
}
