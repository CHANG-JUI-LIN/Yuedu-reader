import Foundation

// Unified library 5d-3g: 隱藏已讀 (Phase 5 plan, decision 21), Emby's `HidePlayedInLatest`
// and `HidePlayedInSuggestions`. 最新 and 相關 leave out a book read to the end on this
// device, by any copy of it: read to the end, or 標記為已讀完 (progress 1). The test is the
// one the shelf uses for 已讀完.

/// Which sections hide read books, and how to tell one.
struct HomeReadFilter {
    var hidesInLatest: Bool
    var hidesInRelated: Bool
    /// Whether an entry's book was read to the end.
    let isRead: (CollectionEntry) -> Bool

    func hides(in binding: HomeSectionBinding) -> Bool {
        switch binding {
        case .latest: hidesInLatest
        case .related: hidesInRelated
        // 系列下一本 never offers a book read to the end: it offers the one after it.
        case .nextInSeries: false
        default: false
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
