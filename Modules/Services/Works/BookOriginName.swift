import Foundation

/// Where a copy is read from, in a word: under the reader's title capsule and in 換源's list of
/// versions (maintainer 2026-10-26: every origin is a version like any other). A 來源配置's, a
/// module's or a library connection's own name; 青空文庫 or Project Gutenberg; 網頁匯入 for a page
/// the browser imported; 本機 for a file imported on this device.
@MainActor
enum BookOriginName {
    /// In `SourceRecord.derived(from:context:)`'s order: a library's file, a 青空文庫 work, a
    /// module's book, a 來源配置's book, then what was imported.
    static func of(_ book: ReadingBook) -> String {
        if let remote = book.remoteSource {
            if remote.connectionID == PublicLibraryID.gutenberg.rawValue { return localized("Project Gutenberg") }
            // A removed connection leaves the file it gave.
            return RemoteLibraryConnectionStore.shared.connection(id: remote.connectionID)?.name ?? localized("本機")
        }
        if book.aozora != nil { return localized("青空文庫") }
        if book.isOnline, let module = book.module {
            return RuleModuleLibrary.shared.installed(id: module.moduleID)?.module.title ?? localized("模組")
        }
        if book.isOnline, let sourceID = book.bookSourceId {
            return BookSourceStore.shared.source(id: sourceID).map(\.bookSourceName)
                .flatMap { $0.isEmpty ? nil : $0 } ?? localized("未知來源配置")
        }
        return book.isOnline ? localized("網頁匯入") : localized("本機")
    }

    /// A version not read here yet, by the place that has it: a library connection's or a
    /// module's name, 青空文庫 or Project Gutenberg; nil for a copy or a 來源配置's book, named
    /// from their own records.
    static func of(_ version: WorkDetailRoute) -> String? {
        switch version.opening {
        case .opdsEntry(_, let id), .webDAVFile(_, let id):
            RemoteLibraryConnectionStore.shared.connection(id: id)?.name ?? localized("遠端書庫")
        case .gutenberg: localized("Project Gutenberg")
        case .aozora: localized("青空文庫")
        case .moduleBook(let book):
            RuleModuleLibrary.shared.installed(id: book.reference.moduleID)?.module.title ?? localized("模組")
        case .copy, .onlineBook, .bibliographic: nil
        }
    }
}
