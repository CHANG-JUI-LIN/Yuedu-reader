import Foundation
import Testing
@testable import yuedu_app

@Suite("Fanqie Sauce source compatibility", .serialized)
struct FanqieSauceSourceTests {

    private static let sourceName = "🌙 番茄酱"
    private static let defaultJSONPath =
        "/Users/zhangruilin/Desktop/Test document/RULE/🌙 番茄酱.json"

    private enum FixtureError: LocalizedError {
        case unexpectedSource(String)
        case sourceNotFound

        var errorDescription: String? {
            switch self {
            case .unexpectedSource(let actualName):
                return "Expected \(sourceName) fixture, found \(actualName)."
            case .sourceNotFound:
                return "The fixture does not contain the \(sourceName) source."
            }
        }
    }

    private static func environmentValue(for key: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[key]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else { return nil }
        return value
    }

    static var jsonPath: String {
        environmentValue(for: "FANQIE_SAUCE_SOURCE_JSON")
            ?? environmentValue(for: "TEST_RUNNER_FANQIE_SAUCE_SOURCE_JSON")
            ?? defaultJSONPath
    }

    static var runLiveTests: Bool {
        if let primary = environmentValue(for: "RUN_LIVE_FANQIE_SAUCE_TESTS") {
            return primary == "1"
        }
        return environmentValue(for: "TEST_RUNNER_RUN_LIVE_FANQIE_SAUCE_TESTS") == "1"
    }

    private func loadSource() throws -> BookSource? {
        guard FileManager.default.fileExists(atPath: Self.jsonPath) else { return nil }
        let data = try Data(contentsOf: URL(fileURLWithPath: Self.jsonPath))
        if let source = try? JSONDecoder().decode(BookSource.self, from: data) {
            guard source.bookSourceName == Self.sourceName else {
                throw FixtureError.unexpectedSource(source.bookSourceName)
            }
            return source
        }
        let sources = try JSONDecoder().decode([BookSource].self, from: data)
        guard let source = sources.first(where: { $0.bookSourceName == Self.sourceName }) else {
            throw FixtureError.sourceNotFound
        }
        return source
    }

    @Test("provided source buildRequest emits authorization")
    func buildRequestEmitsAuthorization() throws {
        guard let source = try loadSource() else { return }
        let engine = JSCoreEngine()
        engine.bookSource = source
        _ = engine.evaluate(source.jsLib, bindings: ["baseUrl": source.bookSourceUrl])
        #expect(engine.lastError == nil)
        #expect(engine.evaluate("typeof buildRequest") == "function")

        let result = engine.evaluate(
            """
            (function () {
                const value = buildRequest(
                    backend + '/fq/detail?book_id=7045187140329671720'
                );
                const serialized = typeof value === 'string' ? value : JSON.stringify(value);
                return typeof serialized === 'string'
                    && /"Authorization"\\s*:\\s*"[^"]+"/.test(serialized);
            })()
            """
        )
        #expect(result == "true")
        #expect(engine.lastError == nil)
    }

    @Test("live source completes the basic reading flow")
    func liveBasicReadingFlow() async throws {
        guard Self.runLiveTests, var source = try loadSource() else { return }
        let fetcher = BookSourceFetcher.shared
        let searchQuery = "重生医妃一睁眼，全京城排队抢亲"

        // Book-info and TOC cache keys include source.id. A fresh ID keeps this
        // opt-in live test from replaying a package persisted by an earlier run.
        source.id = UUID()
        SearchResultCache.shared.clear(query: searchQuery, source: source)
        defer { SearchResultCache.shared.clear(query: searchQuery, source: source) }

        let books = try await fetcher.search(
            query: searchQuery,
            in: source
        )
        let book = try #require(
            books.first { $0.name.contains("重生医妃一睁眼") }
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
            runtimeVariables: info.runtimeVariables,
            onFirstPageReady: nil,
            forceRefresh: true
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
