import Foundation
import Testing
@testable import yuedu_app

/// A book-source row's books made into entries (`BookSourceProvider.entries`).
///
/// 3.0.2 (151) MetricKit hang, 1.66 s on the main thread (Crashlytics
/// b47a5837421c76188d8367875e3194a6): each book of a row inferred its kind through
/// `OnlineBook.inferredContentKind(source:)`, which reads the source's whole variable JSON out
/// of its defaults and parses it — 20 times a row for the same source, 25 of 34 samples inside
/// Foundation's JSON decoding. The row reads the source's mode markers once.
@MainActor
@Suite("Book source row entries", .serialized)
struct BookSourceRowEntriesTests {
    private final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func add() { lock.withLock { value += 1 } }
    }

    private func source(_ url: String = "https://row-entries.test") -> BookSource {
        var source = BookSource()
        source.bookSourceName = "列測試源"
        source.bookSourceUrl = url
        return source
    }

    private func books(_ count: Int, in source: BookSource) -> [OnlineBook] {
        (0..<count).map { index in
            OnlineBook(name: "書\(index)", author: "作者甲", intro: "<p>第 \(index) 本的簡介，寫得不長也不短。</p>", coverUrl: "/c/\(index).jpg",
                       bookUrl: "\(source.bookSourceUrl)/book/\(index)", tocUrl: "", wordCount: "", lastChapter: "第十章",
                       kind: "玄幻,連載", sourceId: source.id, sourceName: source.bookSourceName)
        }
    }

    private func section(_ source: BookSource) -> HomeSection {
        HomeSection(layout: .row, binding: .sourceCategories([
            ExploreCategoryReference(sourceURL: source.bookSourceUrl, title: "熱門", url: "/hot/{{page}}"),
        ]))
    }

    @Test("a row of 20 books reads its source's mode markers once")
    func readsMarkersOnceARow() async throws {
        let source = source()
        let page = books(HomeRow.limit, in: source)
        let reads = Reads()
        let provider = BookSourceProvider(
            source: source,
            pageLoader: SectionPageLoader { _, _, _ in page },
            primeCookies: { _ in },
            modeMarkers: { _ in reads.add(); return [] }
        )

        let entries = try await provider.load(section(source))
        #expect(entries.count == HomeRow.limit)
        #expect(reads.count == 1)
    }

    @Test("the markers are read after the page answered, and decide each book's kind")
    func markersDecideTheKind() async throws {
        let source = source("https://row-entries-audio.test/\(UUID().uuidString)")
        let store = BookSourceRuntimeStateStore.shared
        defer { store.setSourceVariableJSON(nil, for: source.bookSourceUrl) }
        let page = books(3, in: source).map { book in
            // No marker of its own: the source's mode is all that says what it is.
            OnlineBook(name: book.name, author: book.author, intro: "", coverUrl: "", bookUrl: book.bookUrl, tocUrl: "",
                       wordCount: "", lastChapter: "", kind: "", sourceId: source.id, sourceName: "S")
        }
        let provider = BookSourceProvider(
            source: source,
            // The source's script sets its mode while the page loads (`source.setVariable`).
            pageLoader: SectionPageLoader { _, _, _ in
                store.setSourceVariableJSON(#"{"发现页类型":"听书"}"#, for: source.bookSourceUrl)
                return page
            },
            primeCookies: { _ in }
        )

        let entries = try await provider.load(section(source))
        let kinds = entries.compactMap { entry -> ContentKind? in
            guard case .item(let record, _, _) = entry else { return nil }
            return record.contentKind
        }
        #expect(kinds == Array(repeating: ContentKind(OnlineBookContentKind.audio), count: 3))
    }

    /// Main-thread CPU for a row of 20 with a source whose variables are about 300 KB, as an
    /// aggregate source's are: a book at a time (what the row did), the row as it is made now,
    /// and one read of the markers. Prints one `HOMEROWENTRIES …` line; simulator numbers.
    @Test("a row's entries cost one read of a large source's variables, not one a book")
    func rowCostWithLargeVariables() {
        let source = source("https://row-entries-large.test/\(UUID().uuidString)")
        let store = BookSourceRuntimeStateStore.shared
        defer { store.setSourceVariableJSON(nil, for: source.bookSourceUrl) }
        var variables: [String: Any] = ["发现页类型": "小说", "搜索模式": "小说"]
        for index in 0..<1500 {
            variables["设置\(index)"] = String(repeating: "分類與排序的選項\(index)，", count: 6)
        }
        let json = String(decoding: try! JSONSerialization.data(withJSONObject: variables), as: UTF8.self)
        store.setSourceVariableJSON(json, for: source.bookSourceUrl)

        let page = books(HomeRow.limit, in: source)
        let provider = BookSourceProvider(source: source, pageLoader: SectionPageLoader { _, _, _ in [] }, primeCookies: { _ in })

        func cpuMs(_ work: () -> Void) -> Double {
            (0..<5).map { _ in
                let start = SourcePerfTrace.threadCPU
                work()
                return (SourcePerfTrace.threadCPU - start) * 1000
            }.min() ?? 0
        }
        let perBook = cpuMs { _ = page.map { CollectionEntry.onlineBook($0, source: source) } }
        let row = cpuMs { _ = provider.entries(page) }
        let oneRead = cpuMs { _ = OnlineBookContentInference.sourceRuntimeModeMarkers(for: source) }
        print(String(format: "HOMEROWENTRIES books=%d variables=%dB perBook=%.1fms row=%.1fms oneRead=%.1fms",
                     page.count, json.utf8.count, perBook, row, oneRead))

        #expect(provider.entries(page) == page.map { CollectionEntry.onlineBook($0, source: source) })
        // Twenty reads against one: the row costs well under half of a book at a time.
        #expect(row < perBook / 2)
    }
}
