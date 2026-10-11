import Foundation
import Testing
@testable import yuedu_app

/// Unified library 5d-3d: 偏好閱讀語言 and 推薦範圍 in 聚合設定 (Phase 5 plan, decision 21).
@MainActor
@Suite("Reading languages")
struct ReadingLanguagesTests {
    private func item(_ title: String, _ language: String?) -> CollectionEntry {
        let record = SourceRecord(key: SourceItemKey(instance: SourceInstanceKey(type: .opds, id: "c"), item: title),
                                  title: title, authors: [], language: language, contentKind: .text,
                                  identifiers: [], copyID: nil, acquisitions: [])
        return .item(record, WorkSummary(title: title, authors: [], cover: nil, blurb: nil, language: language,
                                         contentKind: .text), .copy(UUID()))
    }

    private func titles(_ entries: [CollectionEntry]) -> [String] {
        entries.compactMap { entry in
            if case .item(let record, _, _) = entry { return record.title }
            return nil
        }
    }

    @Test("before the reader chooses: the interface language alone, preferred")
    func initial() {
        #expect(ReadingLanguagePreferences.initial(interfaceLanguage: "zh-Hant")
                    == ReadingLanguagePreferences(languages: ["zh"], scope: .prefer))
        #expect(ReadingLanguagePreferences.initial(interfaceLanguage: nil).languages == ["en"])
        #expect(ReadingLanguage.base(of: "zh_Hant_TW") == "zh")
        #expect(ReadingLanguage.name(of: "ja") == "日本語")
        #expect(ReadingLanguage.name(of: "en") == "English")
    }

    @Test("優先: the preferred languages in order, then unknown, then the rest, each in the source's order")
    func prefer() {
        let entries = [item("en1", "en"), item("zh2", "zh-Hant"), item("none3", nil), item("ja4", "ja"), item("en5", "en-US"),
                       .location(CollectionLocation(id: "x", title: "place"))]
        let preferences = ReadingLanguagePreferences(languages: ["ja", "en"], scope: .prefer)
        #expect(titles(preferences.arrange(entries)) == ["ja4", "en1", "en5", "none3", "zh2"])
        #expect(preferences.arrange(entries).count == entries.count)
    }

    @Test("只推薦 leaves out books known to be in another language and keeps unknown ones; 不限制 changes nothing")
    func onlyAndAny() {
        let entries = [item("en1", "en"), item("zh2", "zh"), item("none3", nil), item("ja4", "ja")]
        #expect(titles(ReadingLanguagePreferences(languages: ["ja", "en"], scope: .only).arrange(entries))
                    == ["ja4", "en1", "none3"])
        #expect(titles(ReadingLanguagePreferences(languages: ["ja", "en"], scope: .any).arrange(entries))
                    == ["en1", "zh2", "none3", "ja4"])
    }

    @Test("a section's books are ordered after 最新's turns; 繼續閱讀 keeps its recency")
    func sectionsOrdered() {
        let latest = HomeSection(layout: .row, binding: .latest)
        let reading = HomeSection(layout: .compactReadingCard, binding: .continueReading)
        let a = SourceInstanceKey(type: .gutenberg, id: PublicLibraryID.gutenberg.rawValue)
        let b = SourceInstanceKey(type: .aozora, id: PublicLibraryID.aozora.rawValue)
        func row(_ section: HomeSection, _ source: SourceInstanceKey, _ entries: [CollectionEntry]) -> HomeModel.Row {
            HomeModel.Row(id: HomeModel.rowID(section: section.id, source: source), section: section, source: source,
                          sourceName: "", policy: .parallel, state: .loaded(entries))
        }
        let rows = [
            row(reading, .localLibrary, [item("shelf-en", "en"), item("shelf-ja", "ja")]),
            row(latest, a, [item("g-en1", "en"), item("g-en2", "en")]),
            row(latest, b, [item("a-ja1", "ja"), item("a-ja2", "ja")]),
        ]
        let groups = HomeScopeFilter.groups(rows, in: nil,
                                            languages: ReadingLanguagePreferences(languages: ["ja"], scope: .prefer))
        guard case .loaded(let shelf) = groups[0].state, case .loaded(let merged) = groups[1].state else {
            Issue.record("not loaded"); return
        }
        #expect(titles(shelf) == ["shelf-en", "shelf-ja"])
        #expect(titles(merged) == ["a-ja1", "a-ja2", "g-en1", "g-en2"])

        // Under 只推薦 a section left with nothing takes no room.
        let only = HomeScopeFilter.groups([row(latest, a, [item("g-en1", "en")])], in: nil,
                                          languages: ReadingLanguagePreferences(languages: ["ja"], scope: .only))
        #expect(only[0].isSettledEmpty)
    }

    @Test("every book of the bundled lists says its language; 青空 is Japanese")
    func bundledLanguages() {
        for collection in PublicLibraryCollection.all {
            for book in collection.books {
                #expect(book.language != nil, "\(book.title)")
                guard case .item(let record, let summary, _) = CollectionEntry.bundledGutenberg(book) else { continue }
                #expect(record.language == book.language)
                #expect(summary.language == book.language)
            }
        }
        #expect(PublicLibraryCollection.fiction.books.map(\.language) == ["en", "en", "en", "zh"])
    }

    @Test("the store keeps nothing until the reader chooses, then reads back what it saved")
    func store() {
        let suite = "ReadingLanguagesTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AggregationSettingsStore(defaults: defaults)
        #expect(store.settings.readingLanguages == nil)
        #expect(defaults.data(forKey: "yd_aggregation_settings") == nil)

        let chosen = ReadingLanguagePreferences(languages: ["en", "ja"], scope: .only)
        store.setReadingLanguages(chosen)
        #expect(store.readingLanguages == chosen)
        #expect(AggregationSettingsStore(defaults: defaults).readingLanguages == chosen)
    }
}
