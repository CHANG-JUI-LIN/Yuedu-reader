import Combine
import Foundation
import OSLog
import SwiftSoup
import SwiftUI
import UIKit
import WidgetKit
import ReadiumShared

extension OnlineBookContentKind {
    var pipelineKind: BookPipelineKind {
        switch self {
        case .audio:
            return .audio
        case .manga:
            return .manga
        case .text:
            return .html
        }
    }
}

// Widget data model — matched with Widget target's BookProgress
struct WidgetBookProgress: Codable {
    var title: String
    var author: String
    var progress: Double
    var coverImagePath: String?
    var lastReadDate: Date
}

private struct PersistedPositionSnapshot: Equatable {
    let currentPosition: Double
    let mangaChapterIndex: Int
    let mangaPage: Int
    let audioChapterIndex: Int
    let audioTimeSeconds: Double

    init(book: ReadingBook) {
        currentPosition = book.currentPosition
        mangaChapterIndex = book.mangaChapterIndex
        mangaPage = book.mangaPage
        audioChapterIndex = book.audioChapterIndex
        audioTimeSeconds = book.audioTimeSeconds
    }
}

/// Owns the single record array and its data publisher. Data subscribers (sync)
/// must still receive progress while the full-screen reader observes its session.
private final class BookRecordStorage {
    @Published var values: [ReadingBook] = []
}

class BookStore: ObservableObject, BookProvider {
    let objectWillChange = ObservableObjectPublisher()
    private let recordStorage = BookRecordStorage()
    private var records: [ReadingBook] {
        get { recordStorage.values }
        set { replaceRecords(newValue) }
    }

    private func replaceRecords(_ value: [ReadingBook], notifyLibraryViews: Bool = true) {
        if notifyLibraryViews { objectWillChange.send() }
        recordStorage.values = movingChapterListsToStore(value)
        mutationRevision &+= 1
    }

    /// A record never holds its table of contents, as legado's `Book` has none: a list
    /// attached to one — a book built with its chapters, or read through `readingBook(id:)`
    /// and saved back — moves to `chapterStore`, and the record keeps its summary. A record
    /// without one leaves the stored list alone.
    private func movingChapterListsToStore(_ value: [ReadingBook]) -> [ReadingBook] {
        guard value.contains(where: { $0.onlineChapters != nil }) else { return value }
        return value.map { book in
            guard let chapters = book.onlineChapters else { return book }
            var record = book
            record.onlineChapters = nil
            record.applyChapterSummary(from: chapters)
            chapterStore.setChapters(chapters, for: book.id)
            return record
        }
    }

    /// The network may finish after an import, deletion or reading-position edit.
    /// A result may replace the shelf only while its input snapshot is current.
    private(set) var mutationRevision: UInt64 = 0

    /// Only explicit shelf members are exposed to shelf, widget and sync clients.
    var books: [ReadingBook] {
        get { records.filter(\.isInBookshelf) }
        set {
            let ids = Set(newValue.map(\.id))
            records = newValue.map { book in
                var book = book
                book.isInBookshelf = true
                return book
            } + records.filter { !$0.isInBookshelf && !ids.contains($0.id) }
        }
    }

    var shelfPublisher: AnyPublisher<[ReadingBook], Never> {
        recordStorage.$values.map { $0.filter(\.isInBookshelf) }.eraseToAnyPublisher()
    }

    var readingBooks: [ReadingBook] { records }

    /// The book with its table of contents, which is read from `chapterStore` the first
    /// time it is asked for — legado's `getChapterList(bookUrl)` for the book being opened.
    func readingBook(id: UUID) -> ReadingBook? {
        guard var book = records.first(where: { $0.id == id }) else { return nil }
        book.onlineChapters = chapterStore.chapters(for: id)
        return book
    }

    /// A book's table of contents (legado's `getChapterList`). The shelf's records carry
    /// only its summary (`totalChapterNum`, `latestChapterTitle`).
    func chapters(for bookId: UUID) -> [OnlineChapterRef]? {
        chapterStore.chapters(for: bookId)
    }

    func saveReadingBook(_ book: ReadingBook) {
        if let index = records.firstIndex(where: { $0.id == book.id }) {
            records[index] = book
        } else {
            records.append(book)
        }
        saveMetaImmediately()
    }

