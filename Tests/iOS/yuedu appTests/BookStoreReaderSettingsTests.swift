import Foundation
import Testing
@testable import yuedu_app

/// 書籍記錄離開這台裝置時，只屬於這本書的設定要一起清掉；只是移出書架時要留著。
@Suite("BookStore reader settings lifecycle", .serialized)
struct BookStoreReaderSettingsTests {

    @Test("deleting a book removes its reader settings and its role voices")
    @MainActor
    func deletingBookRemovesItsSettings() throws {
        let (store, directory, metadataURL) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let deleted = onlineBook(title: "要刪的書")
        let kept = onlineBook(title: "留下的書")
        store.replaceBooksFromSync([deleted, kept])
        let configuration = FixedPageReaderConfiguration.everyToggleChanged()
        store.readerSettings.setFixedPageConfiguration(configuration, for: deleted.id)
        store.readerSettings.setFixedPageConfiguration(configuration, for: kept.id)

        let settings = GlobalSettings.shared
        let originalVoices = settings.ttsRoleVoices
        defer { settings.ttsRoleVoices = originalVoices }
        var voices = TTSRoleVoiceCast.setting(
            voiceIdentifier: "voice-a", forSpeaker: "張三", bookID: deleted.id, in: originalVoices
        )
        voices = TTSRoleVoiceCast.setting(
            voiceIdentifier: "voice-b", forSpeaker: "張三", bookID: kept.id, in: voices
        )
        settings.ttsRoleVoices = voices

        store.delete(bookId: deleted.id)

        let restarted = BookStore(metadataFileURL: metadataURL)
        #expect(
            restarted.readerSettings.fixedPageConfiguration(for: deleted.id)
                == FixedPageReadingMode.rtl.recommendedConfiguration
        )
        #expect(restarted.readerSettings.fixedPageConfiguration(for: kept.id) == configuration)
        #expect(TTSRoleVoiceCast.cast(forBook: deleted.id, in: settings.ttsRoleVoices).isEmpty)
        #expect(TTSRoleVoiceCast.cast(forBook: kept.id, in: settings.ttsRoleVoices) == ["張三": "voice-b"])
    }

    @Test("removing a remote book from the shelf keeps its reader settings and role voices")
    @MainActor
    func removingRemoteShelfReferenceKeepsSettings() throws {
        let (store, directory, metadataURL) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        var book = ReadingBook(title: "遠端書", author: "Author", contentFilename: "")
        book.remoteSource = RemoteBookReference(
            connectionID: "connection",
            entryID: "entry",
            format: RemoteLibraryFormat(
                url: URL(string: "https://example.com/book.pdf")!,
                fileExtension: "pdf",
                mimeType: "application/pdf"
            )
        )
        store.replaceBooksFromSync([book])
        let configuration = FixedPageReaderConfiguration.everyToggleChanged()
        store.readerSettings.setFixedPageConfiguration(configuration, for: book.id)

        let settings = GlobalSettings.shared
        let originalVoices = settings.ttsRoleVoices
        defer { settings.ttsRoleVoices = originalVoices }
        settings.ttsRoleVoices = TTSRoleVoiceCast.setting(
            voiceIdentifier: "voice-a", forSpeaker: "張三", bookID: book.id, in: originalVoices
        )

        store.delete(bookId: book.id)

        #expect(store.readingBook(id: book.id)?.isInBookshelf == false)
        let restarted = BookStore(metadataFileURL: metadataURL)
        #expect(restarted.readerSettings.fixedPageConfiguration(for: book.id) == configuration)
        #expect(TTSRoleVoiceCast.cast(forBook: book.id, in: settings.ttsRoleVoices) == ["張三": "voice-a"])
    }

    @Test("a sync that no longer carries a book drops that book's reader settings")
    @MainActor
    func syncRemovalDropsSettings() throws {
        let (store, directory, metadataURL) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let removed = onlineBook(title: "別台刪掉的書")
        let kept = onlineBook(title: "還在的書")
        store.replaceBooksFromSync([removed, kept])
        let configuration = FixedPageReaderConfiguration.everyToggleChanged()
        store.readerSettings.setFixedPageConfiguration(configuration, for: removed.id)
        store.readerSettings.setFixedPageConfiguration(configuration, for: kept.id)

        store.replaceBooksFromSync([kept])

        let restarted = BookStore(metadataFileURL: metadataURL)
        #expect(
            restarted.readerSettings.fixedPageConfiguration(for: removed.id)
                == FixedPageReadingMode.rtl.recommendedConfiguration
        )
        #expect(restarted.readerSettings.fixedPageConfiguration(for: kept.id) == configuration)
    }

    @Test("a sync applied before the reading records loaded keeps the settings of books only read")
    @MainActor
    func syncOverIncompleteLoadKeepsSettings() throws {
        let (seeding, directory, metadataURL) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let shelved = onlineBook(title: "書架上的書")
        seeding.replaceBooksFromSync([shelved])
        // 立即閱讀's copy: a record off the shelf, in the reading-record file only.
        let readOnly = seeding.addOnlineBook(
            name: "只讀過的漫畫", author: "Author", sourceId: UUID(),
            bookInfoURL: "https://reader-settings.test/manga", contentKind: .manga,
            chapters: [], isInBookshelf: false
        )
        let configuration = FixedPageReaderConfiguration.everyToggleChanged()
        seeding.readerSettings.setFixedPageConfiguration(configuration, for: readOnly.id)
        seeding.flushPendingMetadataSave()
        seeding.waitForQueuedWrites()
        let readingRecordsURL = metadataURL.deletingPathExtension().appendingPathExtension("reading.json")
        try Data("{ not json".utf8).write(to: readingRecordsURL)

        // The reading records did not load, so this store cannot tell that the book is gone.
        let launched = BookStore(metadataFileURL: metadataURL)
        launched.replaceBooksFromSync([shelved])

        #expect(launched.readerSettings.fixedPageConfiguration(for: readOnly.id) == configuration)
        let settingsURL = metadataURL.deletingPathExtension().appendingPathExtension("reader-settings.json")
        #expect(BookReaderSettingsStore(fileURL: settingsURL).fixedPageConfiguration(for: readOnly.id) == configuration)
    }

    @Test("the app's store moves the legacy reading modes of its books into the settings file")
    @MainActor
    func appStoreMigratesLegacyReadingModes() throws {
        let (seeding, directory, metadataURL) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let book = onlineBook(title: "漫畫")
        seeding.replaceBooksFromSync([book])
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "fixedPage.readingMode.\(book.id.uuidString)"
        defaults.set(FixedPageReadingMode.webtoon.rawValue, forKey: key)

        let launched = BookStore(metadataFileURL: metadataURL, legacyReaderSettingsDefaults: defaults)

        #expect(
            launched.readerSettings.fixedPageConfiguration(for: book.id)
                == FixedPageReadingMode.webtoon.recommendedConfiguration
        )
        #expect(defaults.object(forKey: key) == nil)
    }

    @Test("a readable shelf drops legacy reading modes of books it no longer has")
    @MainActor
    func readableShelfDropsLegacyKeysOfDeletedBooks() throws {
        let (seeding, directory, metadataURL) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        seeding.replaceBooksFromSync([onlineBook(title: "還在的書")])
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "fixedPage.readingMode.\(UUID().uuidString)"
        defaults.set(FixedPageReadingMode.webtoon.rawValue, forKey: key)

        _ = BookStore(metadataFileURL: metadataURL, legacyReaderSettingsDefaults: defaults)

        #expect(defaults.object(forKey: key) == nil)
    }

    @Test("an unreadable reading-record file keeps every unknown legacy reading mode")
    @MainActor
    func unreadableReadingRecordsKeepUnknownLegacyKeys() throws {
        let (seeding, directory, metadataURL) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        seeding.replaceBooksFromSync([onlineBook(title: "還在的書")])
        let readingRecordsURL = metadataURL.deletingPathExtension().appendingPathExtension("reading.json")
        try Data("{ not json".utf8).write(to: readingRecordsURL)
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "fixedPage.readingMode.\(UUID().uuidString)"
        defaults.set(FixedPageReadingMode.webtoon.rawValue, forKey: key)

        _ = BookStore(metadataFileURL: metadataURL, legacyReaderSettingsDefaults: defaults)

        #expect(defaults.object(forKey: key) as? Int == FixedPageReadingMode.webtoon.rawValue)
    }

    // MARK: - Helpers

    @MainActor
    private func makeStore() throws -> (BookStore, URL, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookStoreReaderSettingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let metadataURL = directory.appendingPathComponent("books_meta.json")
        return (BookStore(metadataFileURL: metadataURL), directory, metadataURL)
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "test.book-store-reader-settings.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suiteName)!, suiteName)
    }

    private func onlineBook(title: String) -> ReadingBook {
        var book = ReadingBook(title: title, author: "Author", contentFilename: "")
        book.isOnline = true
        book.contentPipelineKind = .manga
        return book
    }
}
