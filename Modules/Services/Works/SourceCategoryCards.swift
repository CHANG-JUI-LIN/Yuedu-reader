import Foundation

// 分類卡片 of a 來源配置's section (maintainer, 2026-10-26), as Apple Books' More to Explore draws
// its categories (`Technotes/AppleBooksHomeLayouts-2026-10-25.md`): a card per category, its
// name beside the first covers of its first page. Since 2026-10-27 every layout of lists draws
// any source's lists (`HomeListCards.swift`), a 來源配置's categories among them:
// - The categories are the section's own, picked in its form, at most `HomeSection.listCardLimit`.
//   The home never lists the source's categories itself.
// - Each card's covers are its category's first page through the home's `DiscoverFirstPages`
//   (`BookSourceProvider`): one request per category in the home's life, the one a row of the
//   category and 為你推薦 make, one at a time per source.
// - A card opens its category's whole list, as a category row's 查看全部 does; the section's
//   header opens the source's own page (`ExplorePlace.listsPage`).
// - A section of one source's categories keeps its `.sourceCategories` binding whatever its
//   layout, so a build before 分類卡片 draws the first category's books.

extension HomeSection {
    /// The 來源配置 categories the section draws, which 為你推薦 mixes: each card's in a layout of
    /// lists, the first one's in a layout of books. The others stay for a layout of lists.
    var drawnCategories: [ExploreCategoryReference] {
        if drawsLists {
            return listCards.compactMap { card in
                if case .sourceCategories(let references) = card.binding { return references.first }
                return nil
            }
        }
        if case .sourceCategories(let references) = binding { return Array(references.prefix(1)) }
        return []
    }

    /// Every 來源配置 category the section keeps, drawn or not: 加入首頁配置 asks whether a page has one.
    var keptCategories: [ExploreCategoryReference] {
        switch binding {
        case .sourceCategories(let references):
            return references
        case .lists(let cards):
            return cards.flatMap { card -> [ExploreCategoryReference] in
                if case .sourceCategories(let references) = card.binding { return references }
                return []
            }
        default:
            return []
        }
    }
}
