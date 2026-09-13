import Foundation

/// Keeps one built index per book, on disk and in memory.
///
/// Rebuilding is the expensive part — tokenising a 10 MB web novel is seconds, and embedding
/// it is minutes — so an index is built once and reused until its identity changes.
///
/// Storage lives in Application Support, not Caches: a rebuilt index costs the user time and
/// (in the hybrid tier) battery, so the system evicting it under disk pressure would be a
/// worse outcome than the space it occupies.
actor AIBookIndexStore {
    static let shared = AIBookIndexStore()

    private var inMemory: [UUID: AIBookRetrievalIndex] = [:]
    private let directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.directory = base.appendingPathComponent("AIBookIndexes", isDirectory: true)
        }
    }

    /// What is persisted. The identifier is stored alongside the chunks so a load can tell
    /// whether this index was built the way the app builds them now.
    private struct Stored: Codable {
        let identifier: String
        let tier: AIRetrievalTier
        let embeddingIdentifier: String?
        let chunks: [AIContentChunk]
        let sectionTitleByID: [String: String]
        /// Empty in the keyword tier.
        let vectors: [String: [Float]]
    }

    /// The book's index, built if necessary.
    ///
    /// `expectedIdentifier` is the identity the app would build today. A stored index that
    /// does not match is **discarded, not migrated** — that is what makes downloading the
    /// embedding model take effect instead of leaving vector queries running against a
    /// keyword-only index.
    func index(
        for bookID: UUID,
        expectedIdentifier: String,
        build: @Sendable () async throws -> AIBookRetrievalIndex
    ) async throws -> AIBookRetrievalIndex {
        if let cached = inMemory[bookID], cached.identifier == expectedIdentifier {
            return cached
        }
        if let loaded = load(bookID: bookID), loaded.identifier == expectedIdentifier {
            inMemory[bookID] = loaded
            return loaded
        }
        let built = try await build()
        inMemory[bookID] = built
        save(built)
        return built
    }

    func cachedIndex(for bookID: UUID) -> AIBookRetrievalIndex? {
        inMemory[bookID]
    }

    func discard(bookID: UUID) {
        inMemory.removeValue(forKey: bookID)
        try? FileManager.default.removeItem(at: fileURL(for: bookID))
    }

    /// Every book's index. Used when the embedding model is downloaded or removed, so the
    /// change takes effect everywhere rather than one book at a time.
    func discardAll() {
        inMemory.removeAll()
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Persistence

    private func fileURL(for bookID: UUID) -> URL {
        directory.appendingPathComponent("\(bookID.uuidString).json")
    }

    private func load(bookID: UUID) -> AIBookRetrievalIndex? {
        let url = fileURL(for: bookID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            // A file we cannot read is a file we cannot trust to be the right index; drop it
            // rather than leaving it to fail the same way on every launch.
            AppLogger.error("AI index unreadable; discarding", context: ["book": bookID.uuidString])
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return AIBookRetrievalIndex(
            bookID: bookID,
            chunks: stored.chunks,
            sectionTitleByID: stored.sectionTitleByID,
            tier: stored.tier,
            embeddingIdentifier: stored.embeddingIdentifier,
            vectors: stored.vectors
        )
    }

    private func save(_ index: AIBookRetrievalIndex) {
        let stored = Stored(
            identifier: index.identifier,
            tier: index.tier,
            embeddingIdentifier: index.embeddingIdentifier,
            chunks: index.chunks,
            sectionTitleByID: index.sectionTitleByID,
            vectors: index.storedVectors
        )
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(stored).write(to: fileURL(for: index.bookID), options: .atomic)
        } catch {
            // Not fatal: the index is already usable in memory, and it will simply be rebuilt
            // next launch. Logged rather than swallowed so a device that can never persist
            // one is diagnosable.
            AppLogger.error("AI index not saved", context: [
                "book": index.bookID.uuidString,
                "error": error.localizedDescription,
            ])
        }
    }
}
