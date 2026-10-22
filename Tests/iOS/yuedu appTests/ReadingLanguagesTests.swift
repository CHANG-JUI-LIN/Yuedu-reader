import Foundation
import Testing
@testable import yuedu_app

/// 中繼資料語言偏好推薦 in 聚合設定 (maintainer, 2026-10-21), which replaced 偏好閱讀語言 and 推薦範圍
/// (Unified library 5d-3d, Phase 5 plan, decision 21).
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

    @Test("before the reader picks: 跟隨 App 語言, Chinese with the app's script")
    func followsApp() {
        let none = AggregationSettings()
        #expect(none.metadataLanguageChoice(interfaceLanguage: "zh-Hant") == MetadataLanguage.followApp)
        #expect(none.languages(interfaceLanguage: "zh-Hant") == ReadingLanguagePreferences(language: "zh-Hant"))
        #expect(none.languages(interfaceLanguage: "zh-Hans").language == "zh-Hans")
        #expect(none.languages(interfaceLanguage: "ja").language == "ja")
        #expect(none.languages(interfaceLanguage: nil).language == "en")
        #expect(none.languages(interfaceLanguage: "zh-Hant").languages == ["zh"])
        #expect(ReadingLanguage.base(of: "zh_Hant_TW") == "zh")
    }

    @Test("the menu: 跟隨 App 語言 first, then Chinese in each script, each in its own language")
    func menu() {
        #expect(MetadataLanguage.choices.prefix(3) == [MetadataLanguage.followApp, "zh-Hant", "zh-Hans"])
        #expect(MetadataLanguage.name(of: MetadataLanguage.followApp) == localized("跟隨 App 語言"))
        #expect(MetadataLanguage.name(of: "zh-Hant") == "繁體中文")
        #expect(MetadataLanguage.name(of: "zh-Hans") == "简体中文")
        #expect(MetadataLanguage.name(of: "ja") == "日本語")
        #expect(MetadataLanguage.name(of: "en") == "English")
        #expect(ReadingLanguage.name(of: "zh") == "中文", "Gutenberg's shelves keep the base name")
    }

    @Test("優先推薦: the language's books, then unknown, then the rest, each in the source's order; none left out")
    func prefer() {
        let entries = [item("en1", "en"), item("zh2", "zh-Hant"), item("none3", nil), item("ja4", "ja"), item("en5", "en-US"),
                       .location(CollectionLocation(id: "x", title: "place"))]
        let preferences = ReadingLanguagePreferences(language: "ja")
        #expect(titles(preferences.arrange(entries)) == ["ja4", "none3", "en1", "zh2", "en5"])
        #expect(preferences.arrange(entries).count == entries.count)
        #expect(titles(ReadingLanguagePreferences(language: "zh-Hans").arrange(entries)).first == "zh2",
                "a script matches any Chinese book")
    }

    @Test("偏好閱讀語言's first language is the choice until the reader picks one")
    func migrates() {
        func choice(_ languages: [String], app: String) -> String? {
            MetadataLanguage.choice(migrating: LegacyReadingLanguages(languages: languages, scope: "only"),
                                    interfaceLanguage: app)
        }
        #expect(choice(["ja", "en"], app: "zh-Hant") == "ja")
        #expect(choice(["zh", "ja"], app: "zh-Hans") == MetadataLanguage.followApp, "the app's language is following it")
        #expect(choice(["zh"], app: "en") == "zh-Hant", "no script saved: Traditional, the app's source language")
        #expect(MetadataLanguage.choice(migrating: nil, interfaceLanguage: "en") == nil)

        let legacy = AggregationSettings(readingLanguages: LegacyReadingLanguages(languages: ["ja"], scope: "any"))
        #expect(legacy.languages(interfaceLanguage: "zh-Hant").language == "ja")
        var picked = legacy
        picked.metadataLanguage = MetadataLanguage.followApp
        #expect(picked.languages(interfaceLanguage: "zh-Hant").language == "zh-Hant", "跟隨 App 語言, picked, wins")
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
        let groups = HomeScopeFilter.groups(rows, in: nil, languages: ReadingLanguagePreferences(language: "ja"))
        guard case .loaded(let shelf) = groups[0].state, case .loaded(let merged) = groups[1].state else {
            Issue.record("not loaded"); return
        }
        #expect(titles(shelf) == ["shelf-en", "shelf-ja"])
        #expect(titles(merged) == ["a-ja1", "a-ja2", "g-en1", "g-en2"])
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

    @Test("the store keeps nothing until the reader picks, then reads back what it saved")
    func store() {
        let suite = "ReadingLanguagesTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AggregationSettingsStore(defaults: defaults)
        #expect(store.settings.metadataLanguage == nil)
        #expect(store.metadataLanguageChoice == MetadataLanguage.followApp)
        #expect(defaults.data(forKey: "yd_aggregation_settings") == nil)

        store.setMetadataLanguage("ja")
        #expect(store.readingLanguages == ReadingLanguagePreferences(language: "ja"))
        let reread = AggregationSettingsStore(defaults: defaults)
        #expect(reread.metadataLanguageChoice == "ja")
        #expect(reread.readingLanguages.language == "ja")
    }
}
