import Foundation

// 分類卡片 of a 來源配置's section (maintainer, 2026-10-26), as Apple Books' More to Explore draws
// its categories (`Technotes/AppleBooksHomeLayouts-2026-10-25.md`): a card per category, its
// name beside the first covers of its first page.
// - The categories are the section's own, ticked in its form, at most `categoryCardLimit`. The
//   home never lists the source's categories itself.
// - Each card's covers are its category's first page through the home's `DiscoverFirstPages`
//   (`BookSourceProvider`): one request per category in the home's life, the one a row of the
//   category and 為你推薦 make, one at a time per source.
// - A card opens its category's whole list, as a category row's 查看全部 does; the section's
//   header opens the source's own page (`ExplorePlace`).
// - A section keeps one binding whatever its layout, so a build before 分類卡片 draws the first
//   category's books.

extension HomeSection {
    /// The most cards a section draws (maintainer, 2026-10-26): a source's pages come one at a
    /// time, and the section shows once they all have.
    static let categoryCardLimit = 8

    /// A 來源配置's section drawn as 分類卡片: a card per category, not the first one's books.
    var drawsCategoryCards: Bool {
        guard case .sourceCategories = binding else { return false }
        return layout.style == .categoryCards
    }

    /// The book-source categories the section shows: under 分類卡片 each it keeps, up to the
    /// limit; else the first, whose books it draws. The others stay for 分類卡片, and nothing
    /// reads them meanwhile (為你推薦 mixes only these).
    var shownCategories: [ExploreCategoryReference] {
        guard case .sourceCategories(let references) = binding else { return [] }
        return Array(references.prefix(drawsCategoryCards ? Self.categoryCardLimit : 1))
    }
}

extension CollectionSummary {
    /// A book source's category as a card of 分類卡片: its name and its first page's first
    /// books. `bookCount` counts those alone, which no layout of a category shows.
    static func sourceCategory(_ category: ExploreCategoryReference, firstPage books: [OnlineBook],
                               source: BookSource) -> CollectionSummary {
        let summaries = books.prefix(artworkLimit).compactMap { book -> WorkSummary? in
            guard case .item(_, let summary, _) = CollectionEntry.onlineBook(book, source: source) else { return nil }
            return summary
        }
        return CollectionSummary(id: category.id, title: category.title, books: summaries, languages: [],
                                 opening: .sourceCategory(category))
    }
}
