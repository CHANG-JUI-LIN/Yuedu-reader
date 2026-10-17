import Foundation

/// The module a shelf copy is read through (module ecosystem M5b, `ReadingBook.module`): the
/// module's id and the book's page, the item's own `bookUrl` as its list gave it, so the copy's
/// source record (`SourceRecord.derived`) is the item's.
struct ModuleBookReference: Codable, Equatable, Hashable, Sendable {
    var moduleID: String
    var bookURL: String
}

/// A module's book as a list item gave it, frozen into its `ItemOpening` (CLAUDE.md, "Freeze
/// data at search navigation boundaries"): what adding it to the shelf needs.
struct ModuleBook: Hashable, Sendable {
    var reference: ModuleBookReference
    var title: String
    var author: String
    /// Already checked against the module's hosts (`ModuleProvider.entry`).
    var coverURL: String?
    var contentKind: ContentKind
}

enum ModuleBookError: LocalizedError, Equatable {
    /// The module was removed, or this storefront does not have it.
    case moduleMissing(String)
    /// The module is installed but turned off (停用) on the 模組 page.
    case moduleDisabled(String)
    /// The module has no `reading` rules: its books are data only.
    case notReadable(String)
    /// Its table of contents read no chapter.
    case noChapters

    var errorDescription: String? {
        switch self {
        case .moduleMissing: localized("找不到這本書的模組")
        case .moduleDisabled: localized("這本書的模組已停用，在「模組」頁啟用後才能閱讀")
        case .notReadable: localized("這個模組的書無法閱讀")
        case .noChapters: localized("目錄是空的")
        }
    }
}

/// A module's book read through its installed module: the table of contents, a chapter. The
/// module is looked up by id on every call, so an update to it applies at once and a removed
/// one says so.
struct ModuleBookReader: Sendable {
    let client: RuleModuleClient
    /// The module in use by id; throws `moduleDisabled` for one turned off.
    let module: @Sendable (String) async throws -> RuleModule?

    static let live = ModuleBookReader(client: RuleModuleClient(), module: { @MainActor id in
        let library = RuleModuleLibrary.shared
        await library.loadIfNeeded()
        if let installed = library.module(id: id) { return installed.module }
        if library.installed(id: id) != nil { throw ModuleBookError.moduleDisabled(id) }
        return nil
    })

    private func readable(_ reference: ModuleBookReference) async throws -> RuleModule {
        guard let module = try await module(reference.moduleID) else { throw ModuleBookError.moduleMissing(reference.moduleID) }
        guard module.reading != nil else { throw ModuleBookError.notReadable(reference.moduleID) }
        return module
    }

    /// The book's chapters as the reader lists them; a volume heading has no url.
    func chapters(of reference: ModuleBookReference, title: String) async throws -> [OnlineChapterRef] {
        let module = try await readable(reference)
        let chapters = try await client.tableOfContents(bookURL: reference.bookURL, title: title, in: module)
        return chapters.enumerated().map { index, chapter in
            OnlineChapterRef(index: index, title: chapter.title, url: chapter.url, isVolume: chapter.isVolume)
        }
    }

    func chapterPackage(bookId: UUID, ref: OnlineChapterRef, reference: ModuleBookReference) async throws -> ChapterBuildResult {
        let module = try await readable(reference)
        return try await client.chapterPackage(bookId: bookId, chapterIndex: ref.index,
                                               chapter: ModuleChapter(title: ref.title, url: ref.url), in: module)
    }
}

/// Adding a module's book to the shelf, or reading it without: one use case, as
/// `AozoraLibraryDownloadService` is for 青空文庫. A book read without 加入書架 stays off the
/// shelf (maintainer, 2026-10-13) and is read again from the same copy.
@MainActor
final class ModuleBookShelf {
    static let shared = ModuleBookShelf()

    private let reader: ModuleBookReader
    private var operations: [ModuleBookReference: Task<ReadingBook, any Error>] = [:]

    init(reader: ModuleBookReader = .live) {
        self.reader = reader
    }

    func addToShelf(_ book: ModuleBook, store: BookStore) async throws -> ReadingBook {
        let copy = try await readingCopy(book, store: store)
        if copy.isInBookshelf { return copy }
        // Nothing runs between the two on the main actor, so the copy is still recorded.
        guard let shelved = store.addReadingBookToShelf(id: copy.id) else { throw RemoteLibraryError.missingBook }
        return shelved
    }

    /// The copy there is, on the shelf or not, or a new one off the shelf once its table of
    /// contents is read.
    func readingCopy(_ book: ModuleBook, store: BookStore) async throws -> ReadingBook {
        let copies = store.copyLookup().copies(for: SourceRecord.derived(from: book).key)
        if let copy = copies.first(where: \.isInBookshelf) ?? copies.first { return copy }
        if let operation = operations[book.reference] { return try await operation.value }
        let reader = reader
        let operation = Task {
            let chapters = try await reader.chapters(of: book.reference, title: book.title)
            guard chapters.contains(where: { !$0.isVolume }) else { throw ModuleBookError.noChapters }
            return store.addModuleBook(book, chapters: chapters, isInBookshelf: false)
        }
        operations[book.reference] = operation
        defer { operations.removeValue(forKey: book.reference) }
        return try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            operation.cancel()
        }
    }
}

extension SourceRecord {
    /// A module's book not yet on the shelf, under the key its copy will have.
    static func derived(from book: ModuleBook) -> SourceRecord {
        SourceRecord(key: SourceItemKey(instance: SourceInstanceKey(type: .module, id: book.reference.moduleID),
                                        item: book.reference.bookURL),
                     title: book.title, authors: book.author.isEmpty ? [] : [book.author], language: nil,
                     contentKind: book.contentKind, identifiers: [], copyID: nil, acquisitions: [.readOnline])
    }
}
