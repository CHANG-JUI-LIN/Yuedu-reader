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

    @Test("one switch leaves read books out of the whole home but 繼續閱讀 (decision 36)")
    func filtered() {
        let gutenberg = SourceInstanceKey(type: .gutenberg, id: PublicLibraryID.gutenberg.rawValue)
        let books = [GutenbergBook(id: 1342, title: "read", author: ""), GutenbergBook(id: 84, title: "unread", author: "")]
        let entries = books.map(CollectionEntry.bundledGutenberg)
        let sections = [HomeSection(layout: .row, binding: .latest), HomeSection(layout: .row, binding: .related),
                        HomeSection(layout: .row, binding: .gutenbergCollection(id: "x")),
                        HomeSection(layout: .row, binding: .continueReading)]
        let rows = sections.map { section in
            HomeModel.Row(id: HomeModel.rowID(section: section.id, source: gutenberg), section: section, source: gutenberg,
                          sourceName: "", policy: .local, state: .loaded(entries))
        }
        let isRead: (CollectionEntry) -> Bool = { entry in
            if case .item(let record, _, _) = entry { return record.title == "read" }
            return false
        }
        func shown(hides: Bool) -> [[String]] {
            HomeScopeFilter.groups(rows, in: nil, readFilter: HomeReadFilter(hides: hides, isRead: isRead))
                .map { group in
                    guard case .loaded(let loaded) = group.state else { return [] }
                    return titles(loaded)
                }
        }
        #expect(shown(hides: true) == [["unread"], ["unread"], ["unread"], ["read", "unread"]])
        #expect(shown(hides: false) == [["read", "unread"], ["read", "unread"], ["read", "unread"], ["read", "unread"]])
        // An article's read state is the RSS tab's, not this switch's.
        #expect(!HomeReadFilter(hides: true, isRead: isRead).hides(in: .subscriptionArticles))
        #expect(!HomeReadFilter(hides: true, isRead: isRead).hides(in: .nextInSeries))
    }

    private func store(_ stored: AggregationSettings?) throws -> (AggregationSettingsStore, UserDefaults, String) {
        let suite = "HideReadTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        if let stored { defaults.set(try JSONEncoder().encode(stored), forKey: AggregationSettingsStore.defaultsKey) }
        return (AggregationSettingsStore(defaults: defaults), defaults, suite)
    }

    @Test("the switch starts on, and either old switch off starts it off")
    func migration() throws {
        for (stored, expected) in [(nil, true), (AggregationSettings(), true),
                                   (AggregationSettings(hidesReadInLatest: false), false),
                                   (AggregationSettings(hidesReadInRelated: false), false),
                                   (AggregationSettings(hidesReadInLatest: true, hidesReadInRelated: true), true)] as [(AggregationSettings?, Bool)] {
            let (store, defaults, suite) = try store(stored)
            defer { defaults.removePersistentDomain(forName: suite) }
            #expect(store.hidesRead == expected)
        }
    }

    @Test("the new switch is saved and wins; the old values stay stored")
    func saved() throws {
        let (store, defaults, suite) = try store(AggregationSettings(hidesReadInLatest: false))
        defer { defaults.removePersistentDomain(forName: suite) }
        store.setHidesRead(true)
        let reread = AggregationSettingsStore(defaults: defaults)
        #expect(reread.hidesRead)
        let data = try #require(defaults.data(forKey: AggregationSettingsStore.defaultsKey))
        let raw = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(raw["hidesReadInLatest"] as? Bool == false, "an older build still reads its own value")
    }
}
