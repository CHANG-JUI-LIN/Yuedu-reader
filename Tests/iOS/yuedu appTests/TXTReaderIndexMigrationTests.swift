import Foundation
import Testing
import UIKit
@testable import yuedu_app

@MainActor
@Suite(.serialized)
struct TXTReaderIndexMigrationTests {
    @Test func previewAndFailedMigrationCannotPublishPositions() {
        #expect(!ReaderProgressSyncPolicy.canPublishIndexPosition(isTXT: true, indexReady: false))
        #expect(ReaderProgressSyncPolicy.canPublishIndexPosition(isTXT: true, indexReady: true))
        #expect(ReaderProgressSyncPolicy.canPublishIndexPosition(isTXT: false, indexReady: false))
    }
    private final class Positions: ReadingPositionStore, @unchecked Sendable {
        let lock = NSLock()
        var value: CoreTextReadingPosition?
        var failWrites = false
        init(_ position: CoreTextReadingPosition?) { value = position }
        func save(_ position: CoreTextReadingPosition, for bookId: String) async {
            lock.withLock { if !failWrites { value = position } }
        }
        func load(for bookId: String) async -> CoreTextReadingPosition? { loadSync(for: bookId) }
        func loadSync(for bookId: String) -> CoreTextReadingPosition? { lock.withLock { value } }
        func flush(for bookId: String) async {}
    }

    @Test(arguments: [false, true])
    func migrationPreservesBookmarksAndReplaysInterruptedCommit(interrupt: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = "第1章 開始\n正文。\n第一篇：人仙篇！\n第二篇：地仙篇。\n後文。\n第2章 繼續\n正文。"
        let data = Data(text.utf8)
        let file = directory.appendingPathComponent("book.txt")
        try data.write(to: file)
        var book = ReadingBook(title: "Test", author: "Test", contentFilename: "book.txt")
        let oldPosition = CoreTextReadingPosition.chapterStart(2)
        let metadata = directory.appendingPathComponent("books.json")
        let store = BookStore(metadataFileURL: metadata)
        let positions = Positions(oldPosition)
        let ns = text as NSString
        let titles = ["第1章 開始", "第一篇：人仙篇！", "第二篇：地仙篇。", "第2章 繼續"]
        func byteOffset(_ offset: Int) -> Int { ns.substring(to: offset).utf8.count }
        let old = titles.enumerated().map { ordinal, title in
            let range = ns.range(of: title)
            let start = byteOffset(NSMaxRange(range) + 1)
            let end = ordinal + 1 < titles.count ? byteOffset(ns.range(of: titles[ordinal + 1]).location) : data.count
            return ["index": ordinal, "title": title, "lower": start, "upper": end] as [String: Any]
        }
        let cache = StorageLocations.txtChapterCache.appendingPathComponent("\(book.id.uuidString).json")
        let journal = StorageLocations.readingPosition.appendingPathComponent("\(book.id.uuidString).txt-reindex.json")
        defer {
            TXTChapterParser.deleteCachedIndexes(bookId: book.id)
            try? FileManager.default.removeItem(at: journal)
        }
        let cacheData = try JSONSerialization.data(withJSONObject: [
            "version": 5, "fileSize": data.count, "fingerprint": TXTFileReader.fileFingerprint(data: data),
            "encodingRawValue": String.Encoding.utf8.rawValue, "indexes": old
        ])
        try cacheData.write(to: cache)
        let preparation = try TXTReaderPreparationService.prepare(url: file, bookId: book.id, bookTitle: book.title)
        #expect(preparation.cachedChapterIndexes == nil)
        #expect(preparation.previousChapterIndexes?.count == 4)
        #expect(preparation.previewText.isEmpty)
        let settings = EPUBTestFixtures.renderSettings()
        let oldBuilder = TXTLazyAttributedStringBuilder(mappedTextFile: preparation.mappedTextFile,
                                                       chapterIndexes: try #require(preparation.previousChapterIndexes))
        let oldRendered = try await oldBuilder.buildChapter(at: 2, settings: settings,
                                                           themeTextColor: .label, themeBackgroundColor: .systemBackground)
        // The actual title builder prepends a spacer. A highlight of text starts
        // at its rendered range, not raw-title offset zero (the spacer itself).
        let selectedRange = (oldRendered.attributedString.string as NSString).range(of: "第二篇：地")
        #expect(selectedRange.location != NSNotFound)
        let bookmark = Bookmark(chapterIndex: 2, chapterTitle: "第二篇：地仙篇。",
                                position: .init(spineIndex: 2, charOffset: selectedRange.location),
                                length: selectedRange.length, kind: .highlight, note: "Keep note", excerpt: "第二篇：地")
        book.bookmarks = [bookmark]
        store.replaceBooksFromSync([book])
        var interruptedJournal: Data?
        if interrupt {
            positions.failWrites = true
            do {
                _ = try await TXTReaderIndexMigrationService.complete(preparation, store: store, positions: positions, settings: settings)
                Issue.record("Expected failed position persistence")
            } catch {}
            #expect(try Data(contentsOf: cache) == cacheData)
            #expect(FileManager.default.fileExists(atPath: journal.path))
            interruptedJournal = try Data(contentsOf: journal)
            positions.failWrites = false
        }
        let result = try await TXTReaderIndexMigrationService.complete(preparation, store: store, positions: positions, settings: settings)
        #expect(result.indexes.map(\.title) == ["第1章 開始", "第2章 繼續"])
        #expect(result.restoredPosition?.spineIndex == 0)
        #expect((result.restoredPosition?.charOffset ?? 0) > 0)
        let migrated = try #require(store.books.first?.bookmarks.first)
        #expect(migrated.id == bookmark.id)
        #expect(migrated.note == bookmark.note)
        #expect(migrated.length == bookmark.length)
        #expect(migrated.kind == bookmark.kind)
        #expect(migrated.excerpt == bookmark.excerpt)
        #expect(migrated.position == result.restoredPosition)
        let persisted = try JSONDecoder().decode([ReadingBook].self, from: Data(contentsOf: metadata))
        #expect(persisted.first?.bookmarks == store.books.first?.bookmarks)
        #expect(!FileManager.default.fileExists(atPath: journal.path))
        // Simulate termination after all target writes but before journal cleanup.
        if let interruptedJournal { try interruptedJournal.write(to: journal) }
        let reopened = try TXTReaderPreparationService.prepare(url: file, bookId: book.id, bookTitle: book.title)
        #expect(reopened.previousChapterIndexes == nil)
        let repeated = try await TXTReaderIndexMigrationService.complete(reopened, store: store, positions: positions, settings: settings)
        #expect(repeated.restoredPosition == result.restoredPosition)
        #expect(store.books.first?.bookmarks.first == migrated)
        #expect(!FileManager.default.fileExists(atPath: journal.path))
    }

    @Test func newImportPublishesOnlyThroughTheCommitOwner() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("book.txt")
        try Data("第1章 正文\n內容。\n第2章 正文\n內容。".utf8).write(to: file)
        let book = ReadingBook(title: "Test", author: "Test", contentFilename: "book.txt")
        let store = BookStore(metadataFileURL: directory.appendingPathComponent("books.json"))
        store.replaceBooksFromSync([book])
        let positions = Positions(nil)
        defer { TXTChapterParser.deleteCachedIndexes(bookId: book.id) }
        let preparation = try TXTReaderPreparationService.prepare(url: file, bookId: book.id, bookTitle: book.title)
        let result = try await TXTReaderIndexMigrationService.complete(preparation, store: store, positions: positions, settings: EPUBTestFixtures.renderSettings())
        #expect(result.indexes.count == 2)
        #expect(result.restoredPosition == nil)
        let reopened = try TXTReaderPreparationService.prepare(url: file, bookId: book.id, bookTitle: book.title)
        #expect(reopened.cachedChapterIndexes == result.indexes)
        #expect(reopened.previewText.isEmpty)
    }

