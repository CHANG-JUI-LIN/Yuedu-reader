import Foundation

/// One book's own reader settings: how this particular book is read, apart from the
/// rest of the library.
///
/// Today that is only the fixed-page reader's configuration. The typography overrides in
/// `Technotes/PerBookReaderSettings-2026-09-15-design.md` join as further optional fields,
/// where `nil` always means "this book does not speak for that setting".
struct BookReaderSettings: Codable, Equatable {
    let bookID: UUID
    /// Advances on a user edit only, so a later sync can tell which copy is newer.
    var modifiedAt: Date
    /// Reading mode plus every toggle of the manga / PDF / fixed-layout EPUB reader.
    /// `nil` reads as the right-to-left defaults an unsaved book has always had.
    var fixedPage: FixedPageReaderConfiguration? = nil

    var isEmpty: Bool { fixedPage == nil }
}

/// The one place per-book reader settings live.
///
/// Before this store the fixed-page reader kept only its reading mode, under
/// `fixedPage.readingMode.<book id>` in UserDefaults: cropping, spreads and the other
/// toggles reset every time a book was reopened, and deleting the book never removed
/// the key. `BookStore` owns the store and drops a book's entry wherever it drops the book.
final class BookReaderSettingsStore {
    private struct File: Codable {
        var version: Int
        var books: [BookReaderSettings]
    }

    private static let fileVersion = 1
    private static let currentModeKeyPrefix = "fixedPage.readingMode."
    private static let legacyModeKeyPrefix = "manga.readingMode."

    private let fileURL: URL
    private var settingsByBook: [UUID: BookReaderSettings] = [:]
    /// Set when the file on disk could not be read and could not be kept aside either.
    /// Writing would replace data nobody has seen, so edits stay in memory until relaunch.
    private var writesBlocked = false

    init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    // MARK: Fixed-page reader

    func fixedPageConfiguration(for bookID: UUID) -> FixedPageReaderConfiguration {
        settingsByBook[bookID]?.fixedPage ?? FixedPageReadingMode.rtl.recommendedConfiguration
    }

    func setFixedPageConfiguration(_ configuration: FixedPageReaderConfiguration, for bookID: UUID) {
        guard settingsByBook[bookID]?.fixedPage != configuration else { return }
        var settings = settingsByBook[bookID] ?? BookReaderSettings(bookID: bookID, modifiedAt: Date())
        settings.fixedPage = configuration
        settings.modifiedAt = Date()
        settingsByBook[bookID] = settings
        save()
    }

    // MARK: Book lifecycle

    func removeSettings(for bookID: UUID) {
        guard settingsByBook.removeValue(forKey: bookID) != nil else { return }
        save()
    }

    /// Gives `survivorID` the settings of `mergedID` when they are the later choice: the
    /// survivor has none, or changed its own before. For one copy of a work merged into
    /// another (`ShelfWorkMerger.absorb`): a manga read from a second source and set to 條漫
    /// has to open that way as the shelf book it joins (feedback #74). The merged copy's own
    /// entry goes when its book is deleted.
    func carrySettings(from mergedID: UUID, to survivorID: UUID) {
        guard mergedID != survivorID, let carried = settingsByBook[mergedID], !carried.isEmpty else { return }
        if let own = settingsByBook[survivorID], !own.isEmpty, own.modifiedAt >= carried.modifiedAt { return }
        // Not an edit: the choice keeps the time the reader made it.
        settingsByBook[survivorID] = BookReaderSettings(
            bookID: survivorID, modifiedAt: carried.modifiedAt, fixedPage: carried.fixedPage
        )
        AppLogger.cache("本書設定：同一部作品合併，帶過被合併那本的設定", context: [
            "from": mergedID.uuidString, "to": survivorID.uuidString,
        ])
        save()
    }

    /// Drops the settings of every book not in `bookIDs`. Pass only a shelf known to be
    /// complete, never the result of a load that may have failed.
    func removeSettings(notIn bookIDs: Set<UUID>) {
        let orphans = settingsByBook.keys.filter { !bookIDs.contains($0) }
        guard !orphans.isEmpty else { return }
        for bookID in orphans {
            settingsByBook.removeValue(forKey: bookID)
        }
        AppLogger.cache("本書設定：移除已不在書架上的書的設定", context: ["count": orphans.count])
        save()
    }

    // MARK: Migration

