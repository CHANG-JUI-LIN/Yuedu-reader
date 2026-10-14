import Foundation

/// The value of 書籍資訊's 「來源」 row: where a copy came from, read from its source record
/// (unified library 1a). The mapping is in the Phase 1 plan; 遠端書庫 is the one string it
/// added (maintainer, 2026-10-10).
enum SourceLabel {
    static func text(for book: ReadingBook, record: SourceRecord) -> String {
        switch record.key.instance.type {
        case .bookSource:
            return localized("網路書籍")
        case .opds:
            return RemoteLibraryKind.opds.libraryTitle
        case .webDAV:
            return RemoteLibraryKind.webDAV.libraryTitle
        case .calibre:
            return RemoteLibraryKind.calibre.libraryTitle
        case .gutenberg:
            return localized("Project Gutenberg")
        case .aozora:
            return localized("青空文庫")
        case .library, .bibliographic, .module:
            if book.aozora != nil { return localized("青空文庫") }
            // A remote copy whose connection was removed: its kind is gone with it.
            if book.remoteSource != nil { return localized("遠端書庫") }
            return isWebPage(book) ? localized("網頁匯入") : localized("本機文件")
        }
    }

    /// A browser import (`addWebBrowsedBook`) or a page saved by URL (`importWeb`).
    private static func isWebPage(_ book: ReadingBook) -> Bool {
        if book.isOnline { return true }
        let source = book.source.lowercased()
        return source.hasPrefix("http://") || source.hasPrefix("https://")
    }
}
