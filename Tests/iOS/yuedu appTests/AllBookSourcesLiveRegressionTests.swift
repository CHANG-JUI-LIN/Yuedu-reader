import Foundation
import Testing
@testable import yuedu_app

/// Opt-in, real-network regression over every Legado JSON in the local RULE corpus.
/// It deliberately records every source before failing so one broken endpoint cannot
/// hide regressions in the remaining sources.
@Suite("All Book Sources Live Regression", .serialized)
struct AllBookSourcesLiveRegressionTests {
    private static let isEnabled =
        ProcessInfo.processInfo.environment["RUN_ALL_SOURCE_LIVE_TESTS"] == "1"
            || ProcessInfo.processInfo.environment["TEST_RUNNER_RUN_ALL_SOURCE_LIVE_TESTS"] == "1"

    private static let defaultCorpusPath =
        "/Users/zhangruilin/Desktop/Test document/RULE"
    private static var reportPath: String {
        ProcessInfo.processInfo.environment["ALL_SOURCE_REPORT_PATH"]
            ?? ProcessInfo.processInfo.environment["TEST_RUNNER_ALL_SOURCE_REPORT_PATH"]
            ?? "/tmp/yuedu_all_sources_regression.json"
    }

    private struct Result: Codable {
        let file: String
        let index: Int
        let sourceName: String
        let sourceIdentifier: String
        let searchQuery: String
        let status: String
        let stage: String
        let detail: String
        let searchCount: Int?
        let discoverCategoryCount: Int?
        let discoverBookCount: Int?
        let chapterCount: Int?
        let contentLength: Int?
        let elapsedSeconds: Double
    }

