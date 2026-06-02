import Foundation

protocol ReadingPositionStore: AnyObject, Sendable {
    func save(_ position: CoreTextReadingPosition, for bookId: String) async
    func load(for bookId: String) async -> CoreTextReadingPosition?
    func loadSync(for bookId: String) -> CoreTextReadingPosition?
    func flush(for bookId: String) async
}

final class JSONFileReadingPositionStore: ReadingPositionStore {
    private let baseURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.baseURL = docs.appendingPathComponent("reading_position", isDirectory: true)
        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    }

    private func fileURL(for bookId: String) -> URL {
        baseURL.appendingPathComponent("\(bookId).json")
    }

    func save(_ position: CoreTextReadingPosition, for bookId: String) async {
        guard let data = try? encoder.encode(position) else { return }
        let url = fileURL(for: bookId)
        try? data.write(to: url, options: .atomic)
        // Debounce the cloud push: positions save on every page turn, so writing
        // each one directly would flood Firestore.
        Task { @MainActor in
            FirestoreSyncManager.shared.scheduleReadingPositionPush(position, for: bookId)
        }
        print("[ProgressTrace][PositionStore] save bookId=\(bookId) spine=\(position.spineIndex) charOffset=\(position.charOffset)")
    }

    func load(for bookId: String) async -> CoreTextReadingPosition? {
        loadSync(for: bookId)
    }

    func loadSync(for bookId: String) -> CoreTextReadingPosition? {
        let url = fileURL(for: bookId)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            print("[ProgressTrace][PositionStore] load bookId=\(bookId) result=miss")
            return nil
        }
        let position = try? decoder.decode(CoreTextReadingPosition.self, from: data)
        print("[ProgressTrace][PositionStore] load bookId=\(bookId) spine=\(position?.spineIndex.description ?? "nil") charOffset=\(position?.charOffset.description ?? "nil")")
        return position
    }

    func flush(for bookId: String) async {
    }

    static func replacePositionsFromSync(_ positions: [String: CoreTextReadingPosition]) {
        let store = JSONFileReadingPositionStore()
        for (bookId, position) in positions {
            guard let data = try? store.encoder.encode(position) else { continue }
            try? data.write(to: store.fileURL(for: bookId), options: .atomic)
        }
    }
}
