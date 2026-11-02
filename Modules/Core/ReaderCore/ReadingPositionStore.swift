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

    init() {
        self.baseURL = StorageLocations.readingPosition
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
    private struct StoredPosition: Codable {
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

    /// Another device's positions. One stamped with a text version other than this device's
    /// saved position is not written over it: each indexes its own text, and this device
    /// can read only its own.
    static func replacePositionsFromSync(_ positions: [String: SyncedReadingPosition]) {
        let store = JSONFileReadingPositionStore()
        for (bookId, synced) in positions {
            let url = store.fileURL(for: bookId)
            if let data = try? Data(contentsOf: url),
               let saved = try? store.decoder.decode(StoredPosition.self, from: data),
               (saved.textVersion ?? ConvertedTextVersions.unstamped) != (synced.textVersion ?? ConvertedTextVersions.unstamped) {
                AppLogger.cache("[ConvertedText] synced position of another text version kept apart bookId=\(bookId) saved=\(saved.textVersion.map(String.init) ?? "none") synced=\(synced.textVersion.map(String.init) ?? "none")", level: .notice)
                continue
            }
            let stored = StoredPosition(synced.position, countsPictures: nil, textVersion: synced.textVersion)
            guard let data = try? store.encoder.encode(stored) else { continue }
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// A reading position from another device, with the converted text version it indexes
/// (nil for a book that is not converted, or one saved unstamped).
struct SyncedReadingPosition: Equatable, Sendable {
    var position: CoreTextReadingPosition
    var textVersion: Int? = nil
}
