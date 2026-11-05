import Foundation

protocol ReadingPositionStore: AnyObject, Sendable {
    func save(_ position: CoreTextReadingPosition, for bookId: String) async
    func load(for bookId: String) async -> CoreTextReadingPosition?
    func loadSync(for bookId: String) -> CoreTextReadingPosition?
    func flush(for bookId: String) async
    /// Whether the saved position was written by a build whose browser engine gives every
    /// picture one character of a chapter's source text (YueduCoreText 0.11). A position
    /// written before is moved once by `PictureOffsetMigration`.
    func countsPictures(for bookId: String) -> Bool
}

extension ReadingPositionStore {
    /// A store with no files from before 0.11 holds nothing to move.
    func countsPictures(for bookId: String) -> Bool { true }
}

final class JSONFileReadingPositionStore: ReadingPositionStore {
    private let baseURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(baseURL: URL = StorageLocations.readingPosition) {
        self.baseURL = baseURL
    }

    private func fileURL(for bookId: String) -> URL {
        baseURL.appendingPathComponent("\(bookId).json")
    }

    func save(_ position: CoreTextReadingPosition, for bookId: String) async {
        // A converted book's text version, from its reader (`ConvertedTextVersions`).
        let textVersion = ConvertedTextVersions.shared.version(for: bookId)
        guard let data = try? encoder.encode(StoredPosition(position, textVersion: textVersion)) else { return }
        let url = fileURL(for: bookId)
        try? data.write(to: url, options: .atomic)
        // Debounce the cloud push: positions save on every page turn, so writing
        // each one directly would flood Firestore.
        Task { @MainActor in
            FirestoreSyncManager.shared.scheduleReadingPositionPush(position, for: bookId, textVersion: textVersion)
        }
        AppLogger.cache("[ProgressTrace][PositionStore] save bookId=\(bookId) spine=\(position.spineIndex) charOffset=\(position.charOffset)")
    }

    func load(for bookId: String) async -> CoreTextReadingPosition? {
        loadSync(for: bookId)
    }

