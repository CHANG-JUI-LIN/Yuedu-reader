import Foundation
import Testing
@testable import yuedu_app

/// Unified library 5d-3g: 隱藏已讀 in 聚合設定 (Phase 5 plan, decision 21).
@MainActor
@Suite("Hide read")
struct HideReadTests {
    private let context = SourceRecordContext(bookSourceURL: { _ in nil }, connectionKind: { _ in nil }, webDAVRoot: { _ in nil })

    private func gutenbergCopy(_ id: Int, position: Double) -> ReadingBook {
        var book = ReadingBook(title: "Remote", author: "A", source: "local", contentFilename: "\(UUID().uuidString).epub")
        book.remoteSource = RemoteBookReference(
            connectionID: PublicLibraryID.gutenberg.rawValue, entryID: "https://www.gutenberg.org/ebooks/\(id).opds",
            format: RemoteLibraryFormat(url: URL(string: "https://example.com/book.epub")!, fileExtension: "epub",
                                        mimeType: "application/epub+zip"),
            offlineFilename: nil)
        book.currentPosition = position
        return book
    }

    private func titles(_ entries: [CollectionEntry]) -> [String] {
        entries.compactMap { entry in
            if case .item(let record, _, _) = entry { return record.title }
            return nil
        }
    }

    @Test("a book is read when a copy of it was read to the end, whichever copy the card stands for")
    func isRead() {
        let finished = gutenbergCopy(1342, position: 1)
        let reading = gutenbergCopy(84, position: 0.5)
        var shelfFinished = ReadingBook(title: "讀完", author: "", source: "local_epub", contentFilename: "a.epub")
        shelfFinished.currentPosition = 0.995
        let lookup = CopyLookup(books: [finished, reading, shelfFinished], context: context)

        #expect(lookup.isRead(.bundledGutenberg(GutenbergBook(id: 1342, title: "Pride and Prejudice", author: "Jane Austen"))))
        #expect(!lookup.isRead(.bundledGutenberg(GutenbergBook(id: 84, title: "Frankenstein", author: "Mary Shelley"))))
        #expect(!lookup.isRead(.bundledGutenberg(GutenbergBook(id: 11, title: "Alice", author: "Lewis Carroll"))))
        let record = SourceRecord.derived(from: shelfFinished, context: context)
        let summary = WorkSummary(title: "讀完", authors: [], cover: nil, blurb: nil, language: nil, contentKind: .text)
        #expect(lookup.isRead(.item(record, summary, .copy(shelfFinished.id))))
        #expect(!lookup.isRead(.location(CollectionLocation(id: "x", title: "place"))))
    }

    @Test("最新 and 相關 leave read books out, each by its own switch; other sections keep them")
    func filtered() {
        let gutenberg = SourceInstanceKey(type: .gutenberg, id: PublicLibraryID.gutenberg.rawValue)
        let books = [GutenbergBook(id: 1342, title: "read", author: ""), GutenbergBook(id: 84, title: "unread", author: "")]
        let entries = books.map(CollectionEntry.bundledGutenberg)
        let sections = [HomeSection(layout: .row, binding: .latest), HomeSection(layout: .row, binding: .related),
                        HomeSection(layout: .row, binding: .gutenbergCollection(id: "x"))]
        let rows = sections.map { section in
            HomeModel.Row(id: HomeModel.rowID(section: section.id, source: gutenberg), section: section, source: gutenberg,
                          sourceName: "", policy: .local, state: .loaded(entries))
        }
        let isRead: (CollectionEntry) -> Bool = { entry in
            if case .item(let record, _, _) = entry { return record.title == "read" }
            return false
        }
        func shown(latest: Bool, related: Bool) -> [[String]] {
            HomeScopeFilter.groups(rows, in: nil,
                                   readFilter: HomeReadFilter(hidesInLatest: latest, hidesInRelated: related, isRead: isRead))
                .map { group in
                    guard case .loaded(let loaded) = group.state else { return [] }
                    return titles(loaded)
                }
        }
        #expect(shown(latest: true, related: true) == [["unread"], ["unread"], ["read", "unread"]])
        #expect(shown(latest: false, related: true) == [["read", "unread"], ["unread"], ["read", "unread"]])
        #expect(shown(latest: true, related: false) == [["unread"], ["read", "unread"], ["read", "unread"]])
    }

    @Test("both switches start on, and are saved")
    func store() {
        let suite = "HideReadTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AggregationSettingsStore(defaults: defaults)
        #expect(store.hidesReadInLatest && store.hidesReadInRelated)
        store.setHidesReadInRelated(false)
        let reread = AggregationSettingsStore(defaults: defaults)
        #expect(reread.hidesReadInLatest)
        #expect(!reread.hidesReadInRelated)
    }
}
