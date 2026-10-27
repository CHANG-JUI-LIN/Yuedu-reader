import Foundation
import Testing
@testable import yuedu_app

/// Decisions 30 and 37: 專題集合, one card per list. Gutenberg's bundled lists are one section
/// of cards (精選書單), and a new install's home has that section in place of a row per list.
@Suite("專題集合 layout and 精選書單")
@MainActor
struct CollectionLayoutTests {
    private func lists() async throws -> [CollectionSummary] {
        let availability = PublicLibraryAvailability(defaults: UserDefaults(suiteName: "CollectionLayoutTests-\(UUID().uuidString)")!)
        var requests = 0
        let provider = GutenbergProvider(availability: availability) { _ in
            requests += 1
            return OPDSFeed()
        }
        let section = HomeSection(layout: .collection, binding: .gutenbergLists)
        #expect(provider.loadPolicy(for: section) == .local)
        let entries = try await provider.load(section)
        #expect(requests == 0, "the lists are bundled")
        return entries.compactMap { entry in
            if case .collection(let summary) = entry { return summary }
            return nil
        }
    }

    @Test("Gutenberg's lists, each with its first five books in order, opening the whole list")
    func gutenbergLists() async throws {
        let summaries = try await lists()
        #expect(summaries.map(\.id) == PublicLibraryCollection.all.map(\.id))
        for (summary, collection) in zip(summaries, PublicLibraryCollection.all) {
            #expect(summary.title == localized(collection.titleKey))
            #expect(summary.books.map(\.title) == collection.books.prefix(CollectionSummary.collageLimit).map(\.title))
            #expect(summary.bookCount == collection.books.count)
            #expect(summary.opening == .gutenbergCollection(id: collection.id))
        }
        // A Gutenberg cover is Gutenberg's own, as a list's row shows it.
        let first = try #require(summaries.first?.books.first)
        guard case .remote(let url, _) = first.cover else {
            Issue.record("Gutenberg's cover")
            return
        }
        #expect(url.absoluteString.contains("24264"))
    }

    @Test("a list goes by its best-placed book's language; none is left out")
    func languages() async throws {
        let entries = try await lists().map(CollectionEntry.collection)
        func ids(_ preferences: ReadingLanguagePreferences) -> [String] {
            preferences.arrange(entries).compactMap { entry in
                if case .collection(let summary) = entry { return summary.id }
                return nil
            }
        }
        // 小說與文學 holds 吶喊.
        #expect(Array(ids(ReadingLanguagePreferences(language: "zh-Hant")).prefix(3)) == ["chinese", "fiction", "thought"])
        #expect(ids(ReadingLanguagePreferences(language: "en")) == ["fiction", "children", "chinese", "thought"])
        #expect(ids(ReadingLanguagePreferences(language: "ja")) == PublicLibraryCollection.all.map(\.id))
    }

    @Test("A new install's home: one 精選書單 section in place of a row per list; none in China")
    func defaults() {
        for mode in [ExploreMode.publicLibraries, .bookSources] {
            let page = HomePageDefaults.page(mode: mode, publicLibrariesAvailable: true, languages: [])
            let lists = page.sections.filter { $0.binding == .gutenbergLists }
            #expect(lists.count == 1)
            // 分類卡片 since 2026-10-25, after Apple Books' More to Explore.
            #expect(lists.first?.layout == .categoryCards)
            #expect(!page.sections.contains { if case .gutenbergCollection = $0.binding { true } else { false } })
            #expect(lists.first?.displayTitle(sourceName: "") == localized("精選書單"))
        }
        let china = HomePageDefaults.page(mode: .bookSources, publicLibrariesAvailable: false, languages: [])
        #expect(!china.sections.contains { $0.binding == .gutenbergLists })
    }

    @Test("The section and its layout are written as their own values")
    func storedValues() throws {
        let section = HomeSection(layout: .collection, binding: .gutenbergLists)
        let data = try JSONEncoder().encode(section)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains(#""type":"gutenbergLists""#))
        #expect(json.contains(#""layout":"collection""#))
        let decoded = try JSONDecoder().decode(HomeSection.self, from: data)
        #expect(decoded == section)
        #expect(HomeSectionLayout.collection.isKnown)
        #expect(HomeSectionLayout.collection.style == .collection)
        #expect(HomeSectionLayout(style: .collection) == .collection)
        #expect(HomeSectionBinding.gutenbergLists.contentOwner == .gutenberg)
    }

    @Test("A list section offers the layouts of lists alone; a section of books every layout, its list a card")
    func choices() {
        #expect(HomeLayoutStyle.choices(for: .gutenbergLists) == [.collection, .categoryCards, .collageCards, .bannerCards, .chart])
        for binding: HomeSectionBinding in [.latest, .continueReading, .gutenbergCollection(id: "chinese"), .aozoraNew] {
            #expect(HomeLayoutStyle.choices(for: binding) == HomeLayoutStyle.allCases)
        }
    }

    @Test("分類卡片 and 拼貼卡片 are written as their own values; a section of books given one draws a row")
    func listLayoutValues() {
        for (layout, style) in [(HomeSectionLayout.categoryCards, HomeLayoutStyle.categoryCards), (.collageCards, .collageCards)] {
            #expect(layout.isKnown)
            #expect(layout.style == style)
            #expect(HomeSectionLayout(style: style) == layout)
            #expect(style.drawsLists)
        }
    }

    @Test("隱藏已讀 leaves the lists alone: a list is not a book")
    func readFilter() {
        let filter = HomeReadFilter(hides: true, isRead: { _ in true })
        #expect(!filter.hides(in: .gutenbergLists))
    }
}