    func loadSync(for bookId: String) -> CoreTextReadingPosition? {
        let url = fileURL(for: bookId)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            AppLogger.cache("[ProgressTrace][PositionStore] load bookId=\(bookId) result=miss")
            return nil
        }
        let position = try? decoder.decode(CoreTextReadingPosition.self, from: data)
        AppLogger.cache("[ProgressTrace][PositionStore] load bookId=\(bookId) spine=\(position?.spineIndex.description ?? "nil") charOffset=\(position?.charOffset.description ?? "nil")")
        if position != nil, ConvertedTextVersions.shared.version(for: bookId) != nil {
            let stamp = (try? decoder.decode(StoredPosition.self, from: data))?.textVersion
            guard ConvertedTextVersions.shared.indexesReadText(stamp, bookId: bookId) else {
                // Its offsets index another text. The reader's first save replaces it at this
                // device's version: last writer wins, as across devices.
                AppLogger.cache("[ConvertedText] position of another text version not restored bookId=\(bookId) stamp=\(stamp.map(String.init) ?? "none")", level: .notice)
                return nil
            }
        }
        return position
    }

    func flush(for bookId: String) async {
    }

    func countsPictures(for bookId: String) -> Bool {
        guard let data = try? Data(contentsOf: fileURL(for: bookId)) else { return true }
        do {
            return try decoder.decode(StoredPosition.self, from: data).countsPictures == true
        } catch {
            AppLogger.cache("[PictureOffsets] unreadable position file bookId=\(bookId): \(error)")
            return true
        }
    }

    /// The file: the position's own keys, which older builds decode, and the stamps they
    /// ignore — 0.11's, and a converted book's text version (`ConvertedTextVersions`). A
    /// position written through `replacePositionsFromSync` carries no 0.11 stamp: another
    /// device's build wrote it. It keeps the text version that device stamped.
    fileprivate struct StoredPosition: Codable {
        let spineIndex: Int
        let charOffset: Int
        var translationOffset: Int?
        var countsPictures: Bool?
        var textVersion: Int?

        init(_ position: CoreTextReadingPosition, countsPictures: Bool? = true, textVersion: Int?) {
            spineIndex = position.spineIndex
            charOffset = position.charOffset
            translationOffset = position.translationOffset
            self.countsPictures = countsPictures
            self.textVersion = textVersion
        }
    }

    /// Another device's positions, from Firestore. They carry no 0.11 stamp.
    static func replacePositionsFromSync(_ positions: [String: SyncedReadingPosition]) {
        JSONFileReadingPositionStore().applySyncItems(positions.map { bookId, synced in
            ReadingPositionSyncItem(bookId: bookId, position: synced.position, textVersion: synced.textVersion)
        })
    }

    // MARK: Sync

    /// Every book's saved position, with when it was saved: the file's modification date, the
    /// clock iCloud merges positions by (`ICloudSyncManager`, "reading_positions_v1"). Only
    /// `<book id>.json` files: the folder also holds TXT re-index journals.
    func syncItems() -> [(item: ReadingPositionSyncItem, savedAt: Date)] {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: baseURL.path)
        } catch {
            AppLogger.cache("[PositionSync] position folder unreadable: \(error)", level: .error)
            return []
        }
        return names.compactMap { name -> (item: ReadingPositionSyncItem, savedAt: Date)? in
            guard name.hasSuffix(".json") else { return nil }
            let bookId = String(name.dropLast(".json".count))
            guard UUID(uuidString: bookId) != nil else { return nil }
            let url = baseURL.appendingPathComponent(name)
            do {
                let saved = try decoder.decode(StoredPosition.self, from: Data(contentsOf: url))
                let savedAt = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
                return (ReadingPositionSyncItem(bookId: bookId, saved), savedAt ?? .distantPast)
            } catch {
                AppLogger.cache("[PositionSync] unreadable position file bookId=\(bookId): \(error)", level: .error)
                return nil
            }
        }
    }

    /// Writes the positions another device saved over this device's, as that device stamped
    /// them, and returns how many it wrote. One already saved here as it is, or one of a text
    /// version other than this device's saved position, is left: each version indexes its own
    /// text, and this device can read only its own.
    @discardableResult
    func applySyncItems(_ items: [ReadingPositionSyncItem]) -> Int {
        var written = 0
        for item in items {
            let url = fileURL(for: item.bookId)
            if FileManager.default.fileExists(atPath: url.path) {
                do {
                    let saved = try decoder.decode(StoredPosition.self, from: Data(contentsOf: url))
                    if ReadingPositionSyncItem(bookId: item.bookId, saved) == item { continue }
                    if (saved.textVersion ?? ConvertedTextVersions.unstamped) != (item.textVersion ?? ConvertedTextVersions.unstamped) {
                        AppLogger.cache("[ConvertedText] synced position of another text version kept apart bookId=\(item.bookId) saved=\(saved.textVersion.map(String.init) ?? "none") synced=\(item.textVersion.map(String.init) ?? "none")", level: .notice)
                        continue
                    }
                } catch {
                    AppLogger.cache("[PositionSync] unreadable position file bookId=\(item.bookId), replaced: \(error)", level: .error)
                }
            }
            let stored = StoredPosition(item.position, countsPictures: item.countsPictures, textVersion: item.textVersion)
            do {
                try encoder.encode(stored).write(to: url, options: .atomic)
                written += 1
                AppLogger.cache("[ProgressTrace][PositionStore] synced bookId=\(item.bookId) spine=\(item.spineIndex) charOffset=\(item.charOffset)")
            } catch {
                AppLogger.cache("[PositionSync] synced position not written bookId=\(item.bookId): \(error)", level: .error)
            }
        }
        return written
    }
}

/// One book's saved text-reader position as iCloud syncs it: what its file holds, the stamps
/// included, so the device it reaches reads it as the device that saved it did. Text readers
/// restore only from this file (`ReaderNavigator.restore()`); the book record's
/// `currentPosition` is the shelf's percentage, and does not place the reader.
struct ReadingPositionSyncItem: Codable, Equatable, Sendable {
    var bookId: String
    var spineIndex: Int
    var charOffset: Int
    var translationOffset: Int?
    /// The file's 0.11 stamp (`PictureOffsetMigration`); absent from one saved unstamped,
    /// which the receiving device moves once, as the saving device would have.
    var countsPictures: Bool?
    /// A converted book's text version (`ConvertedTextVersions`).
    var textVersion: Int?

    init(bookId: String, position: CoreTextReadingPosition, countsPictures: Bool? = nil, textVersion: Int? = nil) {
        self.bookId = bookId
        spineIndex = position.spineIndex
        charOffset = position.charOffset
        translationOffset = position.translationOffset
        self.countsPictures = countsPictures
        self.textVersion = textVersion
    }

    fileprivate init(bookId: String, _ saved: JSONFileReadingPositionStore.StoredPosition) {
        self.init(bookId: bookId,
                  position: CoreTextReadingPosition(spineIndex: saved.spineIndex, charOffset: saved.charOffset,
                                                    translationOffset: saved.translationOffset),
                  countsPictures: saved.countsPictures, textVersion: saved.textVersion)
    }

    var position: CoreTextReadingPosition {
        CoreTextReadingPosition(spineIndex: spineIndex, charOffset: charOffset, translationOffset: translationOffset)
    }
}

/// A reading position from another device, with the converted text version it indexes
/// (nil for a book that is not converted, or one saved unstamped).
struct SyncedReadingPosition: Equatable, Sendable {
    var position: CoreTextReadingPosition
    var textVersion: Int? = nil
}
