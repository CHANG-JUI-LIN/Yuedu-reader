import Foundation

/// Both shelf layouts expose the same single book focus and rotor actions.
enum BookshelfAccessibility {
    static func description(for book: ReadingBook) -> String {
        var parts = [book.title]
        if !book.author.isEmpty { parts.append(book.author) }
        if book.resolvedPipelineKind == .audio { parts.append(localized("有聲書")) }
        if let latest = book.latestChapterDisplayTitle {
            parts.append(localized("最新") + "，" + latest)
        }
        if book.hasNewChapterUpdate { parts.append(localized("有新章節")) }
        parts.append(readingStatus(for: book))
        if book.offlineDownloadState == .downloading { parts.append(localized("下載中")) }
        return parts.joined(separator: "，")
    }

    /// 新增, 已讀完, or how far the book is read: the shelf's words, also on Explore's home cards.
    static func readingStatus(for book: ReadingBook) -> String {
        if book.shouldShowNewOnBookshelf { return localized("新增") }
        if book.currentPosition >= 0.99 { return localized("已讀完") }
        return String(format: localized("已讀 %d%%"), Int(book.currentPosition * 100))
    }
}
