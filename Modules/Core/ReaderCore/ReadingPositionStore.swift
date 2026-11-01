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
        guard let data = try? encoder.encode(StoredPosition(position)) else { return }
        let url = fileURL(for: bookId)
        try? data.write(to: url, options: .atomic)
        // Debounce the cloud push: positions save on every page turn, so writing
        // each one directly would flood Firestore.
        Task { @MainActor in
            FirestoreSyncManager.shared.scheduleReadingPositionPush(position, for: bookId)
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

    /// The file: the position's own keys, which older builds decode, and the 0.11 stamp
    /// they ignore. A position written through `replacePositionsFromSync` carries no stamp:
    /// another device's build wrote it.
    private struct StoredPosition: Codable {
        let spineIndex: Int
        let charOffset: Int
        var translationOffset: Int?
        var countsPictures: Bool?

        init(_ position: CoreTextReadingPosition) {
            spineIndex = position.spineIndex
            charOffset = position.charOffset
            translationOffset = position.translationOffset
            countsPictures = true
        }
    }

    static func replacePositionsFromSync(_ positions: [String: CoreTextReadingPosition]) {
        let store = JSONFileReadingPositionStore()
        for (bookId, position) in positions {
            guard let data = try? store.encoder.encode(position) else { continue }
            try? data.write(to: store.fileURL(for: bookId), options: .atomic)
        }
    }
}