    @discardableResult
    func addReadingBookToShelf(id: UUID) -> ReadingBook? {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return nil }
        records[index].isInBookshelf = true
        saveMetaImmediately()
        return records[index]
    }

    private var readingMetadataFileURL: URL {
        metadataFileURL.deletingPathExtension().appendingPathExtension("reading.json")
    }
    private var lastPersistedReadingData: Data?


    // Legacy UserDefaults key kept only for one-time migration.
    private let legacyMetaKey = "yd_books_meta"
    private var saveWorkItem: DispatchWorkItem?
    /// When the oldest still-unwritten edit was requested. Drives the debounce ceiling.
    private var firstPendingSaveRequestedAt: Date?
    private var saveGeneration = 0
    private let metadataFileURL: URL
    private var lastPersistedMetadataData: Data?
    /// Set when the shelf file could not be read, or did not decode and could not be copied
    /// aside. Writing would replace the only copy of data nobody has seen.
    private var metadataWritesBlocked = false
    private var lastPersistedPositionSnapshots: [UUID: PersistedPositionSnapshot] = [:]
    private var lastPersistedPositionSaveUptimeByBook: [UUID: TimeInterval] = [:]

    private static let minimumProgressDeltaForMetadataWrite = 0.0025
    private static let minimumAudioTimeDeltaForMetadataWrite: TimeInterval = 30
    private static let maximumPositionMetadataWriteInterval: TimeInterval = 60

    /// Persistent storage location for the book-library JSON.
    /// Kept out of the UserDefaults domain plist (which is loaded synchronously at
    /// launch into memory in its entirety) and under Application Support rather than
    /// Documents: this file *is* the bookshelf, and Documents is user-visible in the
    /// Files app, where deleting it would empty the shelf. Still backed up.
    /// `StorageMigration` moves it out of the legacy Documents location.
    static var booksMetaFileURL: URL {
        StorageLocations.booksMetadataFile
    }

    /// Per-book reader settings. Kept beside the shelf file, as the reading records are, so
    /// a store opened on any other shelf (every test's temporary one) never reads or
    /// rewrites the app's own.
    let readerSettings: BookReaderSettingsStore

    /// Every book's table of contents, one file per book beside the shelf file — legado's
    /// chapters table. The shelf file holds the books and a summary of each list.
    private let chapterStore: BookChapterStore
    /// Whether the last load read both the shelf and the reading records. Only then may a
    /// book missing from `records` be taken as gone, and its list removed.
    private var recordsLoadedCompletely = false

    /// Where a book read and then taken off the shelf leaves its name for 搜索's 最近閱讀
    /// (`OffShelfReadRecords`). Nil for a store on any shelf but the app's own, which then
    /// leaves no names behind.
    private let offShelfReadRecordsDefaults: UserDefaults?

    /// - Parameter legacyReaderSettingsDefaults: where builds before
    ///   `BookReaderSettingsStore` kept the fixed-page reading mode. Only the app's own
    ///   store passes one; a store opened on any other shelf must not claim those keys.
    /// - Parameter offShelfReadRecordsDefaults: where removed books leave their names.
    ///   Only the app's own store passes one, so a test's shelf never writes the app's list.
    init(
        metadataFileURL: URL = BookStore.booksMetaFileURL,
        legacyReaderSettingsDefaults: UserDefaults? = nil,
        offShelfReadRecordsDefaults: UserDefaults? = nil
    ) {
        self.metadataFileURL = metadataFileURL
        self.offShelfReadRecordsDefaults = offShelfReadRecordsDefaults
        readerSettings = BookReaderSettingsStore(
            fileURL: metadataFileURL.deletingPathExtension().appendingPathExtension("reader-settings.json")
        )
        chapterStore = BookChapterStore(
            directoryURL: metadataFileURL.deletingPathExtension().appendingPathExtension("chapters")
        )
        let shelfLoaded = loadMeta()
        let readingRecordsLoaded = loadReadingRecords()
        finishLoadingChapterLists(complete: shelfLoaded && readingRecordsLoaded)
        if let legacyReaderSettingsDefaults {
            readerSettings.migrateLegacyFixedPageReadingModes(
                from: legacyReaderSettingsDefaults,
                knownBookIDs: Set(records.map(\.id)),
                // Only a shelf that really loaded can say a book no longer exists.
                removesUnknownKeys: shelfLoaded && readingRecordsLoaded
            )
        }
    }

    // MARK: Read Book Content

    func content(for book: ReadingBook) -> String {
        let url = documentsURL(for: book.contentFilename)
        if book.resolvedPipelineKind == .txt {
            return (try? TXTFileReader.readTextFile(url: url)) ?? ""
        }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    func package(forLocalBook book: ReadingBook) throws -> BookPackage {
        switch book.resolvedPipelineKind {
        case .epub:
            let epubFilename = book.contentFilename.hasSuffix(".epub")
                ? book.contentFilename
                : book.contentFilename.replacingOccurrences(of: "_epub.json", with: ".epub")
            let epubURL = documentsURL(for: epubFilename)
            let placeholder = EPUBParsedBook.placeholder(
                title: book.title,
                author: book.author,
                basePath: epubURL.deletingLastPathComponent()
            )
            return placeholder.makePackage(pipelineKind: .epub, originalSourceURL: epubURL)
        case .html:
            throw ReaderError.unsupportedFormat("HTML 渲染尚待 CoreText 遷移完成，目前不支援")
        case .txt:
            throw ReaderError.unsupportedFormat("TXT 渲染尚待 CoreText 遷移完成，目前不支援")
        case .manga:
            throw ReaderError.unsupportedFormat("漫畫使用獨立的圖片閱讀器，無 CoreText 套件")
        case .fixedPage:
            throw ReaderError.unsupportedFormat("固定頁面文件使用獨立的固定頁面閱讀器，無 CoreText 套件")
        case .audio:
            throw ReaderError.unsupportedFormat("有聲書使用獨立的音訊播放器，無 CoreText 套件")
        }
    }

    // MARK: Import TXT File

    @MainActor @discardableResult
    func importTxt(url: URL, title: String? = nil) async throws -> ReadingBook {
        let fallbackTitle = title ?? url.deletingPathExtension().lastPathComponent
        let filename = "\(UUID().uuidString).txt"
        let destination = documentsURL(for: filename)

        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let metadataStart = ProcessInfo.processInfo.systemUptime
            let metadata = try SourcePerfTrace.span(
                "txt.import.metadata",
                "bytes=\((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)"
            ) {
                try TXTMetadataProbe.probe(
                    url: url,
                    fallbackTitle: fallbackTitle
                )
            }
            AppLogger.info(
                "[ImportTrace][BookStore.importTxt] stage=metadataProbe "
                    + "elapsedMs=\(String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - metadataStart) * 1_000))"
            )

            try Task.checkCancellation()
            let persistenceStart = ProcessInfo.processInfo.systemUptime
            try SourcePerfTrace.span(
                "txt.import.persist",
                "bytes=\((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)"
            ) {
                try TXTFilePersistence.persistOriginal(
                    source: url,
                    destination: destination
                )
            }
            AppLogger.info(
                "[ImportTrace][BookStore.importTxt] stage=filePersistence "
                    + "elapsedMs=\(String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - persistenceStart) * 1_000))"
            )
            try Task.checkCancellation()
            return metadata
        }

        let metadata: TXTBookMetadata
        do {
            metadata = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
        } catch {
            if FileManager.default.fileExists(atPath: destination.path) {
                do {
                    try FileManager.default.removeItem(at: destination)
                } catch let cleanupError {
                    AppLogger.error(
                        "Failed to clean cancelled TXT import: \(cleanupError.localizedDescription)"
                    )
                }
            }
            throw error
        }

        var book = ReadingBook(
            title: title ?? metadata.title,
            author: metadata.author ?? "未知作者",
            source: "local",
            contentFilename: filename
        )
        book.contentPipelineKind = .txt
        let importedBook = book

        do {
            try Task.checkCancellation()
            records.insert(importedBook, at: 0)
            saveMeta()
        } catch {
            if FileManager.default.fileExists(atPath: destination.path) {
                do {
                    try FileManager.default.removeItem(at: destination)
                } catch let cleanupError {
                    AppLogger.error(
                        "Failed to clean uncommitted TXT import: \(cleanupError.localizedDescription)"
                    )
                }
            }
            throw error
        }
        return importedBook
    }

    @discardableResult
    func importMarkdown(
        url: URL,
        title: String? = nil,
        author: String = "未知作者"
    ) throws -> ReadingBook {
        let bookTitle = title ?? url.deletingPathExtension().lastPathComponent
        let ext = normalizedMarkdownExtension(url.pathExtension.lowercased())
        return try importLocalTextFile(
            url: url,
            title: bookTitle,
            author: author,
            fileExtension: ext
        )
    }

    // MARK: Import Local Manga Archive

    @discardableResult
    func importLocalManga(
        url: URL,
        title: String? = nil,
        author: String? = nil
    ) async throws -> ReadingBook {
        let info = try await LocalMangaArchive.inspect(url: url)
        let uuid = UUID().uuidString
        let ext = url.pathExtension.lowercased() == "zip" ? "zip" : "cbz"
        let filename = "\(uuid).\(ext)"
        let destURL = documentsURL(for: filename)
        var coverFilename: String?
        var book: ReadingBook?

        func cleanupImportedFiles() {
            try? FileManager.default.removeItem(at: destURL)
            if let coverFilename {
                try? FileManager.default.removeItem(at: StorageLocations.coverFile(coverFilename))
            }
            if let book {
                try? FileManager.default.removeItem(at: LocalMangaArchive.bookDirectory(bookId: book.id))
            }
        }

        do {
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.copyItem(at: url, to: destURL)

            let resolvedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? title!.trimmingCharacters(in: .whitespacesAndNewlines)
                : info.title
            let resolvedAuthor = author?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? author!.trimmingCharacters(in: .whitespacesAndNewlines)
                : info.author

            if let cover = await LocalMangaArchive.coverImageData(from: destURL),
               UIImage(data: cover.data) != nil {
                let coverExt = cover.fileExtension.isEmpty ? "jpg" : cover.fileExtension
                let candidate = "\(uuid)_cover.\(coverExt)"
                try cover.data.write(to: StorageLocations.coverFile(candidate))
                coverFilename = candidate
            }

            var imported = ReadingBook(
                title: resolvedTitle,
                author: resolvedAuthor,
                source: "local_manga",
                contentFilename: filename
            )
            imported.contentPipelineKind = .manga
            imported.onlineChapters = [
                OnlineChapterRef(index: 0, title: info.chapterTitle, url: filename)
            ]
            imported.coverImagePath = coverFilename
            book = imported

            _ = try await LocalMangaArchive.extractPages(
                from: destURL,
                to: LocalMangaArchive.chapterDirectory(bookId: imported.id, chapterIndex: 0)
            )

            let importedBook = imported
            await MainActor.run {
                self.records.insert(importedBook, at: 0)
                self.saveMeta()
            }
            return importedBook
        } catch {
            cleanupImportedFiles()
            throw error
        }
    }

    // MARK: Import Local PDF

    /// Import a PDF as a `.fixedPage` book: the file stays in Documents, the whole
    /// document is one chapter (so page numbers stay absolute), and the PDF's own
    /// bookmarks become the reader's table of contents.
    @discardableResult
    func importLocalPDF(
        url: URL,
        title: String? = nil,
        author: String? = nil
    ) async throws -> ReadingBook {
        try Task.checkCancellation()
        let info = try LocalPDFArchive.inspect(url: url)
        let uuid = UUID().uuidString
        let filename = "\(uuid).pdf"
        let destURL = documentsURL(for: filename)
        var coverFilename: String?

        func cleanupImportedFiles() {
            try? FileManager.default.removeItem(at: destURL)
            if let coverFilename {
                try? FileManager.default.removeItem(at: StorageLocations.coverFile(coverFilename))
            }
        }

        do {
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.copyItem(at: url, to: destURL)

            let resolvedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? title!.trimmingCharacters(in: .whitespacesAndNewlines)
                : info.title
            let resolvedAuthor = author?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? author!.trimmingCharacters(in: .whitespacesAndNewlines)
                : info.author

            if let coverData = LocalPDFArchive.coverImageData(from: destURL) {
                let candidate = "\(uuid)_cover.jpg"
                try coverData.write(to: StorageLocations.coverFile(candidate))
                coverFilename = candidate
            }

            var imported = ReadingBook(
                title: resolvedTitle,
                author: resolvedAuthor,
                source: "local_pdf",
                contentFilename: filename
            )
            imported.contentPipelineKind = .fixedPage
            imported.onlineChapters = [
                LocalPDFArchive.chapterRef(
                    for: info,
                    filename: filename,
                    bookTitle: resolvedTitle
                )
            ]
            imported.coverImagePath = coverFilename

            let importedBook = imported
            try await MainActor.run {
                try Task.checkCancellation()
                self.records.insert(importedBook, at: 0)
                self.saveMeta()
            }
            return importedBook
        } catch {
            cleanupImportedFiles()
            throw error
        }
    }

    // MARK: Import Local Audiobook

    @discardableResult
    func importLocalAudiobook(
        url: URL,
        title: String? = nil,
        author: String? = nil
    ) async throws -> ReadingBook {
        let info = try await LocalAudiobookArchive.inspect(url: url)
        let uuid = UUID().uuidString
        let contentFilename = info.isArchive
            ? "local_audio/\(uuid)"
            : "\(uuid).\(url.pathExtension.lowercased())"
        let contentURL = documentsURL(for: contentFilename)
        var coverFilename: String?

        func cleanupImportedFiles() {
            try? FileManager.default.removeItem(at: contentURL)
            if let coverFilename {
                try? FileManager.default.removeItem(at: StorageLocations.coverFile(coverFilename))
            }
        }

        do {
            let resolvedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? title!.trimmingCharacters(in: .whitespacesAndNewlines)
                : info.title
            let resolvedAuthor = author?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? author!.trimmingCharacters(in: .whitespacesAndNewlines)
                : info.author

            let chapters: [OnlineChapterRef]
            if info.isArchive {
                let extracted = try await LocalAudiobookArchive.extractAudioEntries(from: url, to: contentURL)
                chapters = extracted.enumerated().map { index, chapter in
                    OnlineChapterRef(
                        index: index,
                        title: chapter.title,
                        url: "local_audio/\(uuid)/\(chapter.filename)"
                    )
                }
            } else {
                if FileManager.default.fileExists(atPath: contentURL.path) {
                    try FileManager.default.removeItem(at: contentURL)
                }
                try FileManager.default.copyItem(at: url, to: contentURL)
                chapters = info.chapterSeeds.enumerated().map { index, seed in
                    OnlineChapterRef(
                        index: index,
                        title: seed.title,
                        url: contentFilename,
                        audioStartSeconds: seed.audioStartSeconds,
                        audioDurationSeconds: seed.audioDurationSeconds
                    )
                }
            }

            if let data = info.coverImageData,
               let image = UIImage(data: data),
               let jpeg = image.jpegData(compressionQuality: 0.88) {
                let candidate = "\(uuid)_cover.jpg"
                try jpeg.write(to: StorageLocations.coverFile(candidate))
                coverFilename = candidate
            }

            var imported = ReadingBook(
                title: resolvedTitle,
                author: resolvedAuthor,
                source: "local_audio",
                contentFilename: contentFilename
            )
            imported.contentPipelineKind = .audio
            imported.onlineChapters = chapters
            imported.coverImagePath = coverFilename

            let importedBook = imported
            await MainActor.run {
                self.records.insert(importedBook, at: 0)
                self.saveMeta()
            }
            return importedBook
        } catch {
            cleanupImportedFiles()
            throw error
        }
    }

    private func importLocalTextFile(
        url: URL,
        title: String,
        author: String,
        fileExtension: String
    ) throws -> ReadingBook {
        let filename = "\(UUID().uuidString).\(fileExtension)"
        let destURL = documentsURL(for: filename)
        try TXTFilePersistence.persistOriginal(source: url, destination: destURL)

        var book = ReadingBook(title: title, author: author, source: "local", contentFilename: filename)
        book.contentPipelineKind = .txt
        records.insert(book, at: 0)
        saveMeta()
        return book
    }

    private func normalizedMarkdownExtension(_ ext: String) -> String {
        switch ext {
        case "markdown":
            return "markdown"
        default:
            return "md"
        }
    }

    // MARK: Import EPUB File

    @discardableResult
    func importEpub(url: URL, title: String? = nil, author: String? = nil, requireValidPublication: Bool = false) async throws -> ReadingBook {
        let importStartUptime = ProcessInfo.processInfo.systemUptime
        func importTrace(_ message: String) {
            let line = "[ImportTrace][BookStore.importEpub] \(message)"
            print(line)
            NSLog("%@", line)
        }

        let uuid = UUID().uuidString
        let filename = "\(uuid).epub"
        let destURL = documentsURL(for: filename)
        var coverFilename: String? = nil
        let sourceSizeBytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        importTrace(
            "begin source=\(url.lastPathComponent) sourceSizeBytes=\(sourceSizeBytes) dest=\(filename)"
        )

        func cleanupImportedFiles() {
            if FileManager.default.fileExists(atPath: destURL.path) {
                do {
                    try FileManager.default.removeItem(at: destURL)
                } catch {
                    AppLogger.cache("Failed to remove item at \(destURL): \(error)")
                }
            }
            if let coverFilename {
                let coverURL = StorageLocations.coverFile(coverFilename)
                if FileManager.default.fileExists(atPath: coverURL.path) {
                    do {
                        try FileManager.default.removeItem(at: coverURL)
                    } catch {
                        AppLogger.cache("Failed to remove cover image at \(coverURL): \(error)")
                    }
                }
            }
        }

        do {
            try Task.checkCancellation()

            // 1. Copy EPUB to Documents
            let copyStart = ProcessInfo.processInfo.systemUptime
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.copyItem(at: url, to: destURL)
            importTrace(
                "stage=copy done elapsedMs=\(String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - copyStart) * 1000))"
            )
            try Task.checkCancellation()

            // 2. Extract cover and metadata (merged to avoid redundant EPUB ZIP/XML parsing)
            let metadataStart = ProcessInfo.processInfo.systemUptime
            let session: PublicationSession?
            if requireValidPublication {
                // A received file must be readable before the transfer is
                // committed. Reuse this metadata open instead of parsing twice.
                session = try await PublicationSession.open(sourceURL: destURL)
            } else {
                session = try? await PublicationSession.open(sourceURL: destURL)
            }
            importTrace(
                "stage=metadataOpen done elapsedMs=\(String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - metadataStart) * 1000)) chapters=\(session?.chapters.count ?? 0)"
            )
            try Task.checkCancellation()

            let coverStart = ProcessInfo.processInfo.systemUptime
            if let coverResult = await session?.publication.cover(), case .success(let optionalImage) = coverResult, let coverImage = optionalImage {
                let coverName = "\(uuid)_cover.jpg"
                let coverURL = StorageLocations.coverFile(coverName)
                // Convert cover to JPEG for space efficiency
                if let jpegData = coverImage.jpegData(compressionQuality: 0.85) {
                    do {
                        try jpegData.write(to: coverURL)
                        coverFilename = coverName
                    } catch {
                        AppLogger.cache("Failed to write cover image at \(coverURL): \(error)")
                    }
                }
            }
            importTrace(
                "stage=coverExtract done elapsedMs=\(String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - coverStart) * 1000)) hasCover=\(coverFilename != nil)"
            )
            try Task.checkCancellation()

            // 3. Build book model
            let fallbackTitle = title ?? url.deletingPathExtension().lastPathComponent
            let parsedTitle = session?.bookTitle.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let parsedAuthor = session?.author.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let bookTitle = parsedTitle.isEmpty ? fallbackTitle : parsedTitle
            let author = parsedAuthor.isEmpty ? "未知" : parsedAuthor
            var book = ReadingBook(
                title: bookTitle,
                author: author,
                source: "local_epub",
                contentFilename: filename
            )
            if let session, session.layoutMode == .prePaginated {
                book.contentPipelineKind = .fixedPage
                book.onlineChapters = await FixedLayoutEPUBPageProvider.chapterRefs(from: session)
                importTrace(
                    "stage=fixedLayoutDetected pipeline=fixedPage pages=\(session.chapters.count)"
                )
            } else {
                book.contentPipelineKind = .epub
            }
            book.coverImagePath = coverFilename
            let finalBook = book

            try Task.checkCancellation()
            let persistStart = ProcessInfo.processInfo.systemUptime
            try await MainActor.run {
                try Task.checkCancellation()
                self.records.insert(finalBook, at: 0)
                self.saveMeta()
            }
            importTrace(
                "stage=persist done elapsedMs=\(String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - persistStart) * 1000)) totalElapsedMs=\(String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - importStartUptime) * 1000))"
            )
            return finalBook
        } catch is CancellationError {
            importTrace("cancelled totalElapsedMs=\(String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - importStartUptime) * 1000))")
            cleanupImportedFiles()
            throw CancellationError()
        } catch {
            cleanupImportedFiles()
            throw error
        }
    }

    // MARK: Import Web Text

    @discardableResult
    func importWeb(
        content: String,
        title: String,
        author: String = "網路書籍",
        sourceURL: String,
        format: ImportedBookContentFormat = .plainText
    ) throws -> ReadingBook {
        return try saveBook(
            title: title,
            author: author,
            content: content,
            source: sourceURL,
            format: format
        )
    }

    // MARK: Update Reading Progress

    /// Writes a position only when it moves something, or when the library views
    /// have yet to see an earlier silent write.
    ///
    /// A notifying write invalidates every `@EnvironmentObject store` — `ContentView`,
    /// `HomeView` and `BookReaderView` all hold one — and re-evaluates the whole
    /// bookshelf behind the open reader. Reading re-sends the same position
    /// routinely: `saveProgress()` forces a save straight after an auto-save, and a
    /// scroll that settles back on the chapter it started in reports the same
    /// fraction. Those writes move nothing on screen, so they no longer publish.
    /// Persistence is asked either way — a forced save has to be able to flush a
    /// value that is already in memory but not yet on disk.
    ///
    /// `notifyLibraryViews` affects observation only: records, sync, mutation
    /// ownership and the existing disk-write policy always receive the position.
    /// The continuous reader's bars observe ReaderSessionStore instead, and its
    /// lifecycle save publishes the latest summary before the library reappears —
    /// by writing that same position again with notification, which must therefore
    /// publish even though the value did not change.
    private func applyPositionUpdate(
        bookId: UUID,
        force: Bool,
        notifyLibraryViews: Bool = true,
        _ mutate: (inout ReadingBook) -> Void
    ) {
        guard let idx = records.firstIndex(where: { $0.id == bookId }) else { return }
        var book = records[idx]
        mutate(&book)
        let moved = PersistedPositionSnapshot(book: book) != PersistedPositionSnapshot(book: records[idx])
        if moved || (notifyLibraryViews && unpublishedPositionBookIDs.contains(bookId)) {
            var updated = records
            updated[idx] = book
            replaceRecords(updated, notifyLibraryViews: notifyLibraryViews)
            if notifyLibraryViews {
                unpublishedPositionBookIDs.remove(bookId)
            } else {
                unpublishedPositionBookIDs.insert(bookId)
            }
        }
        persistPositionUpdateIfNeeded(bookId: bookId, updatedBook: records[idx], force: force)
    }

    /// Books whose position was written without notifying the library views.
    private var unpublishedPositionBookIDs: Set<UUID> = []

    func updatePosition(
        bookId: UUID, position: Double, forceSave: Bool = false, notifyLibraryViews: Bool = true
    ) {
        applyPositionUpdate(bookId: bookId, force: forceSave, notifyLibraryViews: notifyLibraryViews) { book in
            book.currentPosition = position
        }
    }

    /// Persist manga reading position (chapter index + page) plus an overall
    /// progress fraction so the bookshelf progress bar stays meaningful.
    /// - Parameter pageProgress: how far through the *current* chapter the reader is
    ///   (0...1). Books whose whole content is a single chapter — a local PDF — have
    ///   no chapter-level progress to report, so they pass this instead; leaving it
    ///   nil keeps the chapter-count behaviour every other fixed-page book has.
    func updateMangaPosition(
        bookId: UUID,
        chapter: Int,
        page: Int,
        totalChapters: Int,
        pageProgress: Double? = nil,
        forceSave: Bool = false
    ) {
        applyPositionUpdate(bookId: bookId, force: forceSave) { book in
            book.mangaChapterIndex = chapter
            book.mangaPage = page
            if totalChapters > 0 {
                let progress = (Double(chapter) + (pageProgress ?? 0)) / Double(totalChapters)
                book.currentPosition = min(1.0, max(0, progress))
            }
        }
    }

    /// Persist audiobook playback position (chapter index + elapsed seconds) plus
    /// an overall progress fraction so the bookshelf progress bar stays meaningful.
    func updateAudioPosition(
        bookId: UUID,
        chapter: Int,
        time: Double,
        totalChapters: Int,
        forceSave: Bool = false
    ) {
        applyPositionUpdate(bookId: bookId, force: forceSave) { book in
            book.audioChapterIndex = chapter
            book.audioTimeSeconds = max(0, time)
            if totalChapters > 0 {
                book.currentPosition = min(1.0, Double(chapter) / Double(totalChapters))
            }
        }
    }

    /// The audiobook player's play mode for this book (legado-E / MD3 `Book.setPlayMode`).
    func setAudioPlayMode(bookId: UUID, mode: AudiobookPlayMode) {
        guard let idx = records.firstIndex(where: { $0.id == bookId }),
              records[idx].audiobookPlayMode != mode else { return }
        records[idx].audiobookPlayMode = mode
        saveMeta()
    }

    /// Seconds of opening and closing credits the audiobook player skips in every chapter
    /// of this book (legado-E / MD3 `Book.setOpenCredits` / `setCloseCredits`).
    func setAudioSkipCredits(bookId: UUID, openSeconds: Int, closeSeconds: Int) {
        guard let idx = records.firstIndex(where: { $0.id == bookId }),
              records[idx].audiobookOpeningCreditsSeconds != openSeconds
                || records[idx].audiobookClosingCreditsSeconds != closeSeconds
        else { return }
        records[idx].audiobookOpeningCreditsSeconds = openSeconds
        records[idx].audiobookClosingCreditsSeconds = closeSeconds
        saveMeta()
    }

    func updateLastOpened(bookId: UUID) {
        guard let idx = records.firstIndex(where: { $0.id == bookId }) else { return }
        records[idx].lastOpenedDate = Date()
        // Opening the book counts as acknowledging any new chapters.
        records[idx].hasNewChapterUpdate = false
        saveMeta()
    }

    func setRendererPreference(bookId: UUID, preference: BookRendererPreference) {
        guard let idx = records.firstIndex(where: { $0.id == bookId }) else { return }
        records[idx].rendererPreference = preference
        saveMeta()
    }

    /// Lifts an automatic quarantine, leaving every deliberate choice alone.
    ///
    /// `.quarantined` is written by the chapter fetcher after five cumulative failures and
    /// persisted, and nothing ever wrote it back — so a burst of failures (cancelling a
    /// download cancels many chapters at once) downgraded the book's renderer for good.
    /// Only the automatic value is cleared: `.forcedLegacy` / `.forcedWeb` are the user's.
    func clearAutomaticQuarantine(bookId: UUID) {
        guard let idx = records.firstIndex(where: { $0.id == bookId }),
              records[idx].compatibilityState == .quarantined
        else { return }
        records[idx].compatibilityState = .defaultWeb
        saveMeta()
    }

    func setCompatibilityState(bookId: UUID, state: BookCompatibilityState) {
        guard let idx = records.firstIndex(where: { $0.id == bookId }) else { return }
        records[idx].compatibilityState = state
        saveMeta()
    }

    func setOfflineDownloadState(
        bookId: UUID,
        state: BookOfflineDownloadState,
        downloadedChapterCount: Int? = nil,
        offlineDownloadTask: BookOfflineDownloadTask? = nil
    ) {
        guard let idx = records.firstIndex(where: { $0.id == bookId }) else { return }
        records[idx].offlineDownloadState = state
        if let downloadedChapterCount {
            records[idx].downloadedChapterCount = downloadedChapterCount
        }
        if let offlineDownloadTask {
            records[idx].offlineDownloadTask = offlineDownloadTask
        }
        // Download terminal states must survive an immediate app suspension or
        // termination. Progress updates remain debounced to avoid rewriting the
        // full library metadata once per chapter.
        switch state {
        case .available, .partial, .paused, .failed:
            saveMetaImmediately()
        case .none, .downloading:
            saveMeta()
        }
    }

    func replaceOfflineDownloadTask(
        bookId: UUID,
        task: BookOfflineDownloadTask,
        isRunning: Bool
    ) {
        guard let idx = records.firstIndex(where: { $0.id == bookId }) else { return }
        let previousRequestedIndices = records[idx].offlineDownloadTask?.requestedIndices
        let state = task.derivedState(isRunning: isRunning)
        // One assignment: each one publishes the store to every view on it.
        var updated = records[idx]
        updated.offlineDownloadTask = task
        updated.offlineDownloadState = state
        updated.downloadedChapterCount = task.completedChapterCount
        records[idx] = updated
        let targetsChanged = previousRequestedIndices != task.requestedIndices
        switch state {
        case .available, .partial, .paused, .failed:
            saveMetaImmediately()
        case .none, .downloading:
            targetsChanged ? saveMetaImmediately() : saveMeta()
        }
        // The single write funnel for download progress, and therefore the only place the
        // Live Activity needs to hear from. Observing `$records` instead would fire for every
        // unrelated shelf edit.
        DownloadLiveActivityController.refresh(books: books)
    }

    func clearOfflineDownloadTask(bookId: UUID) {
        guard let idx = records.firstIndex(where: { $0.id == bookId }) else { return }
        records[idx].offlineDownloadTask = nil
        saveMeta()
    }

    @discardableResult
    func ensureOnlineBookForDownload(_ book: ReadingBook) -> ReadingBook {
        guard book.isOnline else { return book }
        if var stored = readingBook(id: book.id) {
            // Only a shelf book's chapters download (`OfflineDownloadManager.runBook`). One
            // only read — 立即閱讀's, which stays off the shelf — goes on it as its download
            // starts, and stays there.
            if !stored.isInBookshelf, addReadingBookToShelf(id: book.id) != nil {
                stored.isInBookshelf = true
            }
            return stored
        }
        var libraryBook = book
        libraryBook.addedDate = Date()
        records.insert(libraryBook, at: 0)
        saveMeta()
        return libraryBook
    }

    /// Finds a shelf book by its source-qualified online identity — or, `onShelf: false`, a
    /// book only read: what 立即閱讀 keeps while its reader is open, and leaves behind when
    /// the app ends before the reader closes.
    ///
    /// A detail URL is not globally unique: aggregation sources can expose the
    /// same site URL under different source rules. Keeping `bookSourceId` in the
    /// key lets those source variants coexist, matching the MD3 shelf model,
    /// while repeated opens of the same source reuse one shelf item.
    func onlineBook(sourceId: UUID?, bookInfoURL: String?, onShelf: Bool = true) -> ReadingBook? {
        let urlKey = Self.onlineBookURLKey(bookInfoURL)
        guard !urlKey.isEmpty else { return nil }
        return records.first { book in
            guard book.isInBookshelf == onShelf, book.isOnline, book.bookSourceId == sourceId else { return false }
            return Self.onlineBookURLKey(book.bookInfoURL ?? book.source) == urlKey
        }
    }

    // MARK: Bookmark Management

    func addBookmark(bookId: UUID, bookmark: Bookmark) {
        guard let idx = records.firstIndex(where: { $0.id == bookId }) else { return }
        // Prevent duplicate bookmarks at the same stable position.
        // Top-bar bookmarks write chapter-start positions, so they share one per chapter.
        if records[idx].bookmarks.contains(where: { $0.hasSameStableLocation(as: bookmark) }) { return }
        records[idx].bookmarks.append(bookmark)
        records[idx].bookmarks = records[idx].bookmarks.sortedByStablePosition()
        saveMeta()
    }

    func removeBookmark(bookId: UUID, bookmarkId: UUID) {
        guard let idx = records.firstIndex(where: { $0.id == bookId }) else { return }
        records[idx].bookmarks.removeAll { $0.id == bookmarkId }
        saveMeta()
    }

    /// 一頁一個書籤：這一頁上已有的書籤，由早到晚。
    func pageBookmarks(bookId: UUID, in range: ReaderPageBookmarkRange) -> [Bookmark] {
        guard let book = records.first(where: { $0.id == bookId }) else { return [] }
        return range.pageBookmarks(in: book.bookmarks)
    }

    /// 一頁一個書籤：這頁沒有就加一個（位置記在頁首），已經有就把整頁範圍內的書籤都移除。
    ///
    /// 用範圍而不是位置相等來判斷，換過字級／邊距之後舊書籤仍然屬於它原本那一頁，
    /// 不會在同一頁上疊出第二個，也刪得掉。
    /// - Returns: `true` 代表這次是加入書籤，`false` 代表移除。
    @discardableResult
    func togglePageBookmark(
        bookId: UUID, chapterIndex: Int, chapterTitle: String,
        range: ReaderPageBookmarkRange, excerpt: String
    ) -> Bool {
        guard let idx = records.firstIndex(where: { $0.id == bookId }) else { return false }
        let existing = range.pageBookmarks(in: records[idx].bookmarks)
        if existing.isEmpty {
            records[idx].bookmarks.append(Bookmark(
                chapterIndex: chapterIndex,
                chapterTitle: chapterTitle,
                position: range.bookmarkPosition,
                excerpt: excerpt
            ))
            records[idx].bookmarks = records[idx].bookmarks.sortedByStablePosition()
            saveMeta()
            return true
        }
        let removedIDs = Set(existing.map(\.id))
        records[idx].bookmarks.removeAll { removedIDs.contains($0.id) }
        saveMeta()
        return false
    }

    func addTextAnnotation(
        bookId: UUID,
        chapterIndex: Int,
        chapterTitle: String,
        position: CoreTextReadingPosition,
        length: Int,
        excerpt: String,
        style: AnnotationStyle = .underline,
        color: AnnotationColor = .yellow,
        note: String? = nil
    ) {
        guard let idx = records.firstIndex(where: { $0.id == bookId }) else { return }
        let safeLength = max(1, length)
        let targetRange = NSRange(location: position.charOffset, length: safeLength)
        let existingAnnotations = records[idx].bookmarks.compactMap(\.coreTextTextAnnotation)
        // 改顏色／樣式時範圍不變，舊標註會被下面的 removeExact 拿掉。新標註要接手它的身分
        // （id、筆記、建立時間、摘錄），否則「換個顏色」等於刪掉重畫一條新的。
        let replaced = existingAnnotations.first {
            $0.spineIndex == position.spineIndex && NSEqualRanges($0.range, targetRange)
        }
        let newAnnotation = CoreTextTextAnnotation(
            id: replaced?.id ?? UUID(),
            spineIndex: position.spineIndex,
            range: targetRange,
            style: style,
            color: color,
            note: note ?? replaced?.note
        )
        // 若同一範圍已有標註（改顏色/樣式時範圍不變），先移除舊的，避免新舊兩色並存。
        // 全新選取不會精確命中既有範圍，removeExact 為 no-op。
        let (cleaned, replacedIDs) = AnnotationStore.removeExact(
            spineIndex: position.spineIndex,
            range: targetRange,
            from: existingAnnotations
        )
        let annotation: CoreTextTextAnnotation
        let absorbedIDs: [UUID]
        switch AnnotationStore.merge(newAnnotation, into: cleaned).editResult {
        case .created(let created):
            annotation = created
            absorbedIDs = []
        case .updated(let updated):
            annotation = updated
            absorbedIDs = [updated.id]
        case .merged(let merged, absorbedIDs: let ids):
            annotation = merged
            absorbedIDs = ids
        }

        // 只換掉這次被取代或併入的標註，其他劃線原封不動。以前是把全書劃線整批刪掉再從範圍重建，
        // 別條的 id、建立時間、摘錄全被洗掉（見 BookStoreTextAnnotationTests）。
        let consumedIDs = Set(replacedIDs).union(absorbedIDs)
        let consumed = records[idx].bookmarks.filter { consumedIDs.contains($0.id) }
        records[idx].bookmarks.removeAll { consumedIDs.contains($0.id) }

        // 沒選到文字時呼叫端送的是頁面開頭（`currentPageExcerpt`），所以範圍沒變就沿用原本的摘錄；
        // 原本是空的（例如被舊版清掉）才用這次送來的。範圍變大時舊摘錄只涵蓋其中一段，改用這次的。
        let replacedExcerpt = replaced.flatMap { old in consumed.first { $0.id == old.id }?.excerpt } ?? ""
        let keepsReplacedExcerpt = NSEqualRanges(annotation.range, targetRange) && !replacedExcerpt.isEmpty
        records[idx].bookmarks.append(Bookmark(
            chapterIndex: chapterIndex,
            chapterTitle: chapterTitle,
            position: CoreTextReadingPosition(spineIndex: annotation.spineIndex, charOffset: annotation.startOffset),
            length: annotation.range.length,
            kind: annotation.style == .highlight ? .highlight : .underline,
            note: annotation.note ?? "",
            excerpt: keepsReplacedExcerpt ? replacedExcerpt : excerpt,
            id: annotation.id,
            date: consumed.map(\.date).min() ?? Date(),
            annotationStyle: annotation.style,
            annotationColor: annotation.color
        ))
        records[idx].bookmarks = records[idx].bookmarks.sortedByStablePosition()
        saveMeta()
    }

    func removeTextAnnotation(
        bookId: UUID,
        position: CoreTextReadingPosition,
        length: Int,
        style: AnnotationStyle = .underline,
        color: AnnotationColor = .yellow
    ) {
        guard let idx = records.firstIndex(where: { $0.id == bookId }) else { return }
        let range = NSRange(location: position.charOffset, length: max(1, length))
        let (_, removedIDs) = AnnotationStore.removeExact(
            spineIndex: position.spineIndex,
            range: range,
            from: records[idx].bookmarks.compactMap(\.coreTextTextAnnotation)
        )
        guard !removedIDs.isEmpty else {
            AppLogger.cache("劃線：要刪除的範圍沒有完全相同的標註 spine=\(position.spineIndex) range=\(range)")
            return
        }
        // 只刪命中的那一條。以前會把同章其他劃線重建成空摘錄、新 id、新建立時間。
        let removedIDSet = Set(removedIDs)
        records[idx].bookmarks.removeAll { removedIDSet.contains($0.id) }
        records[idx].bookmarks = records[idx].bookmarks.sortedByStablePosition()
        saveMeta()
    }

    /// 找出涵蓋指定範圍的標註書籤。
    ///
    /// 新增標註後範圍可能被 `AnnotationStore.merge` 併大，呼叫端不能拿自己送出去的
    /// range 當結果用——筆記要掛在合併後那一條上，否則下次開啟會對不到。
    func textAnnotationBookmark(bookId: UUID, spineIndex: Int, range: NSRange) -> Bookmark? {
        guard let book = records.first(where: { $0.id == bookId }) else { return nil }
        let start = range.location
        let end = range.location + range.length
        return book.bookmarks.first { bm in
            guard bm.kind == .underline || bm.kind == .highlight else { return false }
            guard bm.position.spineIndex == spineIndex else { return false }
            return bm.position.charOffset <= start
                && bm.position.charOffset + bm.length >= end
        }
    }

    /// 寫入／清空一條標註的筆記。傳空字串等於「只刪筆記、保留標註」。
    func setTextAnnotationNote(bookId: UUID, bookmarkId: UUID, note: String) {
        guard let idx = records.firstIndex(where: { $0.id == bookId }),
              let bmIdx = records[idx].bookmarks.firstIndex(where: { $0.id == bookmarkId })
        else { return }
        records[idx].bookmarks[bmIdx].note = note
        saveMeta()
    }

    func isBookmark(bookId: UUID, position: CoreTextReadingPosition) -> Bool {
        records.first(where: { $0.id == bookId })?.bookmarks.contains(where: {
            $0.position == position
        }) ?? false
    }

    /// 一頁一個書籤：這一頁上有沒有書籤。
    func isPageBookmarked(bookId: UUID, range: ReaderPageBookmarkRange) -> Bool {
        !pageBookmarks(bookId: bookId, in: range).isEmpty
    }

    // MARK: Incremental Content Update (download interruption protection)

    func updateBookContent(bookId: UUID, rawText: String) {
        guard let idx = records.firstIndex(where: { $0.id == bookId }) else { return }
        let filename = records[idx].contentFilename
        let fileURL = documentsURL(for: filename)
        do {
            try rawText.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            AppLogger.cache("Failed to write raw text chapter to \(fileURL): \(error)")
        }
    }

    // MARK: Edit Book Info

    func updateBook(bookId: UUID, title: String, author: String) {
        if let idx = records.firstIndex(where: { $0.id == bookId }) {
            records[idx].title = title.isEmpty ? records[idx].title : title
            records[idx].author = author.isEmpty ? records[idx].author : author
            saveMeta()
        }
    }

    // MARK: Bookshelf Grouping

    var allGroups: [String] {
        let groups = books.compactMap { $0.group.isEmpty ? nil : $0.group }
        return Array(Set(groups)).sorted()
    }

    func setGroup(_ group: String, for bookId: UUID) {
        setGroups([bookId: group])
    }

    /// Moves several books at once and saves once — AI 整理書架 applies a whole proposal.
    func setGroups(_ assignments: [UUID: String]) {
        var updated = records
        var changed = false
        for index in updated.indices {
            guard let group = assignments[updated[index].id], updated[index].group != group else { continue }
            updated[index].group = group
            changed = true
        }
        guard changed else { return }
        records = updated
        saveMeta()
    }

    // MARK: Delete Book

    /// Moves the records with the given `ids` before `targetId`.
    /// If `targetId` is nil, moves them to the end. Preserves relative order.
    func moveBooks(ids: [UUID], before targetId: UUID?) {
        guard !ids.isEmpty else { return }
        let idSet = Set(ids)
        let moving = records.filter { idSet.contains($0.id) }
        var rest = records.filter { !idSet.contains($0.id) }
        if let targetId, let idx = rest.firstIndex(where: { $0.id == targetId }) {
            rest.insert(contentsOf: moving, at: idx)
        } else {
            rest.append(contentsOf: moving)
        }
        records = rest
        saveMeta()
    }

    func delete(bookId: UUID) {
        Task { @MainActor in
            do { try await AICharacterMemoryService.shared.clear(book: bookId) }
            catch { AppLogger.error("Character memory cleanup failed") }
        }
        if let idx = records.firstIndex(where: { $0.id == bookId }) {
            let book = records[idx]
            // Read and now off the shelf — removed, or read from its detail page without
            // being added: its name stays for 搜索's 最近閱讀, as legado's 閱讀記錄
            // outlives the book.
            if let offShelfReadRecordsDefaults, let lastRead = book.lastOpenedDate {
                OffShelfReadRecords.record(
                    title: book.title,
                    author: book.author,
                    coverUrl: book.coverUrl ?? "",
                    at: lastRead,
                    defaults: offShelfReadRecordsDefaults
                )
            }
            if book.remoteSource != nil {
                // Removing a remote shelf reference keeps the same reading record
                // and explicit offline copy available from its library detail.
                records[idx].isInBookshelf = false
                persistReadingRecords()
                saveMetaImmediately()
                return
            }
            if book.isOnline {
                // Delete cache directory
                let cacheDir = StorageLocations.onlineCache.appendingPathComponent(bookId.uuidString)
                do {
                    try FileManager.default.removeItem(at: cacheDir)
                } catch {
                    AppLogger.cache("Failed to remove cache directory \(cacheDir): \(error)")
                }
            } else {
                do {
                    let fileUrl = documentsURL(for: book.contentFilename)
                    try FileManager.default.removeItem(at: fileUrl)
                } catch {
                    AppLogger.cache("Failed to remove document file \(book.contentFilename): \(error)")
                }
                if book.resolvedPipelineKind == .manga || book.resolvedPipelineKind == .fixedPage {
                    do {
                        try FileManager.default.removeItem(at: LocalMangaArchive.bookDirectory(bookId: book.id))
                    } catch {
                        AppLogger.cache("Failed to remove local manga directory for \(book.id): \(error)")
                    }
                }
                TXTChapterParser.deleteCachedIndexes(bookId: bookId)
                // Also delete EPUB font resource directory
                if book.isLegacyParsedEPUB {
                    let assetsDir = book.contentFilename.replacingOccurrences(
                        of: "_epub.json", with: "_epub_assets")
                    do {
                        let assetsUrl = documentsURL(for: assetsDir)
                        try FileManager.default.removeItem(at: assetsUrl)
                    } catch {
                        AppLogger.cache("Failed to remove assets directory \(assetsDir): \(error)")
                    }
                }
            }
            readerSettings.removeSettings(for: bookId)
            // legado's chapters go with their book (`ForeignKey.CASCADE`); so does the list here.
            chapterStore.removeChapters(for: bookId)
            // The 多角色朗讀 cast is keyed by book id and would otherwise outlive the book.
            let globalSettings = GlobalSettings.shared
            let remainingRoleVoices = TTSRoleVoiceCast.clearing(bookID: bookId, in: globalSettings.ttsRoleVoices)
            if remainingRoleVoices.count != globalSettings.ttsRoleVoices.count {
                globalSettings.ttsRoleVoices = remainingRoleVoices
            }
            // Nothing draws this book's covers any more: release their bitmaps. The
            // files themselves stay where deletion has always left them.
            let coverSources = [book.coverImagePath, book.originalCoverImagePath]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .map { CoverImageSource.bookCover(filename: $0) }
            CoverImagePipeline.shared.invalidate(Set(coverSources))
            records.remove(at: idx)
            saveMeta()
        }
    }

    // MARK: Add Online Book (from book source)

    @discardableResult
    func addOnlineBook(
        name: String, author: String,
        sourceId: UUID, bookInfoURL: String, tocURL: String? = nil,
        coverUrl: String = "",
        runtimeVariables: [String: String]? = nil,
        contentKind: OnlineBookContentKind? = nil,
        chapters: [OnlineChapterRef],
        isInBookshelf: Bool = true
    ) -> ReadingBook {
        var book = ReadingBook(
            title: name, author: author, source: bookInfoURL, contentFilename: "")
        book.isOnline = true
        book.isInBookshelf = isInBookshelf
        let source = BookSourceStore.shared.sources.first { $0.id == sourceId }
        let inferredKind = contentKind ?? OnlineBookContentInference.infer(
            sourceType: source?.bookSourceType,
            runtimeVariables: runtimeVariables,
            urls: [bookInfoURL, tocURL ?? ""],
            metadataText: OnlineBookContentInference.sourceRuntimeModeMarkers(for: source)
        )
        book.contentPipelineKind = inferredKind.pipelineKind
        book.bookSourceId = sourceId
        book.bookInfoURL = bookInfoURL
        book.tocURL = tocURL
        book.runtimeVariables = runtimeVariables
        if !coverUrl.isEmpty { book.coverUrl = coverUrl }
        book.onlineChapters = chapters.map { chapter in
            var sanitized = chapter
            sanitized.title = ReaderHTMLUtilities.displayText(fromHTMLFragment: chapter.title)
            return sanitized
        }
        records.insert(book, at: 0)
        saveMeta()
        downloadCoverIfNeeded(bookId: book.id, coverUrl: coverUrl, sourceId: sourceId)
        return book
    }

    @discardableResult
    func updateOnlineBookContentKind(bookId: UUID, kind: OnlineBookContentKind) -> Bool {
        guard let idx = records.firstIndex(where: { $0.id == bookId }) else { return false }
        guard records[idx].isOnline else { return false }
        let pipelineKind = kind.pipelineKind
        guard records[idx].contentPipelineKind != pipelineKind else { return false }
        records[idx].contentPipelineKind = pipelineKind
        saveMeta()
        return true
    }

    /// Promote an online book to the manga pipeline once a fetched chapter turns out
    /// to be an image page list. Aggregation sources report `bookSourceType == 0`
    /// (text) even when serving manga, so the only reliable signal is the content
    /// itself. After this flips, `BookReaderView` reactively swaps to the image
    /// reader and the change persists for future opens. Idempotent and cheap.
    @discardableResult
    func upgradeToMangaIfDetected(bookId: UUID, content: String, imageStyle: String? = nil) -> Bool {
        guard let idx = records.firstIndex(where: { $0.id == bookId }) else { return false }
        guard records[idx].isOnline, records[idx].contentPipelineKind != .manga else { return false }
        guard MangaChapterParser.looksLikeMangaContent(content, imageStyle: imageStyle) else { return false }
        records[idx].contentPipelineKind = .manga
        saveMeta()
        ReaderTelemetry.shared.log(
            "manga_autodetect",
            attributes: ["bookId": bookId.uuidString]
        )
        return true
    }

    /// Promote an online book to the audio pipeline once a fetched chapter turns
    /// out to be an audiobook stream. Aggregation sources report `bookSourceType
    /// == 0` (text) even when serving audiobooks, so the content itself is the
    /// only reliable signal. After this flips, `BookReaderView` reactively swaps
    /// to the audio player and the change persists for future opens. Idempotent.
    @discardableResult
    func upgradeToAudioIfDetected(bookId: UUID, content: String) -> Bool {
        guard let idx = records.firstIndex(where: { $0.id == bookId }) else { return false }
        guard records[idx].isOnline,
              records[idx].contentPipelineKind != .manga,
              records[idx].contentPipelineKind != .audio else { return false }
        guard DirectChapterAudioResolver.looksLikeAudioContent(content) else { return false }
        records[idx].contentPipelineKind = .audio
        saveMeta()
        ReaderTelemetry.shared.log(
            "audio_autodetect",
            attributes: ["bookId": bookId.uuidString]
        )
        return true
    }

    /// Download a remote cover (with source headers) and store it on the book.
    /// No-op when the URL is empty or the book already has a cover.
    func downloadCoverIfNeeded(bookId: UUID, coverUrl: String, sourceId: UUID?) {
        let trimmed = coverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let book = records.first(where: { $0.id == bookId }),
              book.coverImagePath == nil else { return }

        let source = sourceId.flatMap { id in BookSourceStore.shared.sources.first { $0.id == id } }
        let headers = BookCoverLoader.headers(
            sourceBaseURL: source?.bookSourceUrl,
            sourceHeaders: source?.parsedHeaders ?? [:]
        )
        CoverDecodeService.shared.registerIfNeeded(coverUrl: trimmed, source: source)
        let filename = "\(bookId.uuidString)_cover.jpg"
        Task { [weak self] in
            guard let saved = await BookCoverLoader.downloadAndSave(
                urlString: trimmed, headers: headers, filename: filename
            ) else { return }
            guard let self else { return }
            await MainActor.run { self.setCoverImagePath(bookId: bookId, filename: saved) }
        }
    }

    /// Assign a downloaded cover filename to a book and persist.
    func setCoverImagePath(bookId: UUID, filename: String) {
        guard let idx = records.firstIndex(where: { $0.id == bookId }) else { return }
        records[idx].coverImagePath = filename
        saveMeta()
    }

    // MARK: - Custom cover (封面搜索 / 相簿 / 手動網址)

    /// Download a cover the user picked in 書籍資訊 (封面搜索 result or a pasted
    /// address) and make it this book's cover.
    ///
    /// `sourceId` is the book source the cover URL came from — its headers are
    /// what make hotlink-protected CDN covers load at all, so a cover found in
    /// source B is downloaded with B's headers, not with the book's own source.
    /// Returns false when the image could not be fetched or decoded, so the
    /// caller can tell the user instead of silently keeping the old cover.
    @discardableResult
    @MainActor
    func applyCustomCover(bookId: UUID, coverUrl: String, sourceId: UUID?) async -> Bool {
        let trimmed = coverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, records.contains(where: { $0.id == bookId }) else { return false }

        let source = sourceId.flatMap { id in BookSourceStore.shared.sources.first { $0.id == id } }
        let headers = BookCoverLoader.headers(
            sourceBaseURL: source?.bookSourceUrl,
            sourceHeaders: source?.parsedHeaders ?? [:]
        )
        CoverDecodeService.shared.registerIfNeeded(coverUrl: trimmed, source: source)
        guard let image = await BookCoverLoader.loadImage(urlString: trimmed, headers: headers) else {
            AppLogger.network("[Cover] custom cover download failed url=\(trimmed)")
            return false
        }
        return storeCustomCover(bookId: bookId, image: image, customCoverUrl: trimmed)
    }

    /// Make a locally picked image (相簿 / 檔案) this book's cover. Downsampled on
    /// the way in, like every network cover, so a 12MP photo does not become a
    /// full-size decode in each shelf row.
    @discardableResult
    @MainActor
    func applyCustomCover(bookId: UUID, imageData: Data) -> Bool {
        guard let image = BookCoverLoader.decodedCover(from: imageData) else {
            AppLogger.render("[Cover] custom cover pick could not be decoded")
            return false
        }
        return storeCustomCover(
            bookId: bookId,
            image: image,
            customCoverUrl: ReadingBook.localCustomCoverMarker
        )
    }

    /// Writes the chosen image to the custom-cover directory and points the book
    /// at it.
    ///
    /// Each custom cover lands under a fresh filename rather than overwriting
    /// `<id>_cover.jpg`: the bookshelf reads covers straight off disk keyed by
    /// that filename, so reusing it leaves every already-rendered row showing the
    /// previous image until the app restarts.
    @MainActor
    private func storeCustomCover(bookId: UUID, image: UIImage, customCoverUrl: String) -> Bool {
        guard let idx = records.firstIndex(where: { $0.id == bookId }),
              let jpeg = image.jpegData(compressionQuality: 0.85) else { return false }

        // The marker routes the file to `StorageLocations.customCovers`, which
        // 快取管理 does not wipe — a photo-library pick has no second source.
        let filename =
            "\(bookId.uuidString)\(StorageLocations.customCoverFilenameMarker)"
            + "\(UUID().uuidString.prefix(8)).jpg"
        do {
            try BookCoverFileStore.live.write(jpeg, filename: filename)
        } catch {
            AppLogger.render("[Cover] could not write custom cover: \(error.localizedDescription)")
            return false
        }

        let previousPath = records[idx].coverImagePath
        // First customization only: keep whatever the source or the EPUB gave us
        // so 重設封面 has something to restore. Later changes replace each other.
        if records[idx].originalCoverImagePath == nil {
            records[idx].originalCoverImagePath = previousPath
        } else if let previousPath, previousPath != records[idx].originalCoverImagePath {
            removeCoverFile(previousPath)
        }
        records[idx].coverImagePath = filename
        records[idx].customCoverUrl = customCoverUrl
        // Picking a cover is a user-confirmed metadata transaction, like a source
        // switch: it must survive leaving 書籍資訊 and an immediate suspension. The
        // 2-second debounce is for high-frequency progress/TOC writes.
        saveMetaImmediately()
        return true
    }

    /// Drop the user's cover and go back to the source's / EPUB's own.
    ///
    /// The preserved original is not synced by iCloud (only `coverImagePath` is),
    /// so on a restored device the file can be gone — that case re-downloads from
    /// `coverUrl` instead of leaving the book with no cover at all.
    @MainActor
    func resetCover(bookId: UUID) {
        guard let idx = records.firstIndex(where: { $0.id == bookId }) else { return }
        let customPath = records[idx].coverImagePath
        let originalPath = records[idx].originalCoverImagePath

        records[idx].customCoverUrl = nil
        records[idx].originalCoverImagePath = nil

        if let originalPath,
           FileManager.default.fileExists(atPath: StorageLocations.coverFileLocation(originalPath).path) {
            records[idx].coverImagePath = originalPath
            if let customPath, customPath != originalPath { removeCoverFile(customPath) }
            // Immediate for the same reason as `storeCustomCover`, and because the
            // custom file is already deleted — a lost write would leave the book
            // pointing at a cover that no longer exists.
            saveMetaImmediately()
            return
        }

        records[idx].coverImagePath = nil
        if let customPath { removeCoverFile(customPath) }
        saveMetaImmediately()
        downloadCoverIfNeeded(
            bookId: bookId,
            coverUrl: records[idx].coverUrl ?? "",
            sourceId: records[idx].bookSourceId
        )
    }

    private func removeCoverFile(_ filename: String) {
        BookCoverFileStore.live.remove(filename: filename)
    }

    // MARK: Add Browser-Imported Book (no book source; lazy-loads by URL)

    @discardableResult
    func addWebBrowsedBook(
        name: String, author: String,
        sourceURL: String,
        chapters: [OnlineChapterRef]
    ) -> ReadingBook {
        var book = ReadingBook(title: name, author: author, source: sourceURL, contentFilename: "")
        book.isOnline = true
        book.contentPipelineKind = .html
        book.bookSourceId = nil  // nil indicates browser-converted book, independent of book sources
        book.bookInfoURL = sourceURL
        book.onlineChapters = chapters.map { chapter in
            var sanitized = chapter
            sanitized.title = ReaderHTMLUtilities.displayText(fromHTMLFragment: chapter.title)
            return sanitized
        }
        records.insert(book, at: 0)
        saveMeta()
        return book
    }

    // MARK: Update Cached Chapters

    func updateCachedChapter(bookId: UUID, chapterIndex: Int, filename: String) {
        guard records.contains(where: { $0.id == bookId }),
            var chapters = chapterStore.chapters(for: bookId),
            let ci = chapters.firstIndex(where: { $0.index == chapterIndex }),
            chapters[ci].cachedFilename != filename
        else { return }
        chapters[ci].cachedFilename = filename
        // The list changes, the record does not: a cache mark is not a shelf change, and
        // going through `records` published the whole store to every view on it once per
        // chapter a download fetched. legado's `BookHelp.saveContent` writes the file and
        // touches no book row either. The list is written by the next shelf save.
        chapterStore.setChapters(chapters, for: bookId)
        saveMeta()
    }

    func clearCachedChapter(bookId: UUID, chapterIndex: Int) {
        guard let idx = records.firstIndex(where: { $0.id == bookId }),
            var chapters = chapterStore.chapters(for: bookId)
        else { return }
        if let ci = chapters.firstIndex(where: { $0.index == chapterIndex }) {
            chapters[ci].cachedFilename = nil
            records[idx].onlineChapters = chapters
            saveMeta()
        }
    }

    /// Clears all cachedFilename markers for a book without affecting offlineDownloadState.
    /// Used alongside `clearAllChapterCache` during refresh to reset the book's cache state.
    func clearAllCachedChapterFilenames(bookId: UUID) {
        guard let idx = records.firstIndex(where: { $0.id == bookId }),
            var chapters = chapterStore.chapters(for: bookId)
        else { return }
        var changed = false
        for i in chapters.indices where chapters[i].cachedFilename != nil {
            chapters[i].cachedFilename = nil
            changed = true
        }
        guard changed else { return }
        records[idx].onlineChapters = chapters
        saveMeta()
    }

    // Called from OfflineDownloadManager's actor. Both publications and the cache-clear
    // notification can synchronously rebuild a mounted reader, including UIKit constraints.
    @MainActor
    func clearOnlineDownload(
        bookId: UUID,
        offlineChapterStore: any OfflineChapterStoring = OfflineChapterStore()
    ) async throws {
        guard let removing = records.first(where: { $0.id == bookId }) else { return }
        // Every chapter is about to go back to the network for the first time since the
        // download was made. Doing that against a table of contents the cache has been
        // replaying unchanged — it is keyed by `(sourceId, url)` and outlives the book — is
        // what turned 移除下載 into "the whole book fails and only 換源 fixes it".
        if let sourceId = removing.bookSourceId,
           let source = BookSourceStore.shared.sources.first(where: { $0.id == sourceId }) {
            BookSourceFetcher.shared.clearTOCAndBookInfoCache(
                tocUrl: removing.tocURL,
                bookURL: removing.bookInfoURL,
                source: source
            )
        }
        try await offlineChapterStore.removeBook(bookId: bookId)
        // `records` can be mutated while the artifact removal is in flight (imports
        // insert at 0, deletions remove rows), so the row has to be located again:
        // an index resolved before the await could now address a different book,
        // or be past the end of the array.
        guard let idx = records.firstIndex(where: { $0.id == bookId }) else { return }
        if var chapters = chapterStore.chapters(for: bookId) {
            for chapterIndex in chapters.indices {
                chapters[chapterIndex].cachedFilename = nil
            }
            records[idx].onlineChapters = chapters
        }
        records[idx].offlineDownloadState = .none
        records[idx].downloadedChapterCount = 0
        records[idx].offlineDownloadTask = nil
        DownloadLiveActivityController.refresh(books: books)
        // The cache was already removed from disk; persist the matching state
        // now so a quick relaunch cannot resurrect a stale completed download.
        saveMetaImmediately()
        // An open reader still holds `.ready` chapter states for the files just deleted, and
        // nothing else would tell it otherwise: no load state changed and no chapter was
        // entered, so neither of the reader's mismatch checks runs. Left alone it renders
        // 資料不一致 over a chapter it could simply refetch.
        NotificationCenter.default.post(
            name: .onlineChapterCacheDidClear,
            object: nil,
            userInfo: ["bookId": bookId]
        )
    }

    // MARK: Update Online Book TOC (called after progressive TOC load completes)

    func updateOnlineChapters(
        bookId: UUID,
        chapters: [OnlineChapterRef],
        runtimeVariables: [String: String]? = nil
    ) {
        guard let idx = records.firstIndex(where: { $0.id == bookId }) else { return }
        records[idx].onlineChapters = chapters
        if let runtimeVariables, !runtimeVariables.isEmpty {
            records[idx].runtimeVariables = runtimeVariables
        }
        saveMeta()
    }

    // MARK: Switch Book Source

    /// Switches the book to a new source: fetches new TOC, updates book-source metadata,
    /// replaces onlineChapters, and clears the chapter cache.
    /// 設置書籍變量 editor: replaces the book's runtime-variable map (the values
    /// a source's JS reads back as book variables on subsequent fetches).
    func updateBookRuntimeVariables(bookId: UUID, variables: [String: String]?) {
        guard let idx = records.firstIndex(where: { $0.id == bookId }) else { return }
        let normalized = (variables?.isEmpty ?? true) ? nil : variables
        records[idx].runtimeVariables = normalized
        saveMeta()
    }

    /// Commits a source switch. `preparedTOC` is the table of contents the caller already
    /// fetched — the reader resolves it up front so it can show progress and stay cancellable,
    /// and passing it here is what stops the switch from fetching the same TOC a second time
    /// (Legado hands the toc to `changeTo(source, book, toc)` for the same reason).
    func updateOnlineBookSource(
        bookId: UUID,
        origin: BookOrigin,
        preparedTOC: TOCPackage? = nil,
        bookSourceFetcher: any BookSourceFetching = LiveBookSourceFetcher(bookSourceFetcher: BookSourceFetcher.shared),
        offlineChapterStore: any OfflineChapterStoring = OfflineChapterStore()
    ) async throws {
        guard let source = BookSourceStore.shared.sources.first(where: { $0.id == origin.sourceId })
        else {
            throw NSError(
                domain: "BookStore", code: -1, userInfo: [NSLocalizedDescriptionKey: "找不到書源"])
        }
        let tocPackage: TOCPackage
        if let preparedTOC {
            tocPackage = preparedTOC
        } else {
            tocPackage = try await bookSourceFetcher.fetchTOCPackage(
                tocUrl: origin.tocUrl, source: source, runtimeVariables: origin.runtimeVariables)
        }
        // `fetchTOCPackage` returns an empty package instead of throwing when a source's TOC
        // rules match nothing, and committing that wipes `onlineChapters`: the book loses its
        // chapter list, the reader's 刷新 action disappears (it is gated on a non-empty list),
        // and only a reopen — which re-runs `refreshOnlineBookMetadata` — brings it back.
        // A switch that cannot produce chapters has failed; leave the old source intact.
        guard !tocPackage.chapters.isEmpty else {
            throw NSError(
                domain: "BookStore", code: -5,
                userInfo: [NSLocalizedDescriptionKey: localized("此書源取不到目錄")])
        }
        let oldRefs = await MainActor.run {
            chapterStore.chapters(for: bookId) ?? []
        }
        try await SourcePerfTrace.spanAsync(
            "changeSource.reconcileOffline", "\(max(oldRefs.count, tocPackage.chapters.count))ch"
        ) {
            try await offlineChapterStore.reconcileBook(
                bookId: bookId,
                oldRefs: oldRefs,
                newRefs: tocPackage.chapters,
                // A confirmed rebinding to a different source: the old source's chapter
                // bytes are genuinely worthless here, and the user asked for it.
                disposition: .deleteMismatched
            )
        }
        await MainActor.run {
            guard let idx = records.firstIndex(where: { $0.id == bookId }) else { return }
            records[idx].bookSourceId = origin.sourceId
            records[idx].bookInfoURL = origin.bookUrl
            records[idx].tocURL = origin.tocUrl
            records[idx].runtimeVariables = origin.runtimeVariables
            records[idx].onlineChapters = tocPackage.chapters
            // A source switch is a user-confirmed metadata transaction. It must
            // survive leaving the reader or immediate app suspension; the normal
            // debounce is reserved for high-frequency progress/TOC updates.
            saveMetaImmediately()
        }
        let staleIndices = await Task.detached(priority: .userInitiated) {
            Self.changedChapterIdentities(oldRefs: oldRefs, newRefs: tocPackage.chapters)
        }.value
        await SourcePerfTrace.spanAsync("changeSource.reconcileTask") {
            await reconcileOfflineTaskMetadata(
                bookId: bookId,
                oldRefs: oldRefs,
                newRefs: tocPackage.chapters,
                staleIndices: staleIndices
            )
        }
    }

    @discardableResult
    func refreshOnlineBookMetadata(
        bookId: UUID,
        forceInfoRefresh: Bool = false,
        bookSourceFetcher: any BookSourceFetching = LiveBookSourceFetcher(bookSourceFetcher: BookSourceFetcher.shared),
        offlineChapterStore: any OfflineChapterStoring = OfflineChapterStore(),
        onFirstChaptersReady: (@MainActor (ReadingBook) -> Void)? = nil
    ) async throws -> ReadingBook {
        guard let snapshot = await MainActor.run(body: {
            records.first(where: { $0.id == bookId }).flatMap { $0.isOnline ? $0 : nil }
        }) else {
            throw NSError(
                domain: "BookStore", code: -2, userInfo: [NSLocalizedDescriptionKey: "找不到線上書籍"])
        }

        // Snapshot of what the user has already seen, so the final merge can tell
        // whether this refresh actually brought in newer chapters (drives the
        // "更新" badge on the bookshelf). Read off the main thread: the list of a
        // 2000-chapter book is a 2MB file, and the launch refresh walks the whole shelf.
        // (Detached on purpose — with approachable concurrency an `async` function runs on
        // its caller's actor, and the launch refresh is called from the main actor.)
        let (originalChapterCount, originalLatestTitle) = await Task.detached(priority: .utility) { [chapterStore] in
            let originalChapters = chapterStore.chapters(for: bookId) ?? []
            return (originalChapters.count, Self.normalizeChapterTitle(originalChapters.last?.title ?? ""))
        }.value

        guard let sourceId = snapshot.bookSourceId else {
            return snapshot
        }
        guard let source = await MainActor.run(body: {
            BookSourceStore.shared.sources.first(where: { $0.id == sourceId })
        }) else {
            throw NSError(
                domain: "BookStore", code: -3, userInfo: [NSLocalizedDescriptionKey: "找不到書源"])
        }

        let bookURL = normalizedOnlineValue(snapshot.bookInfoURL ?? snapshot.source)
        guard !bookURL.isEmpty else {
            throw NSError(
                domain: "BookStore", code: -4, userInfo: [NSLocalizedDescriptionKey: "缺少書籍詳情頁 URL"])
        }

        var runtimeVariables = snapshot.runtimeVariables
        var tocURL = normalizedOnlineValue(snapshot.tocURL)
        var infoPackage: BookInfoPackage?

        if forceInfoRefresh || tocURL.isEmpty {
            // The shelf already knows this book — hand that over so a detail page that omits a
            // field leaves the stored value alone. Most sources' `ruleBookInfo.name` is empty
            // (they rely on the caller keeping the title it already had, as legado's
            // `analyzeBookInfo` does), and a refresh must never blank a shelved book's title.
            let knownBook = OnlineBook(
                name: snapshot.title,
                author: snapshot.author,
                intro: "",   // ReadingBook does not store an intro; nothing to preserve here
                coverUrl: snapshot.coverUrl ?? "",
                bookUrl: bookURL,
                tocUrl: normalizedOnlineValue(snapshot.tocURL),
                wordCount: "",
                lastChapter: snapshot.onlineChapters?.last?.title ?? "",
                kind: "",
                sourceId: sourceId,
                sourceName: source.bookSourceName,
                runtimeVariables: runtimeVariables
            )
            let fetchedInfo = try await bookSourceFetcher.fetchBookInfoPackage(
                url: bookURL,
                source: source,
                runtimeVariables: runtimeVariables,
                knownBook: knownBook
            )
            infoPackage = fetchedInfo
            if let fetchedRuntime = fetchedInfo.runtimeVariables, !fetchedRuntime.isEmpty {
                runtimeVariables = fetchedRuntime
            }
            let discoveredTOC = normalizedOnlineValue(fetchedInfo.tocUrl)
            if !discoveredTOC.isEmpty {
                tocURL = discoveredTOC
            }
        }

        if tocURL.isEmpty {
            tocURL = bookURL
        }

        let progressiveTOCURL = tocURL
        let progressiveRuntimeVariables = runtimeVariables
        let progressiveInfoPackage = infoPackage

        let tocPackage = try await bookSourceFetcher.fetchTOCPackage(
            tocUrl: tocURL,
            source: source,
            runtimeVariables: runtimeVariables,
            onFirstPageReady: { [weak self] firstChapters in
                guard let self else { return }
                Task.detached(priority: .utility) {
                    guard OnlineTOCCommitPolicy.decide(
                        refreshedCount: firstChapters.count
                    ) == .commit else {
                        AppLogger.network("⟐ TOC first page came back empty, not committing", context: [
                            "bookId": bookId.uuidString,
                        ])
                        return
                    }
                    // Merging and comparing 2000-chapter lists normalizes every title; done
                    // here, off the main thread, and the record is replaced once below.
                    let existingChapters = self.chapterStore.chapters(for: bookId) ?? []
                    let mergedChapters = Self.mergeOnlineChapters(
                        existing: existingChapters,
                        refreshed: firstChapters,
                        preservingExistingTail: true
                    )
                    let chaptersChanged = Self.chapterListChanged(existing: existingChapters, refreshed: firstChapters)
                    let listChanged = mergedChapters != existingChapters
                    await MainActor.run {
                        guard let idx = self.records.firstIndex(where: { $0.id == bookId }) else { return }
                        var updated = self.records[idx]
                        let tocChanged = self.normalizedOnlineValue(updated.tocURL) != progressiveTOCURL
                        let runtimeChanged = (updated.runtimeVariables ?? [:]) != (progressiveRuntimeVariables ?? [:])
                        updated.bookSourceId = source.id
                        updated.bookInfoURL = bookURL
                        updated.tocURL = progressiveTOCURL
                        updated.runtimeVariables = progressiveRuntimeVariables
                        updated.onlineChapters = mergedChapters
                        if let progressiveInfoPackage {
                            let resolvedName = self.normalizedOnlineValue(progressiveInfoPackage.name)
                            let resolvedAuthor = self.normalizedOnlineValue(progressiveInfoPackage.author)
                            if !resolvedName.isEmpty {
                                updated.title = resolvedName
                            }
                            if !resolvedAuthor.isEmpty {
                                updated.author = resolvedAuthor
                            }
                        }
                        let titleChanged = updated.title != self.records[idx].title
                        let authorChanged = updated.author != self.records[idx].author
                        let sourceChanged = updated.bookSourceId != self.records[idx].bookSourceId
                            || updated.bookInfoURL != self.records[idx].bookInfoURL
                        // One assignment, and only for a change: every assignment publishes
                        // the whole store to every view on it.
                        if runtimeChanged || chaptersChanged || listChanged || tocChanged
                            || titleChanged || authorChanged || sourceChanged {
                            self.records[idx] = updated
                        }
                        if runtimeChanged || chaptersChanged || tocChanged || titleChanged || authorChanged {
                            self.saveMeta()
                        }
                        onFirstChaptersReady?(self.readingBook(id: bookId) ?? self.records[idx])
                    }
                }
            },
            // Always hit the network here: this is the "check for new chapters"
            // path, so the stale cached TOC must be bypassed or serial novels
            // never pick up newly-published chapters.
            forceRefresh: true
        )
        if let fetchedRuntime = tocPackage.runtimeVariables, !fetchedRuntime.isEmpty {
            runtimeVariables = fetchedRuntime
        }

        let finalTOCURL = tocURL
        let finalRuntimeVariables = runtimeVariables
        let finalInfoPackage = infoPackage

        // Returning early here leaves `onlineChapters` — and therefore the reconcile that
        // reads it — completely untouched. See `OnlineTOCCommitPolicy`.
        guard OnlineTOCCommitPolicy.decide(
            refreshedCount: tocPackage.chapters.count
        ) == .commit else {
            AppLogger.network("⟐ TOC refresh came back empty, keeping existing chapters", context: [
                "bookId": bookId.uuidString,
                "existing": chapterStore.chapters(for: bookId)?.count ?? 0,
            ])
            return snapshot
        }

        // The merge, the comparison and the stale-chapter scan each normalize every title
        // of both lists — on a 2000-chapter book that was ~100ms on the main thread per
        // refreshed book, with the launch refresh walking the whole shelf. All of it runs
        // here; the main thread only replaces the record, once, and only for a change.
        // Detached, and through a static helper: with approachable concurrency this function
        // and any local function of it run on the caller's actor, which for the launch
        // refresh is the main one.
        let refreshed = tocPackage.chapters
        let prepared = await Task.detached(priority: .utility) { [chapterStore] in
            Self.mergePlan(
                existing: chapterStore.chapters(for: bookId) ?? [], refreshed: refreshed,
                originalChapterCount: originalChapterCount, originalLatestTitle: originalLatestTitle
            )
        }.value

        let updateResult = await MainActor.run { () -> (ReadingBook, MergePlan)? in
            guard let idx = records.firstIndex(where: { $0.id == bookId }) else {
                return nil
            }
            // A chapter cached while the plan was being made (a download marks one per
            // chapter) changed the list under it; plan again from what is there now.
            let current = chapterStore.chapters(for: bookId) ?? []
            let plan = current == prepared.existing ? prepared : Self.mergePlan(
                existing: current, refreshed: refreshed,
                originalChapterCount: originalChapterCount, originalLatestTitle: originalLatestTitle
            )
            let mergedChapters = plan.merged
            let chaptersChanged = plan.chaptersChanged
            let listChanged = plan.listChanged
            let gainedChapters = plan.gainedChapters
            var updated = records[idx]
            let tocChanged = normalizedOnlineValue(updated.tocURL) != finalTOCURL
            let runtimeChanged = (updated.runtimeVariables ?? [:]) != (finalRuntimeVariables ?? [:])

            updated.bookSourceId = source.id
            updated.bookInfoURL = bookURL
            updated.tocURL = finalTOCURL
            updated.runtimeVariables = finalRuntimeVariables
            updated.onlineChapters = mergedChapters

            if let finalInfoPackage {
                let resolvedName = normalizedOnlineValue(finalInfoPackage.name)
                let resolvedAuthor = normalizedOnlineValue(finalInfoPackage.author)
                if !resolvedName.isEmpty {
                    updated.title = resolvedName
                }
                if !resolvedAuthor.isEmpty {
                    updated.author = resolvedAuthor
                }
            }
            if gainedChapters {
                updated.hasNewChapterUpdate = true
            }

            let titleChanged = updated.title != records[idx].title
            let authorChanged = updated.author != records[idx].author
            let sourceChanged = updated.bookSourceId != records[idx].bookSourceId
                || updated.bookInfoURL != records[idx].bookInfoURL
            let badgeChanged = updated.hasNewChapterUpdate != records[idx].hasNewChapterUpdate

            if runtimeChanged || chaptersChanged || listChanged || tocChanged
                || titleChanged || authorChanged || sourceChanged || badgeChanged {
                records[idx] = updated
            }
            if runtimeChanged || chaptersChanged || tocChanged || titleChanged || authorChanged || gainedChapters {
                saveMeta()
            }
            return (readingBook(id: bookId) ?? records[idx], plan)
        }

        guard let (updated, committed) = updateResult else {
            return snapshot
        }
        let oldRefs = committed.existing
        let newRefs = committed.merged
        let staleIndices = committed.staleIndices

        do {
            try await offlineChapterStore.reconcileBook(
                bookId: bookId,
                oldRefs: oldRefs,
                newRefs: newRefs,
                // A refresh asks about chapter *lists*; it is never a request to discard
                // chapter *bytes*. `reconcileOfflineTaskMetadata` below still nulls
                // `cachedFilename` and re-pends every mismatched index, so those chapters
                // are refetched on demand — the files just stop being deleted behind the
                // user's back.
                disposition: .preserveContent
            )
        } catch {
            await reconcileOfflineTaskMetadata(
                bookId: bookId,
                oldRefs: oldRefs,
                newRefs: newRefs,
                staleIndices: staleIndices
            )
            throw error
        }
        await reconcileOfflineTaskMetadata(
            bookId: bookId,
            oldRefs: oldRefs,
            newRefs: newRefs,
            staleIndices: staleIndices
        )

        return updated
    }

    private struct MergePlan {
        let existing: [OnlineChapterRef]
        let merged: [OnlineChapterRef]
        let chaptersChanged: Bool
        let listChanged: Bool
        let gainedChapters: Bool
        let staleIndices: Set<Int>
    }

    /// Everything a table-of-contents refresh decides from the two lists. Normalizes every
    /// title of both several times over; call it off the main thread.
    private static func mergePlan(
        existing: [OnlineChapterRef],
        refreshed: [OnlineChapterRef],
        originalChapterCount: Int,
        originalLatestTitle: String
    ) -> MergePlan {
        let merged = mergeOnlineChapters(existing: existing, refreshed: refreshed)
        // Surface newly-arrived chapters on the bookshelf. Only flag when the
        // book already had chapters (avoids marking a first-time population)
        // and the latest chapter moved on — more chapters, or a new tail title.
        let gained = originalChapterCount > 0
            && (merged.count > originalChapterCount
                || normalizeChapterTitle(merged.last?.title ?? "") != originalLatestTitle)
        return MergePlan(
            existing: existing,
            merged: merged,
            chaptersChanged: chapterListChanged(existing: existing, refreshed: refreshed),
            listChanged: merged != existing,
            gainedChapters: gained,
            staleIndices: changedChapterIdentities(oldRefs: existing, newRefs: merged)
        )
    }

    /// Indices present in both lists whose chapter is no longer the same one (different
    /// URL or title), so a cached file under that index belongs to another chapter.
    /// Normalizes every title of both lists; call it off the main thread.
    private static func changedChapterIdentities(
        oldRefs: [OnlineChapterRef],
        newRefs: [OnlineChapterRef]
    ) -> Set<Int> {
        var changed: Set<Int> = []
        for index in 0..<min(oldRefs.count, newRefs.count) {
            let sameURL = normalizedOnlineValue(oldRefs[index].url)
                == normalizedOnlineValue(newRefs[index].url)
            let sameTitle = normalizeChapterTitle(oldRefs[index].title)
                == normalizeChapterTitle(newRefs[index].title)
            if !sameURL || !sameTitle {
                changed.insert(index)
            }
        }
        return changed
    }

    /// - Parameter staleIndices: `changedChapterIdentities(oldRefs:newRefs:)`, computed off
    ///   the main thread; this runs on it and only walks the list.
    @MainActor
    private func reconcileOfflineTaskMetadata(
        bookId: UUID,
        oldRefs: [OnlineChapterRef],
        newRefs: [OnlineChapterRef],
        staleIndices: Set<Int>
    ) {
        guard let idx = records.firstIndex(where: { $0.id == bookId }) else { return }
        var invalidatedIndices: Set<Int> = []
        if var chapters = chapterStore.chapters(for: bookId) {
            var listChanged = false
            for index in chapters.indices {
                let inBothLists = oldRefs.indices.contains(index) && newRefs.indices.contains(index)
                let stale = !inBothLists || staleIndices.contains(index)
                if stale, oldRefs.indices.contains(index) {
                    invalidatedIndices.insert(index)
                }
                if stale, chapters[index].cachedFilename != nil {
                    chapters[index].cachedFilename = nil
                    listChanged = true
                }
            }
            if listChanged {
                records[idx].onlineChapters = chapters
            }
        }
        if var task = records[idx].offlineDownloadTask?.clamped(to: newRefs.count) {
            for index in invalidatedIndices where task.requestedIndices.contains(index) {
                task.markPending(index)
            }
            replaceOfflineDownloadTask(bookId: bookId, task: task, isRunning: false)
        } else if records[idx].offlineDownloadTask != nil {
            records[idx].offlineDownloadTask = nil
            records[idx].offlineDownloadState = .none
            records[idx].downloadedChapterCount = 0
            saveMetaImmediately()
        } else {
            saveMeta()
        }
    }

    // MARK: Private Methods

    private func saveBook(
        title: String,
        author: String,
        content: String,
        source: String,
        format: ImportedBookContentFormat = .plainText
    ) throws -> ReadingBook {
        let filename = "\(UUID().uuidString).\(format.fileExtension)"
        let fileURL = documentsURL(for: filename)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        var book = ReadingBook(
            title: title, author: author, source: source, contentFilename: filename)
        book.contentPipelineKind = (format == .html) ? .html : .txt
        records.insert(book, at: 0)
        saveMeta()
        return book
    }

    /// Book content files stay in Documents: they are the user's own files, and being
    /// visible in the Files app is the point.
    private func documentsURL(for filename: String) -> URL {
        StorageLocations.bookFile(filename)
    }

    func localEPUBURL(for book: ReadingBook) -> URL {
        let epubFilename = book.contentFilename.hasSuffix(".epub")
            ? book.contentFilename
            : book.contentFilename.replacingOccurrences(of: "_epub.json", with: ".epub")
        return documentsURL(for: epubFilename)
    }

    /// The on-disk book file to hand to a share sheet (the EPUB/TXT itself), or nil for online books
    /// (no local file) and missing files.
    func shareableFileURL(for book: ReadingBook) -> URL? {
        guard !book.isOnline, !book.contentFilename.isEmpty else { return nil }
        // EPUB-derived records may store an `_epub.json` sidecar; share the real `.epub`.
        if book.contentFilename.hasSuffix(".epub") || book.contentFilename.hasSuffix("_epub.json") {
            let epubURL = localEPUBURL(for: book)
            if FileManager.default.fileExists(atPath: epubURL.path) {
                return epubURL
            }
        }
        let direct = documentsURL(for: book.contentFilename)
        return FileManager.default.fileExists(atPath: direct.path) ? direct : nil
    }

    /// Longest a pending metadata write may be deferred, however many times the debounce is
    /// re-armed. Cancel-and-reschedule with no ceiling starves the write entirely whenever
    /// edits arrive faster than the debounce window — a download completing a chapter every
    /// second never persisted a single one, so an app kill lost the whole run.
    private static let metadataSaveMaximumDelay: TimeInterval = 10

    private func saveMeta() {
        saveWorkItem?.cancel()
        saveGeneration += 1
        let generation = saveGeneration

        let now = Date()
        if firstPendingSaveRequestedAt == nil {
            firstPendingSaveRequestedAt = now
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.saveGeneration == generation else { return }
            self.saveWorkItem = nil
            self.firstPendingSaveRequestedAt = nil
            self.persistMetadataIfChanged(inBackground: true)
        }

        saveWorkItem = workItem
        // Debounce writes by 2 seconds to avoid frequent UI stalls, but never let the oldest
        // unwritten edit sit longer than `metadataSaveMaximumDelay`.
        let elapsed = now.timeIntervalSince(firstPendingSaveRequestedAt ?? now)
        let delay = max(0, min(2.0, Self.metadataSaveMaximumDelay - elapsed))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    /// Immutable input and encoded output share the same local revision. The worker
    /// never reads the store or writes files, so a late result cannot overwrite a
    /// newer progress save, import, deletion, or another sync application.
    struct SyncSnapshot {
        fileprivate let records: [ReadingBook]
        fileprivate let revision: UInt64
    }

    struct EncodedSyncSnapshot {
        fileprivate let snapshot: SyncSnapshot
        fileprivate let shelfData: Data
        fileprivate let readingData: Data
    }

    private static let syncEncodingQueue = DispatchQueue(
        label: "com.yuedu.library.sync-metadata", qos: .utility
    )

    @MainActor
    func snapshotForSync(_ syncedBooks: [ReadingBook], expectedMutationRevision: UInt64? = nil) -> SyncSnapshot? {
        if let expectedMutationRevision, expectedMutationRevision != mutationRevision { return nil }
        // The table of contents is this device's own: `chapterStore` keeps it, and the
        // record's summary is derived from it. A synced copy carries none, except one a build
        // before the store uploaded — an older list, taken only by a device that has none.
        let localRecords = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let shelf = syncedBooks.map { book in
            var merged = book.withoutTableOfContents()
            merged.isInBookshelf = true
            if let incoming = book.onlineChapters, !incoming.isEmpty, !chapterStore.hasList(for: book.id) {
                merged.onlineChapters = incoming
                merged.applyChapterSummary(from: incoming)
            } else {
                merged.totalChapterNum = localRecords[book.id]?.totalChapterNum
                merged.latestChapterTitle = localRecords[book.id]?.latestChapterTitle
            }
            return merged
        }.sorted { lhs, rhs in
            (lhs.lastOpenedDate ?? lhs.addedDate) > (rhs.lastOpenedDate ?? rhs.addedDate)
        }
        let ids = Set(shelf.map(\.id))
        return SyncSnapshot(records: shelf + records.filter { !$0.isInBookshelf && !ids.contains($0.id) },
                            revision: mutationRevision)
    }

    static func encodeSyncSnapshot(_ snapshot: SyncSnapshot) async throws -> EncodedSyncSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            syncEncodingQueue.async {
                dispatchPrecondition(condition: .notOnQueue(.main))
                do {
                    let result = try SourcePerfTrace.span("sync.encode.books", "count=\(snapshot.records.count) main=false") {
                        try encodeSyncSnapshotData(snapshot)
                    }
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func encodeSyncSnapshotData(_ snapshot: SyncSnapshot) throws -> EncodedSyncSnapshot {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try EncodedSyncSnapshot(snapshot: snapshot,
            shelfData: encoder.encode(snapshot.records.filter(\.isInBookshelf)),
            readingData: encoder.encode(snapshot.records.filter { !$0.isInBookshelf }))
    }

    @discardableResult
    @MainActor
    func applySyncSnapshot(_ prepared: EncodedSyncSnapshot) -> Bool {
        guard prepared.snapshot.revision == mutationRevision else { return false }
        replaceRecords(prepared.snapshot.records)
        cancelPendingMetadataSave()
        let bookIDs = Set(records.map(\.id))
        if recordsLoadedCompletely { chapterStore.removeChapters(notIn: bookIDs) }
        persistMetadata(prepared.shelfData, readingData: prepared.readingData)
        readerSettings.removeSettings(notIn: bookIDs)
        return true
    }

    /// Every book this device holds a record of, on the shelf or only read.
    var recordIDs: Set<UUID> { Set(records.map(\.id)) }

    /// Books added on devices still on a build from before the iCloud sync split
    /// (2026-10-05), taken onto the shelf under the id they carry, so a book is one book
    /// when those devices update. Only ids with no record here: a book this device holds,
    /// on the shelf or only read, stays as it is.
    ///
    /// - Returns: how many were taken.
    @discardableResult
    @MainActor
    func adoptBooksAddedByOlderBuilds(_ books: [ReadingBook]) -> Int {
        var known = recordIDs
        let adopted = books.compactMap { book -> ReadingBook? in
            guard known.insert(book.id).inserted else { return nil }
            var shelved = book
            shelved.isInBookshelf = true
            return shelved
        }
        guard !adopted.isEmpty else { return 0 }
        records = adopted + records
        saveMeta()
        return adopted.count
    }

    /// Synchronous callers retain their immediate durability boundary. Live cloud
    /// sync uses snapshot → worker encoding → revision-checked application instead.
    @discardableResult
    @MainActor
    func replaceBooksFromSync(_ syncedBooks: [ReadingBook], expectedMutationRevision: UInt64? = nil) -> Bool {
        guard let snapshot = snapshotForSync(syncedBooks, expectedMutationRevision: expectedMutationRevision),
              let prepared = try? Self.encodeSyncSnapshotData(snapshot) else { return false }
        return applySyncSnapshot(prepared)
    }

    private func cancelPendingMetadataSave() {
        saveWorkItem?.cancel()
        saveGeneration += 1
        saveWorkItem = nil
        firstPendingSaveRequestedAt = nil
    }

    private func saveMetaImmediately() {
        cancelPendingMetadataSave()
        persistMetadataIfChanged(inBackground: false)
    }

    /// Writes a debounced save now. The scene calls this on its way out of the
    /// foreground: an app killed from the app switcher, or while suspended, never ran
    /// the pending write, and a book added to the shelf just before was gone.
    func flushPendingMetadataSave() {
        guard saveWorkItem != nil else {
            // A background write already in flight finishes before the scene is gone.
            Self.persistQueue.sync {}
            return
        }
        saveMetaImmediately()
    }

    /// Reindexing changes the meaning of chapter numbers. Publish bookmark changes
    /// only after their full metadata snapshot is durably written, and reject edits
    /// made while the migration was measuring source/rendered correspondence.
    @MainActor
    func commitTXTBookmarks(bookId: UUID, original: [Bookmark], migrated: [Bookmark]) throws {
        guard let index = records.firstIndex(where: { $0.id == bookId }),
              records[index].bookmarks == original || records[index].bookmarks == migrated else {
            throw TXTLocationMigration.Failure.missingSourceIdentity
        }
        var updated = records[index]
        updated.bookmarks = migrated
        let output = records.map { $0.id == bookId ? updated : $0 }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(output.filter { $0.isInBookshelf == updated.isInBookshelf })
        // Changed lists become durable with this write, as when they rode inside the shelf.
        // On `persistQueue`, after any background write in flight.
        try Self.persistQueue.sync {
            chapterStore.flush()
            try data.write(to: updated.isInBookshelf ? metadataFileURL : readingMetadataFileURL, options: .atomic)
        }
        records[index] = updated
        persistSequence &+= 1
        lastAppliedPersistSequence = persistSequence
        if updated.isInBookshelf { markMetadataPersisted(data, records: output); syncWidgetData() }
        else { notePersistedReadingData(data) }

    }

    private func persistPositionUpdateIfNeeded(
        bookId: UUID,
        updatedBook: ReadingBook,
        force: Bool
    ) {
        guard shouldPersistPositionUpdate(bookId: bookId, updatedBook: updatedBook, force: force) else {
            return
        }
        if force {
            saveMetaImmediately()
        } else {
            saveMeta()
        }
    }

    private func shouldPersistPositionUpdate(
        bookId: UUID,
        updatedBook: ReadingBook,
        force: Bool
    ) -> Bool {
        if force { return true }

        let snapshot = PersistedPositionSnapshot(book: updatedBook)
        guard let persisted = lastPersistedPositionSnapshots[bookId] else {
            return true
        }

        if abs(snapshot.currentPosition - persisted.currentPosition) >= Self.minimumProgressDeltaForMetadataWrite {
            return true
        }
        if snapshot.mangaChapterIndex != persisted.mangaChapterIndex {
            return true
        }
        if snapshot.audioChapterIndex != persisted.audioChapterIndex {
            return true
        }
        if abs(snapshot.audioTimeSeconds - persisted.audioTimeSeconds) >= Self.minimumAudioTimeDeltaForMetadataWrite {
            return true
        }

        guard snapshot != persisted else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        let lastSave = lastPersistedPositionSaveUptimeByBook[bookId] ?? now
        return now - lastSave >= Self.maximumPositionMetadataWriteInterval
    }

    // MARK: - Writing the shelf
    //
    // Every write goes through `persistQueue`, in order. A debounced save — what a download's
    // chapter marks and the launch refresh's table-of-contents updates ask for, every few
    // seconds for as long as either runs — is written in the background: encoding 100 books
    // and a changed 2000-chapter list took 30–120ms on the main thread each time. An
    // immediate save (a source switch, a download's state change, the scene leaving the
    // foreground) still writes before it returns, on the same queue, so it lands after any
    // background write already in flight. legado writes its books and chapters through Room
    // on its IO dispatcher for the same reason.
    private static let persistQueue = DispatchQueue(label: "com.yuedu.library.persist", qos: .utility)
    /// Order of the writes handed to `persistQueue`; a write's bookkeeping is applied only if
    /// no later write's has been.
    private var persistSequence: UInt64 = 0
    private var lastAppliedPersistSequence: UInt64 = 0

    /// What the two files last received from this store. Read and written on `persistQueue`
    /// only, so a write sees the one before it even while that one's main-thread bookkeeping
    /// is still queued; the main thread sets it when it reads or writes the files itself.
    private final class PersistedFiles {
        var shelfData: Data?
        var readingData: Data?
    }
    private let persistedFiles = PersistedFiles()

    private struct MetadataWriteInput {
        enum Payload {
            case records(shelf: [ReadingBook], reading: [ReadingBook])
            case encoded(shelf: Data, reading: Data)
        }
        let payload: Payload
        let writesBlocked: Bool
        /// The records the shelf data describes, for the position bookkeeping.
        let records: [ReadingBook]
    }

    private struct MetadataWritten {
        var shelfData: Data?
        var readingData: Data?
    }

    private func persistMetadataIfChanged(inBackground: Bool) {
        persist(
            MetadataWriteInput(
                payload: .records(shelf: books, reading: records.filter { !$0.isInBookshelf }),
                writesBlocked: metadataWritesBlocked,
                records: records
            ),
            inBackground: inBackground
        )
    }

    private func persistMetadata(_ data: Data, readingData: Data) {
        persist(
            MetadataWriteInput(
                payload: .encoded(shelf: data, reading: readingData),
                writesBlocked: metadataWritesBlocked,
                records: records
            ),
            inBackground: false
        )
    }

    private func persist(_ input: MetadataWriteInput, inBackground: Bool) {
        persistSequence &+= 1
        let sequence = persistSequence
        if inBackground {
            Self.persistQueue.async { [self] in
                let written = writeMetadata(input)
                DispatchQueue.main.async { self.noteMetadataWritten(written, from: input, sequence: sequence) }
            }
        } else {
            let written = Self.persistQueue.sync { writeMetadata(input) }
            noteMetadataWritten(written, from: input, sequence: sequence)
        }
    }

    /// Runs on `persistQueue`. Touches no store state beyond `chapterStore`, which has its own lock.
    private func writeMetadata(_ input: MetadataWriteInput) -> MetadataWritten {
        let shelfData: Data?
        let readingData: Data?
        switch input.payload {
        case .records(let shelf, let reading):
            shelfData = Self.encodeShelf(shelf)
            readingData = Self.encodeShelf(reading)
        case .encoded(let shelf, let reading):
            shelfData = shelf
            readingData = reading
        }
        var written = MetadataWritten()
        let files = persistedFiles
        SourcePerfTrace.span(
            "library.shelf.save", "books=\(input.records.count) main=\(Thread.isMainThread)", thresholdMs: 5
        ) {
            do {
                // Write the shelf first: a crash while promoting a reading record must
                // leave at least one durable copy. Loading gives shelf IDs precedence.
                if input.writesBlocked {
                    // What is on disk is the only copy of a shelf this launch could not read.
                    AppLogger.cache("Bookshelf metadata is unreadable and was not kept aside; leaving it as it is")
                } else {
                    // The lists go before the shelf that no longer carries them: a shelf moved out
                    // of an older build's file must not be written until its lists are on disk.
                    chapterStore.flush()
                    if let shelfData, shelfData != files.shelfData {
                        // A restore (iCloud, WebDAV) replaces the file from outside the store and
                        // reloads it afterwards. A write queued before that must not put the old
                        // shelf back over it: the file is only overwritten while it still holds
                        // what this store last wrote.
                        if Self.file(metadataFileURL, holds: files.shelfData) {
                            try shelfData.write(to: metadataFileURL, options: .atomic)
                            files.shelfData = shelfData
                            written.shelfData = shelfData
                        } else {
                            AppLogger.cache("Bookshelf file changed outside the store; keeping it")
                        }
                    }
                }
                if let readingData, readingData != files.readingData {
                    try readingData.write(to: readingMetadataFileURL, options: .atomic)
                    files.readingData = readingData
                    written.readingData = readingData
                }
            } catch {
                AppLogger.cache("Failed to write metadata: \(error)")
            }
        }
        return written
    }

    private static func file(_ url: URL, holds data: Data?) -> Bool {
        guard let data else { return !FileManager.default.fileExists(atPath: url.path) }
        return (try? Data(contentsOf: url)) == data
    }

    /// Main thread: records what the files now hold. A write that an immediate one has
    /// already overtaken changes nothing here; the files hold the later one.
    private func noteMetadataWritten(_ written: MetadataWritten, from input: MetadataWriteInput, sequence: UInt64) {
        guard sequence > lastAppliedPersistSequence else { return }
        lastAppliedPersistSequence = sequence
        if let shelfData = written.shelfData {
            markMetadataPersisted(shelfData, records: input.records)
            syncWidgetData()
        }
        if let readingData = written.readingData {
            lastPersistedReadingData = readingData
        }
    }

    private func notePersistedReadingData(_ data: Data) {
        lastPersistedReadingData = data
        Self.persistQueue.sync { persistedFiles.readingData = data }
    }

    private static func encodeShelf(_ books: [ReadingBook]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(books)
    }

    private func encodeBooksMetadata() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(books)
    }

    /// - Parameter records: the records `data` was encoded from — on a background write,
    ///   the store may have moved on by the time this runs.
    private func markMetadataPersisted(_ data: Data, records: [ReadingBook]) {
        lastPersistedMetadataData = data
        Self.persistQueue.sync { persistedFiles.shelfData = data }
        let now = ProcessInfo.processInfo.systemUptime
        lastPersistedPositionSnapshots = Dictionary(
            uniqueKeysWithValues: records.map { ($0.id, PersistedPositionSnapshot(book: $0)) }
        )
        lastPersistedPositionSaveUptimeByBook = Dictionary(
            uniqueKeysWithValues: records.map { ($0.id, now) }
        )
    }

    // MARK: - Widget Data Sync

    private static let widgetAppGroupID = "group.com.zhangruilin.yuedureader"
    private static let widgetDataKey = "widget_last_book"

    private func syncWidgetData() {
        guard let defaults = UserDefaults(suiteName: Self.widgetAppGroupID) else { return }
        guard let lastBook = books
            .sorted(by: { ($0.lastOpenedDate ?? $0.addedDate) > ($1.lastOpenedDate ?? $1.addedDate) })
            .first
        else {
            defaults.removeObject(forKey: Self.widgetDataKey)
            return
        }

        let entry = WidgetBookProgress(
            title: lastBook.title,
            author: lastBook.author,
            progress: min(1, max(0, lastBook.currentPosition)),
            coverImagePath: lastBook.coverImagePath,
            lastReadDate: lastBook.lastOpenedDate ?? lastBook.addedDate
        )

        if let data = try? JSONEncoder().encode(entry) {
            defaults.set(data, forKey: Self.widgetDataKey)
            WidgetCenter.shared.reloadTimelines(ofKind: "BookProgressWidget")
        }
    }

    /// Re-reads `books_meta.json` into memory. Used after an iCloud restore
    /// overwrites the file so the bookshelf reflects it without a relaunch.
    func reloadFromDisk() {
        // Nothing of the shelf being replaced may be written over it: a pending save is
        // dropped, and a write already in flight finishes first (it keeps the restored
        // file, see `writeMetadata`).
        cancelPendingMetadataSave()
        Self.persistQueue.sync {}
        let shelfLoaded = loadMeta()
        let readingRecordsLoaded = loadReadingRecords()
        finishLoadingChapterLists(complete: shelfLoaded && readingRecordsLoaded)
    }

    /// Runs once the shelf and the reading records are read. Lists that came inside them —
    /// a file written before `chapterStore`, or by an older build since — are written out;
    /// a book whose summary is missing gets it back from its stored list; and when both
    /// files read completely, the lists of books that are in neither are removed.
    private func finishLoadingChapterLists(complete: Bool) {
        // A shelf without the summary has its lists on disk all the same: a backup restored
        // over it never carries the summary (`strippedForSync`), and a build from before it
        // drops the fields when it rewrites the file.
        var repaired = records
        var didRepair = false
        for index in repaired.indices where repaired[index].totalChapterNum == nil {
            let bookID = repaired[index].id
            guard chapterStore.hasStoredList(for: bookID),
                  let chapters = chapterStore.chapters(for: bookID) else { continue }
            repaired[index].applyChapterSummary(from: chapters)
            didRepair = true
        }
        if didRepair { records = repaired }
        recordsLoadedCompletely = complete
        if complete { chapterStore.removeChapters(notIn: Set(records.map(\.id))) }
        if didRepair || chapterStore.hasUnwrittenChanges { saveMetaImmediately() }
    }

    /// Whether the shelf is known to be complete: the file decoded, or there is no shelf
    /// file yet. A file that exists but does not decode leaves the shelf empty, and that
    /// must not be taken to mean the user has no books.
    @discardableResult
    private func loadMeta() -> Bool {
        let shelfFileExists = FileManager.default.fileExists(atPath: metadataFileURL.path)
        // Prefer the file-based store.
        if shelfFileExists {
            do {
                let data = try Data(contentsOf: metadataFileURL)
                do {
                    let decoded = try SourcePerfTrace.span("library.shelf.load", "bytes=\(data.count)", thresholdMs: 5) {
                        try JSONDecoder().decode([ReadingBook].self, from: data)
                    }
                    records = Self.sanitizingInlineChapterURLs(decoded)
                    markMetadataPersisted(data, records: records)
                    return true
                } catch {
                    // The shelf opens empty when this happens, and nothing on screen says why.
                    AppLogger.error(
                        "Bookshelf metadata could not be decoded",
                        error: error,
                        context: ["file": metadataFileURL.lastPathComponent]
                    )
                    metadataWritesBlocked = !keptUnreadableMetadataAside(data)
                    if !metadataWritesBlocked {
                        // The bytes are safe in their copy, so the file may be written over:
                        // the write queue is told what it holds now.
                        Self.persistQueue.sync { persistedFiles.shelfData = data }
                    }
                }
            } catch {
                // Not even the bytes are in hand, so nothing may be written over them.
                AppLogger.error(
                    "Bookshelf metadata could not be read",
                    error: error,
                    context: ["file": metadataFileURL.lastPathComponent]
                )
                metadataWritesBlocked = true
            }
        }

        // One-time migration: pull legacy data out of UserDefaults, write to disk,
        // then remove the UserDefaults entry so it no longer inflates the plist.
        if let data = UserDefaults.standard.data(forKey: legacyMetaKey),
           let decoded = try? JSONDecoder().decode([ReadingBook].self, from: data)
        {
            records = Self.sanitizingInlineChapterURLs(decoded)
            if !metadataWritesBlocked, let migrated = encodeBooksMetadata() {
                chapterStore.flush()
                try? migrated.write(to: metadataFileURL, options: .atomic)
                markMetadataPersisted(migrated, records: records)
            }
            UserDefaults.standard.removeObject(forKey: legacyMetaKey)
            return true
        }
        return !shelfFileExists
    }

    /// Copies a shelf file that did not decode next to itself, before anything writes over it.
    ///
    /// Named after the file's own modification time, so the next launch recognises the copy it
    /// already made instead of filling the folder with duplicates. Returns whether the bytes
    /// are safely preserved; when they are not, the shelf is left exactly as it is for this
    /// launch — an empty shelf written over the only copy is how a library disappears.
    private func keptUnreadableMetadataAside(_ data: Data) -> Bool {
        let modified = try? metadataFileURL
            .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let stamp = Int((modified ?? Date()).timeIntervalSince1970)
        let backupURL = metadataFileURL
            .deletingPathExtension()
            .appendingPathExtension("corrupt-\(stamp).json")
        do {
            try data.write(to: backupURL, options: .withoutOverwriting)
            AppLogger.error(
                "Bookshelf metadata kept aside as \(backupURL.lastPathComponent)",
                context: ["bytes": data.count]
            )
            return true
        } catch {
            if let existing = try? Data(contentsOf: backupURL), existing == data {
                // An earlier launch already kept exactly these bytes.
                return true
            }
            AppLogger.error(
                "Bookshelf metadata could not be kept aside; this launch will not write the shelf",
                error: error,
                context: ["backup": backupURL.lastPathComponent]
            )
            return false
        }
    }

    /// Whether every reading-only record is known: the file decoded, or there is none.
    @discardableResult
    private func loadReadingRecords() -> Bool {
        guard FileManager.default.fileExists(atPath: readingMetadataFileURL.path) else { return true }
        do {
            let data = try Data(contentsOf: readingMetadataFileURL)
            let decoded = Self.sanitizingInlineChapterURLs(try JSONDecoder().decode([ReadingBook].self, from: data))
            let shelfIDs = Set(records.map(\.id))
            records.append(contentsOf: decoded.filter { !$0.isInBookshelf && !shelfIDs.contains($0.id) })
            notePersistedReadingData(data)
            return true
        } catch {
            AppLogger.error("Remote reading records could not be loaded", error: error)
            return false
        }
    }

    private func persistReadingRecords() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(records.filter { !$0.isInBookshelf })
            try persistEncodedReadingRecords(data)
        } catch { AppLogger.error("Remote reading records could not be saved", error: error) }
    }

    private func persistEncodedReadingRecords(_ data: Data) throws {
        guard data != lastPersistedReadingData else { return }
        try Self.persistQueue.sync {
            try data.write(to: readingMetadataFileURL, options: .atomic)
        }
        notePersistedReadingData(data)
    }

    /// Cleans the chapter URLs of lists read from inside a shelf file: replaces URLs
    /// containing HTML markup with sanitized href values. Lists written by `chapterStore`
    /// passed through here on their way out of the shelf, or came from a current parser.
    private static func sanitizingInlineChapterURLs(_ books: [ReadingBook]) -> [ReadingBook] {
        books.map { book in
            guard book.isOnline, var chapters = book.onlineChapters else { return book }
            var bookChanged = false
            for j in chapters.indices {
                let original = chapters[j].url
                let sanitized = RuleEngine.sanitizeExtractedURL(original)
                if sanitized != original {
                    chapters[j].url = sanitized
                    bookChanged = true
                }
            }
            guard bookChanged else { return book }
            var sanitized = book
            sanitized.onlineChapters = chapters
            return sanitized
        }
    }

    private static func normalizedOnlineValue(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func normalizedOnlineValue(_ value: String?) -> String {
        Self.normalizedOnlineValue(value)
    }

    private static func onlineBookURLKey(_ raw: String?) -> String {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return "" }
        if var components = URLComponents(string: trimmed) {
            components.fragment = nil
            return (components.string ?? trimmed).lowercased()
        }
        return trimmed.lowercased()
    }

    /// - Parameter preservingExistingTail: keep chapters the refreshed list does not reach.
    ///   Required for the progressive `onFirstPageReady` commit, which carries **only the
    ///   first page** of the table of contents: replacing a 3000-chapter list with those 50
    ///   truncates the book, and any `saveMetaImmediately()` racing that window — every
    ///   completed download chapter issues one — persists the truncation. A later reconcile
    ///   then reads the short list as "these chapters are gone". The final commit passes
    ///   false, because by then the refreshed list is the whole thing and a genuine deletion
    ///   upstream should be reflected.
    private static func mergeOnlineChapters(
        existing: [OnlineChapterRef],
        refreshed: [OnlineChapterRef],
        preservingExistingTail: Bool = false
    ) -> [OnlineChapterRef] {
        let existingByIndex = Dictionary(uniqueKeysWithValues: existing.map { ($0.index, $0) })
        var merged = refreshed.map { chapter in
            var merged = chapter
            guard let current = existingByIndex[chapter.index] else {
                return merged
            }
            if normalizedOnlineValue(current.url) == normalizedOnlineValue(chapter.url) {
                merged.cachedFilename = current.cachedFilename
            }
            if (merged.runtimeVariables == nil || merged.runtimeVariables?.isEmpty == true),
                let currentRuntime = current.runtimeVariables,
                !currentRuntime.isEmpty
            {
                merged.runtimeVariables = currentRuntime
            }
            return merged
        }
        if preservingExistingTail, existing.count > merged.count {
            merged.append(contentsOf: existing[merged.count...])
        }
        return merged
    }

    private static func chapterListChanged(
        existing: [OnlineChapterRef],
        refreshed: [OnlineChapterRef]
    ) -> Bool {
        guard existing.count == refreshed.count else { return true }
        for (left, right) in zip(existing, refreshed) {
            if left.index != right.index { return true }
            if normalizedOnlineValue(left.url) != normalizedOnlineValue(right.url) { return true }
            if normalizeChapterTitle(left.title) != normalizeChapterTitle(right.title) { return true }
        }
        return false
    }

    private static func normalizeChapterTitle(_ title: String) -> String {
        ReaderHTMLUtilities.displayText(fromHTMLFragment: title)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
    }
}