    /// Moves the reading modes older builds kept in UserDefaults into this store.
    ///
    /// A key whose book is not in `knownBookIDs` stays unless `removesUnknownKeys` is set:
    /// the book may have been deleted, or the shelf may only have failed to load, and only
    /// the caller can tell. Keys go only after their mode is on disk — removing first and
    /// then failing the write would lose it. A book that already has stored settings keeps
    /// them; its leftover key is simply removed.
    ///
    /// Delete this, with the two key prefixes, once no installed build predates the store.
    @discardableResult
    func migrateLegacyFixedPageReadingModes(
        from defaults: UserDefaults,
        knownBookIDs: Set<UUID>,
        removesUnknownKeys: Bool
    ) -> Int {
        var currentModes: [UUID: Int] = [:]
        var legacyModes: [UUID: Int] = [:]
        var keysByBook: [UUID: [String]] = [:]
        for (key, value) in defaults.dictionaryRepresentation() {
            let isCurrentKey = key.hasPrefix(Self.currentModeKeyPrefix)
            guard isCurrentKey || key.hasPrefix(Self.legacyModeKeyPrefix) else { continue }
            let prefixLength = isCurrentKey ? Self.currentModeKeyPrefix.count : Self.legacyModeKeyPrefix.count
            guard let bookID = UUID(uuidString: String(key.dropFirst(prefixLength))) else { continue }
            keysByBook[bookID, default: []].append(key)
            guard let rawValue = value as? Int else { continue }
            if isCurrentKey {
                currentModes[bookID] = rawValue
            } else {
                legacyModes[bookID] = rawValue
            }
        }
        guard !keysByBook.isEmpty else { return 0 }

        var migrated = 0
        let now = Date()
        for bookID in keysByBook.keys where knownBookIDs.contains(bookID) {
            // The newer key first: the same precedence the reader used when it read them.
            guard settingsByBook[bookID]?.fixedPage == nil,
                  let rawValue = currentModes[bookID] ?? legacyModes[bookID],
                  let mode = FixedPageReadingMode(rawValue: rawValue)
            else { continue }
            var settings = settingsByBook[bookID] ?? BookReaderSettings(bookID: bookID, modifiedAt: now)
            settings.fixedPage = mode.recommendedConfiguration
            settings.modifiedAt = now
            settingsByBook[bookID] = settings
            migrated += 1
        }
        if migrated > 0, !save() {
            AppLogger.cache("本書設定：閱讀方向沒有寫入成功，保留舊的設定鍵下次再搬", context: ["count": migrated])
            return 0
        }

        var removedKeys = 0
        for (bookID, keys) in keysByBook where removesUnknownKeys || knownBookIDs.contains(bookID) {
            for key in keys {
                defaults.removeObject(forKey: key)
            }
            removedKeys += keys.count
        }
        AppLogger.cache(
            "本書設定：搬移舊版的閱讀方向",
            context: ["migrated": migrated, "removedKeys": removedKeys, "keptKeys": keysByBook.values.joined().count - removedKeys]
        )
        return migrated
    }

    // MARK: Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            writesBlocked = true
            AppLogger.error("本書設定：無法讀取設定檔，這次啟動不寫入，以免蓋掉它", error: error)
            return
        }
        do {
            let file = try JSONDecoder().decode(File.self, from: data)
            settingsByBook = Dictionary(
                file.books.map { ($0.bookID, $0) },
                uniquingKeysWith: { _, later in later }
            )
        } catch {
            keepUnreadableFile(data, decodingError: error)
        }
    }

    /// A file that does not decode is copied aside under a new name before anything is
    /// written over it, as the header/footer layout does with its corrupt data.
    private func keepUnreadableFile(_ data: Data, decodingError: Error) {
        let stamp = Int(Date().timeIntervalSince1970)
        let backupURL = fileURL.deletingPathExtension().appendingPathExtension("corrupt-\(stamp).json")
        do {
            try data.write(to: backupURL, options: .withoutOverwriting)
            AppLogger.error(
                "本書設定：設定檔無法解析，原檔已另存為 \(backupURL.lastPathComponent)",
                error: decodingError
            )
        } catch {
            writesBlocked = true
            AppLogger.error(
                "本書設定：設定檔無法解析，也無法另存，這次啟動不寫入",
                error: error,
                context: ["decodingError": String(describing: decodingError)]
            )
        }
    }

    @discardableResult
    private func save() -> Bool {
        guard !writesBlocked else {
            AppLogger.cache("本書設定：設定檔先前無法讀取，這次的修改只留在記憶體")
            return false
        }
        let books = settingsByBook.values
            .filter { !$0.isEmpty }
            .sorted { $0.bookID.uuidString < $1.bookID.uuidString }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(File(version: Self.fileVersion, books: books))
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            AppLogger.error("本書設定：無法寫入設定檔", error: error)
            return false
        }
    }
}
