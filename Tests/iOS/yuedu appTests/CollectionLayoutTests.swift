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

    @Test("Gutenberg's lists, each with its first three books in order, opening the whole list")
    func gutenbergLists() async throws {
        let summaries = try await lists()
        #expect(summaries.map(\.id) == PublicLibraryCollection.all.map(\.id))
        for (summary, collection) in zip(summaries, PublicLibraryCollection.all) {
            #expect(summary.title == localized(collection.titleKey))
            #expect(summary.books.map(\.title) == collection.books.prefix(CollectionSummary.artworkLimit).map(\.title))
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

    @Test("只推薦偏好語言 leaves out a list with no book in a preferred language; a mixed list stays")
    func languages() async throws {
        let entries = try await lists().map(CollectionEntry.collection)
        func ids(_ preferences: ReadingLanguagePreferences) -> [String] {
            preferences.arrange(entries).compactMap { entry in
                if case .collection(let summary) = entry { return summary.id }
                return nil
            }
        }
        // 小說與文學 holds 吶喊.
        #expect(ids(ReadingLanguagePreferences(languages: ["zh"], scope: .only)) == ["chinese", "fiction", "thought"])
        #expect(ids(ReadingLanguagePreferences(languages: ["en"], scope: .prefer)) == ["fiction", "children", "chinese", "thought"])
        #expect(ids(ReadingLanguagePreferences(languages: ["ja"], scope: .only)).isEmpty)
        #expect(ids(ReadingLanguagePreferences(languages: ["ja"], scope: .any)) == PublicLibraryCollection.all.map(\.id))
    }

    @Test("A new install's home: one 精選書單 section in place of a row per list; none in China")
    func defaults() {
        for mode in [ExploreMode.publicLibraries, .bookSources] {
            let page = HomePageDefaults.page(mode: mode, publicLibrariesAvailable: true, languages: [])
            let lists = page.sections.filter { $0.binding == .gutenbergLists }
            #expect(lists.count == 1)
            #expect(lists.first?.layout == .collection)
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

    @Test("A list section offers 專題集合 alone; a section of books never offers it")
    func choices() {
        #expect(HomeLayoutStyle.choices(for: .gutenbergLists) == [.collection])
        for binding: HomeSectionBinding in [.latest, .continueReading, .gutenbergCollection(id: "chinese"), .aozoraNew] {
            let choices = HomeLayoutStyle.choices(for: binding)
            #expect(!choices.contains(.collection))
            #expect(choices.contains(.featured))
        }
    }

    @Test("隱藏已讀 leaves the lists alone: a list is not a book")
    func readFilter() {
        let filter = HomeReadFilter(hides: true, isRead: { _ in true })
        #expect(!filter.hides(in: .gutenbergLists))
    }
}