    @Test func missingOldIndexPreservesSavedData() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("book.txt")
        try Data("第1章 正文\n內容。\n第2章 正文\n內容。".utf8).write(to: file)
        var book = ReadingBook(title: "Test", author: "Test", contentFilename: "book.txt")
        let position = CoreTextReadingPosition(spineIndex: 5, charOffset: 123)
        book.bookmarks = [Bookmark(chapterIndex: 5, chapterTitle: "Old", position: position)]
        let metadata = directory.appendingPathComponent("books.json")
        let store = BookStore(metadataFileURL: metadata)
        store.replaceBooksFromSync([book])
        let original = try Data(contentsOf: metadata)
        let positions = Positions(position)
        let preparation = try TXTReaderPreparationService.prepare(url: file, bookId: book.id, bookTitle: book.title)
        do {
            _ = try await TXTReaderIndexMigrationService.complete(preparation, store: store, positions: positions, settings: EPUBTestFixtures.renderSettings())
            Issue.record("Missing old index must not silently reinterpret a saved position")
        } catch TXTLocationMigration.Failure.missingSourceIdentity {}
        #expect(try Data(contentsOf: metadata) == original)
        #expect(positions.loadSync(for: book.id.uuidString) == position)
        #expect(!FileManager.default.fileExists(atPath: StorageLocations.txtChapterCache.appendingPathComponent("\(book.id.uuidString).json").path))
    }

    @Test func fileMismatchDoesNotOverwriteTheOldIndex() throws {
        let id = UUID()
        let indexes = [TXTMappedChapterIndex(index: 0, title: "Old", byteRange: 0..<10)]
        defer { TXTChapterParser.deleteCachedIndexes(bookId: id) }
        try TXTChapterParser.writeCachedIndexes(indexes, bookId: id, fileSize: 10, fingerprint: "old", encoding: .utf8)
        let url = StorageLocations.txtChapterCache.appendingPathComponent("\(id.uuidString).json")
        let original = try Data(contentsOf: url)
        #expect(throws: TXTLocationMigration.Failure.self) {
            try TXTChapterParser.cachedIndexesForMigration(bookId: id, fileSize: 10, fingerprint: "new", encoding: .utf8)
        }
        #expect(try Data(contentsOf: url) == original)
    }
}