    @Test(
        "every local source completes search, detail, toc, and first chapter",
        .enabled(if: isEnabled, "Set RUN_ALL_SOURCE_LIVE_TESTS=1 to run the real-network corpus"),
        .timeLimit(.minutes(60))
    )
    func allSources() async throws {
        let corpusPath = ProcessInfo.processInfo.environment["ALL_SOURCE_CORPUS_PATH"]
            ?? ProcessInfo.processInfo.environment["TEST_RUNNER_ALL_SOURCE_CORPUS_PATH"]
            ?? Self.defaultCorpusPath
        let corpusURL = URL(fileURLWithPath: corpusPath, isDirectory: true)
        let rawFileFilter = ProcessInfo.processInfo.environment["ALL_SOURCE_FILE_FILTER"]
            ?? ProcessInfo.processInfo.environment["TEST_RUNNER_ALL_SOURCE_FILE_FILTER"]
        let fileFilters = rawFileFilter?
            .split(separator: "|")
            .map(String.init) ?? []
        let rawNameFilter = ProcessInfo.processInfo.environment["ALL_SOURCE_NAME_FILTER"]
            ?? ProcessInfo.processInfo.environment["TEST_RUNNER_ALL_SOURCE_NAME_FILTER"]
        let nameFilters = rawNameFilter?
            .split(separator: "|")
            .map(String.init) ?? []
        let fileURLs = try FileManager.default.contentsOfDirectory(
            at: corpusURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { fileURL in
            fileURL.pathExtension.lowercased() == "json"
                && (fileFilters.isEmpty || fileFilters.contains {
                    fileURL.lastPathComponent.contains($0)
                })
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        var corpus: [(URL, Int, BookSource)] = []
        for fileURL in fileURLs {
            for (index, source) in try decodeSources(at: fileURL).enumerated() {
                if !nameFilters.isEmpty,
                   !nameFilters.contains(where: { source.bookSourceName.contains($0) }) {
                    continue
                }
                corpus.append((fileURL, index, source))
            }
        }
        #expect(!corpus.isEmpty)

        let fetcher = BookSourceFetcher.shared
        try? FileManager.default.removeItem(at: fetcher.bookInfoCacheDir())
        try? FileManager.default.removeItem(at: fetcher.tocCacheDir())

        var results: [Result] = []
        writeReport(
            results,
            corpusPath: corpusPath,
            expectedCount: corpus.count,
            currentFile: nil,
            currentSource: nil
        )

        for (offset, entry) in corpus.enumerated() {
            let started = Date()
            var source = entry.2
            source.id = UUID()
            source.lastUpdateTime = Int64(Date().timeIntervalSince1970 * 1_000) + Int64(offset)
            let prefix = "ALL_SOURCE_PROGRESS [\(offset + 1)/\(corpus.count)] \(source.bookSourceName)"
            print("\(prefix) START")
            writeReport(
                results,
                corpusPath: corpusPath,
                expectedCount: corpus.count,
                currentFile: entry.0.lastPathComponent,
                currentSource: source.bookSourceName
            )

            var searchCount: Int?
            var discoverCategoryCount: Int?
            var discoverBookCount: Int?
            var chapterCount: Int?
            var currentStage = "discover"
            var discoveredSearchSeed: String?
            var discoverFailure: String?
            var resolvedSearchQuery = ""
            do {
                if source.enabledExplore,
                   !source.exploreUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let items = await fetcher.discoverItems(in: source)
                    discoverCategoryCount = items.count
                    var discoveredBooks: [OnlineBook] = []
                    var attemptErrors: [String] = []
                    for item in items.filter({
                        !(($0.url ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }).prefix(3) {
                        do {
                            let books = try await fetcher.discoverBooks(from: item, in: source)
                            if discoveredBooks.isEmpty, !books.isEmpty {
                                discoveredBooks = books
                            }
                        } catch {
                            attemptErrors.append(String(error.localizedDescription.prefix(160)))
                        }
                    }
                    discoverBookCount = discoveredBooks.count
                    discoveredSearchSeed = discoveredBooks.first?.name
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if items.isEmpty {
                        discoverFailure = "no categories"
                    } else if discoveredBooks.isEmpty {
                        discoverFailure = attemptErrors.isEmpty
                            ? "categories returned no books"
                            : "categories returned no books: \(attemptErrors.joined(separator: " | "))"
                    }
                }

                currentStage = "search"
                var books: [OnlineBook] = []
                for query in searchQueries(for: source, discoveredSeed: discoveredSearchSeed) {
                    resolvedSearchQuery = query
                    books = try await fetcher.search(query: query, in: source)
                    searchCount = books.count
                    if books.contains(where: { !$0.bookUrl.isEmpty }) { break }
                }
                guard let book = books.first(where: { !$0.bookUrl.isEmpty }) else {
                    throw StageFailure(stage: "search", detail: "no usable result")
                }

                currentStage = "detail"
                var runtimeVariables = book.runtimeVariables
                let detail = try await fetcher.fetchBookInfoPackage(
                    url: book.bookUrl,
                    source: source,
                    runtimeVariables: runtimeVariables
                )
                runtimeVariables = detail.runtimeVariables
                let tocURL = detail.tocUrl.isEmpty ? book.bookUrl : detail.tocUrl

                currentStage = "toc"
                let toc = try await fetcher.fetchTOCPackage(
                    tocUrl: tocURL,
                    source: source,
                    runtimeVariables: runtimeVariables,
                    onFirstPageReady: nil,
                    forceRefresh: true
                )
                chapterCount = toc.chapters.count
                guard var chapter = toc.chapters.first(where: {
                    $0.hasLoadableContentURL && !$0.shouldRenderAsVolumeSeparator
                }) else {
                    throw StageFailure(stage: "toc", detail: "no loadable chapter")
                }

                if let bookRuntime = toc.runtimeVariables ?? runtimeVariables, !bookRuntime.isEmpty {
                    var merged = bookRuntime
                    for (key, value) in chapter.runtimeVariables ?? [:] {
                        merged[key] = value
                    }
                    chapter.runtimeVariables = merged
                }

                currentStage = "chapter"
                let package = try await fetcher.fetchChapterPackage(
                    ref: chapter,
                    bookId: UUID(),
                    source: source,
                    chapterReferer: tocURL
                )
                let contentLength = package.content
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .count
                guard contentLength > 0 else {
                    throw StageFailure(stage: "chapter", detail: "empty content")
                }

                if let discoverFailure {
                    throw StageFailure(stage: "discover", detail: discoverFailure)
                }

                results.append(makeResult(
                    fileURL: entry.0,
                    index: entry.1,
                    source: source,
                    searchQuery: resolvedSearchQuery,
                    status: "passed",
                    stage: "complete",
                    detail: "ok",
                    searchCount: searchCount,
                    discoverCategoryCount: discoverCategoryCount,
                    discoverBookCount: discoverBookCount,
                    chapterCount: chapterCount,
                    contentLength: contentLength,
                    started: started
                ))
                print(
                    "\(prefix) PASS query=\(resolvedSearchQuery) search=\(searchCount ?? 0) "
                        + "discover=\(discoverCategoryCount ?? 0)/\(discoverBookCount ?? 0) "
                        + "toc=\(chapterCount ?? 0) content=\(contentLength)"
                )
            } catch let failure as StageFailure {
                results.append(makeResult(
                    fileURL: entry.0,
                    index: entry.1,
                    source: source,
                    searchQuery: resolvedSearchQuery,
                    status: "failed",
                    stage: failure.stage,
                    detail: failure.detail,
                    searchCount: searchCount,
                    discoverCategoryCount: discoverCategoryCount,
                    discoverBookCount: discoverBookCount,
                    chapterCount: chapterCount,
                    contentLength: nil,
                    started: started
                ))
                print("\(prefix) FAIL stage=\(failure.stage) detail=\(failure.detail)")
            } catch {
                let stage = currentStage
                let detail = String(error.localizedDescription.prefix(400))
                results.append(makeResult(
                    fileURL: entry.0,
                    index: entry.1,
                    source: source,
                    searchQuery: resolvedSearchQuery,
                    status: "failed",
                    stage: stage,
                    detail: detail,
                    searchCount: searchCount,
                    discoverCategoryCount: discoverCategoryCount,
                    discoverBookCount: discoverBookCount,
                    chapterCount: chapterCount,
                    contentLength: nil,
                    started: started
                ))
                print("\(prefix) FAIL stage=\(stage) detail=\(detail)")
            }
            writeReport(
                results,
                corpusPath: corpusPath,
                expectedCount: corpus.count,
                currentFile: nil,
                currentSource: nil
            )
        }

        let failures = results.filter { $0.status != "passed" }
        print(
            "ALL_SOURCE_SUMMARY completed=\(results.count) "
                + "passed=\(results.count - failures.count) failed=\(failures.count) "
                + "report=\(Self.reportPath)"
        )
    }

    private struct StageFailure: Error {
        let stage: String
        let detail: String
    }

    private func decodeSources(at fileURL: URL) throws -> [BookSource] {
        var data = try Data(contentsOf: fileURL)
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            data.removeFirst(3)
        }
        if let sources = try? JSONDecoder().decode([BookSource].self, from: data) {
            return sources
        }
        return [try JSONDecoder().decode(BookSource.self, from: data)]
    }

    private func makeResult(
        fileURL: URL,
        index: Int,
        source: BookSource,
        searchQuery: String,
        status: String,
        stage: String,
        detail: String,
        searchCount: Int?,
        discoverCategoryCount: Int?,
        discoverBookCount: Int?,
        chapterCount: Int?,
        contentLength: Int?,
        started: Date
    ) -> Result {
        Result(
            file: fileURL.lastPathComponent,
            index: index,
            sourceName: source.bookSourceName,
            sourceIdentifier: redactedIdentifier(source.bookSourceUrl),
            searchQuery: searchQuery,
            status: status,
            stage: stage,
            detail: detail,
            searchCount: searchCount,
            discoverCategoryCount: discoverCategoryCount,
            discoverBookCount: discoverBookCount,
            chapterCount: chapterCount,
            contentLength: contentLength,
            elapsedSeconds: Date().timeIntervalSince(started)
        )
    }

    private func searchQueries(for source: BookSource, discoveredSeed: String?) -> [String] {
        let configured = source.ruleSearch.checkKeyWord
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates = [configured, discoveredSeed ?? ""]
        switch source.bookSourceType {
        case 1:
            candidates += ["诛仙", "斗罗大陆", "绝对之门"]
        case 2:
            candidates += ["斗破苍穹", "鬼灭之刃", "妖神记", "凤逆天下", "海贼王", "god"]
        default:
            candidates += ["斗罗大陆", "诛仙", "我的"]
        }
        var seen = Set<String>()
        return candidates.filter { query in
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return false }
            return true
        }
    }

    private func redactedIdentifier(_ value: String) -> String {
        guard var components = URLComponents(string: value), components.host != nil else {
            return String(value.prefix(160))
        }
        components.query = nil
        components.fragment = nil
        return String((components.string ?? value).prefix(160))
    }

    private func writeReport(
        _ results: [Result],
        corpusPath: String,
        expectedCount: Int,
        currentFile: String?,
        currentSource: String?
    ) {
        struct Report: Codable {
            let corpusPath: String
            let expectedCount: Int
            let completedCount: Int
            let passedCount: Int
            let failedCount: Int
            let currentFile: String?
            let currentSource: String?
            let results: [Result]
        }
        let report = Report(
            corpusPath: corpusPath,
            expectedCount: expectedCount,
            completedCount: results.count,
            passedCount: results.filter { $0.status == "passed" }.count,
            failedCount: results.filter { $0.status != "passed" }.count,
            currentFile: currentFile,
            currentSource: currentSource,
            results: results
        )
        guard let data = try? JSONEncoder().encode(report) else { return }
        try? data.write(to: URL(fileURLWithPath: Self.reportPath), options: .atomic)
    }
}
