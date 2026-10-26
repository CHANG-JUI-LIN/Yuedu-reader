import Foundation

/// The copy a version of a work is read from, taken as 開始閱讀 takes it: one path for 作品詳情's
/// 目錄 and for 換源 (maintainer 2026-10-26: 「所有來源配置、WebDAV、Calibre、模組⋯都是相同地位」).
/// A copy is itself; a 青空文庫 work, a module's book and a library's file each become their own
/// reading copy, off the shelf until something puts one there (`AozoraLibraryDownloading`,
/// `ModuleBookShelf`, `RemoteLibraryServing`), and reused when one was taken before.
@MainActor
struct VersionReadingCopy {
    /// A library item in no format this app reads.
    struct Unreadable: LocalizedError {
        var errorDescription: String? { localized("這個版本的格式無法閱讀。") }
    }

    let store: BookStore
    let dependencies: AppDependencies

    /// How `version`'s copy is taken; nil for a version with none — a 來源配置's book (its own
    /// page reads it), a bibliographic record — or a library item not read yet, or in a format
    /// that does not read.
    /// - Parameters:
    ///   - item: the library item an OPDS entry, a WebDAV file or a Gutenberg book reads from.
    ///   - format: the item's format to read.
    func acquisition(of version: WorkDetailRoute, item: RemoteLibraryItem?,
                     format: RemoteLibraryFormat?) -> (() async throws -> ReadingBook)? {
        switch version.opening {
        case .copy(let id):
            guard let book = store.copyLookup().copies(for: .copy(id)).first else { return nil }
            return { book }
        case .aozora(let work):
            return { [dependencies, store] in try await dependencies.aozoraLibrary.readingCopy(work: work, store: store) }
        case .moduleBook(let book):
            return { [dependencies, store] in try await dependencies.moduleBooks.readingCopy(book, store: store) }
        case .gutenberg, .opdsEntry, .webDAVFile:
            guard let item, let format, format.isSupported else { return nil }
            return { [dependencies, store] in try dependencies.remoteLibrary.readingCopy(item: item, format: format, store: store) }
        case .onlineBook, .bibliographic:
            return nil
        }
    }

    /// Takes `version`'s copy now, in its library's preferred format; a Gutenberg book's catalog
    /// entry is read first. Throws `Unreadable` for a version with no copy to take.
    func readingCopy(of version: WorkDetailRoute) async throws -> ReadingBook {
        let item = try await libraryItem(of: version)
        let format = item.flatMap(RemoteLibraryBrowsePresentation.preferredFormat(in:))
        guard let take = acquisition(of: version, item: item, format: format) else { throw Unreadable() }
        return try await take()
    }

    /// The library item `version` reads from: an OPDS entry's or a WebDAV file's, held by the
    /// version; a Gutenberg book's, from its catalog entry. Nil for every other version.
    func libraryItem(of version: WorkDetailRoute) async throws -> RemoteLibraryItem? {
        switch version.opening {
        case .opdsEntry(let entry, let connectionID):
            return RemoteLibraryBookRoute(entry: entry, connectionID: connectionID).item
        case .webDAVFile(let entry, let connectionID):
            return RemoteLibraryBookRoute(entry: entry, connectionID: connectionID).item
        case .gutenberg(let book):
            return try await GutenbergBookDetail.load(book).item
        case .copy, .aozora, .moduleBook, .onlineBook, .bibliographic:
            return nil
        }
    }

    /// Whether `version` has a copy to take, as far as is known without a request: a library
    /// item held by the version in a format that reads. A Gutenberg book's formats are known
    /// once its entry is read, so it counts.
    static func isReadable(_ version: WorkDetailRoute) -> Bool {
        switch version.opening {
        case .opdsEntry(let entry, let connectionID):
            return RemoteLibraryBrowsePresentation.preferredFormat(
                in: RemoteLibraryBookRoute(entry: entry, connectionID: connectionID).item)?.isSupported == true
        case .webDAVFile(let entry, let connectionID):
            return RemoteLibraryBrowsePresentation.preferredFormat(
                in: RemoteLibraryBookRoute(entry: entry, connectionID: connectionID).item)?.isSupported == true
        case .gutenberg, .aozora, .moduleBook:
            return true
        case .copy, .onlineBook, .bibliographic:
            return false
        }
    }
}
