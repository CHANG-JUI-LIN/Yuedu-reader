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
    private var pending: [String: Task<AIBookRetrievalIndex, Error>] = [:]
    private var latest: [UUID: String] = [:]
    private var loadFailure: [UUID: String] = [:]

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
        let schema: Int
        let contentFingerprint: String
        let manifest: AISourceManifest?
        let chunkerConfiguration: String
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
        onCacheDecision: (@Sendable (String) -> Void)? = nil,
        build: @escaping @Sendable () async throws -> AIBookRetrievalIndex
    ) async throws -> AIBookRetrievalIndex {
        latest[bookID] = expectedIdentifier
        let key = "\(bookID):\(expectedIdentifier)"
        if let cached = inMemory[bookID], cached.identifier == expectedIdentifier {
            onCacheDecision?("memoryHit")
            AIDiagnostics.current?.event("index", ["cache": "memoryHit"])
            return cached
        }
        let loaded = load(bookID: bookID)
        if let loaded, loaded.identifier == expectedIdentifier {
            inMemory[bookID] = loaded
            onCacheDecision?("diskHit")
            AIDiagnostics.current?.event("index", ["cache": "diskHit"])
            return loaded
        }
        if let task = pending[key] {
            onCacheDecision?("sharedBuild")
            AIDiagnostics.current?.event("index", ["cache": "sharedBuild"])
            return try await task.value
        }
        let reason = loaded.map { expectedIdentifier.hasSuffix("@" + $0.contentFingerprint) ? "configurationChanged" : "sourceChanged" }
            ?? loadFailure[bookID] ?? "unknown"
        AIDiagnostics.current?.event("index", ["cache": "rebuild", "reason": reason])
        let task = Task { try await build() }
        pending[key] = task
        defer { pending.removeValue(forKey: key) }
        let built = try await task.value
        guard built.bookID == bookID, built.identifier == expectedIdentifier else {
            throw AIEmbeddingContract.Failure.artifactMismatch
        }
        if latest[bookID] == expectedIdentifier {
            inMemory[bookID] = built
            save(built)
        }
        return built
    }

    func cachedIndex(for bookID: UUID) -> AIBookRetrievalIndex? {
        inMemory[bookID]
    }

    func discard(bookID: UUID) {
        latest.removeValue(forKey: bookID)
        inMemory.removeValue(forKey: bookID)
        try? FileManager.default.removeItem(at: fileURL(for: bookID))
    }

    /// Every book's index. Used when the embedding model is downloaded or removed, so the
    /// change takes effect everywhere rather than one book at a time.
    func discardAll() {
        latest.removeAll()
        inMemory.removeAll()
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Persistence

    private func fileURL(for bookID: UUID) -> URL {
        directory.appendingPathComponent("\(bookID.uuidString).json")
    }

    private func load(bookID: UUID) -> AIBookRetrievalIndex? {
        let url = fileURL(for: bookID)
        loadFailure[bookID] = "missingFile"
        guard let data = try? Data(contentsOf: url) else { return nil }
        loadFailure[bookID] = "unreadableSchema"
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            // A file we cannot read is a file we cannot trust to be the right index; drop it
            // rather than leaving it to fail the same way on every launch.
            AppLogger.error("AI index unreadable; discarding", context: ["book": bookID.uuidString])
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        loadFailure[bookID] = "schemaOrManifestMismatch"
        guard stored.schema == 2, stored.manifest.map({ $0.identifier == stored.contentFingerprint }) ?? true else { return nil }
        let loaded = AIBookRetrievalIndex(
            bookID: bookID,
            chunks: stored.chunks,
            sectionTitleByID: stored.sectionTitleByID,
            tier: stored.tier,
            embeddingIdentifier: stored.embeddingIdentifier,
            vectors: stored.vectors,
            contentFingerprint: stored.contentFingerprint,
            manifest: stored.manifest,
            chunkerConfiguration: stored.chunkerConfiguration
        )
        loadFailure[bookID] = "identifierDoesNotMatchConfiguration"
        guard loaded.identifier == stored.identifier else { return nil }
        return loaded
    }

    private func save(_ index: AIBookRetrievalIndex) {
        let stored = Stored(
            schema: 2,
            contentFingerprint: index.contentFingerprint,
            manifest: index.manifest,
            chunkerConfiguration: index.chunkerConfiguration,
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
