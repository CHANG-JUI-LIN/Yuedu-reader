import Foundation

// Unified library 5d-3g: 隱藏已讀 (Phase 5 plan, decision 21), one switch since decision 36,
// as Emby's "Hide fully played content". The home's sections of books, all but 繼續閱讀, leave
// out a book read to the end on this device, by any copy of it: read to the end, or 標記為已讀完
// (progress 1). The test is the one the shelf uses for 已讀完.

/// Which sections hide read books, and how to tell one.
struct HomeReadFilter {
    /// 聚合設定's 隱藏已讀.
    var hides: Bool
    /// Whether an entry's book was read to the end.
    let isRead: (CollectionEntry) -> Bool

    /// Every section of books but 繼續閱讀, as Emby's "Hide fully played content" (decision 36).
    func hides(in binding: HomeSectionBinding) -> Bool {
        guard hides else { return false }
        switch binding {
        case .latest, .related, .sourceCategories, .opdsFeed, .gutenbergCollection, .gutenbergFeed,
             .gutenbergShelf, .aozoraNew:
            return true
        // 繼續閱讀 is what is being read. 系列下一本 never offers a book read to the end: it
        // offers the one after it. An article's read state is the RSS tab's. An index's chips
        // and 我的書庫's tiles are not books, nor are 精選書單's lists.
        case .continueReading, .nextInSeries, .subscriptionArticles, .aozoraIndex, .gutenbergLists, .myLibrary, .unknown:
            return false
        }
    }
}

extension ReadingBook {
    /// 已讀完, as the shelf shows it (`BookshelfAccessibility.readingStatus`).
    var isReadToEnd: Bool { currentPosition >= 0.99 }
}

extension CopyLookup {
    /// Whether any copy of the entry's book on this device was read to the end: the shelf
    /// copy a card stands for, or one made from the entry's item. A book-source item has
    /// none (`CopyLookup` leaves book-source copies out), so it is never hidden.
    func isRead(_ entry: CollectionEntry) -> Bool {
        guard case .item(let record, _, let opening) = entry else { return false }
        if case .copy(let id) = opening, copies(for: .copy(id)).contains(where: \.isReadToEnd) { return true }
        return copies(for: record.key).contains(where: \.isReadToEnd)
    }
}
