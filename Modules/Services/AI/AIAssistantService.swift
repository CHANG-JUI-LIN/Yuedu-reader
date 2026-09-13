import Combine
import Foundation

/// The one entry point the AI screens call.
///
/// Views ask for an answer, a recap or a character card; this owns the index, the spoiler
/// ceiling, the provider, and the degradation when any of them is missing. Nothing above this
/// line builds a prompt or touches retrieval — the project rule is that a view calls one
/// service-level use case and the service owns the rest.
@MainActor
final class AIAssistantService: ObservableObject {
    static let shared = AIAssistantService()

    /// What went wrong, in terms a reader can act on.
    enum Failure: LocalizedError, Equatable {
        case unavailable(AIProviderAssembly.Unavailable)
        case bookNotIndexed
        case emptyBook

        var errorDescription: String? {
            switch self {
            case let .unavailable(reason): return reason.message
            case .bookNotIndexed: return localized("這本書還沒建立索引")
            case .emptyBook: return localized("這本書沒有可以分析的內容")
            }
        }
    }

    /// Progress of a book's index build, so a long one is visible rather than a frozen screen.
    enum IndexState: Equatable {
        case idle
        case building(completed: Int, total: Int)
        case ready(chunkCount: Int, tier: AIRetrievalTier)
        case failed(String)
    }

    @Published private(set) var indexState: [UUID: IndexState] = [:]

    private let store: AIBookIndexStore

    init(store: AIBookIndexStore = .shared) {
        self.store = store
    }

    // MARK: - Index

    /// The identity an index for this book should have right now.
    ///
    /// Reads the embedding tier at call time, so downloading or removing the model changes the
    /// expected identity and the next request rebuilds instead of querying a mismatched index.
    private func expectedIdentifier(for adapter: AIBookContentAdapter) -> String {
        let embedding = AIEmbeddingModelStore.shared.readyProvider()
        return AIBookRetrievalIndex.identifier(
            tier: embedding == nil ? .keyword : .hybrid,
            embeddingIdentifier: embedding?.identifier,
            contentFingerprint: adapter.contentFingerprint
        )
    }

    /// Builds — or reuses — the index for an open book.
    func index(
        forBook bookID: UUID,
        adapter: AIBookContentAdapter
    ) async throws -> AIBookRetrievalIndex {
        let expected = expectedIdentifier(for: adapter)
        let embedding = AIEmbeddingModelStore.shared.readyProvider()
        indexState[bookID] = .building(completed: 0, total: 0)
        do {
            let index = try await store.index(for: bookID, expectedIdentifier: expected) {
                let chunks = AIPublicationChunker(
                    maximumCharacters: 800,
                    overlapCharacters: 120,
                    minimumCharacters: 200
                ).chunks(from: adapter)
                guard !chunks.isEmpty else { throw Failure.emptyBook }

                var vectors: [String: [Float]] = [:]
                if let embedding {
                    // Batched so a long book reports progress and stays cancellable, rather
                    // than disappearing into one call that either finishes or does not.
                    let batchSize = 32
                    var completed = 0
                    for start in stride(from: 0, to: chunks.count, by: batchSize) {
                        try Task.checkCancellation()
                        let slice = Array(chunks[start..<min(start + batchSize, chunks.count)])
                        let encoded = try await embedding.embed(slice.map(\.text))
                        for (chunk, vector) in zip(slice, encoded) {
                            vectors[chunk.id] = vector
                        }
                        completed += slice.count
                        let progressCount = completed
                        await MainActor.run {
                            self.indexState[bookID] = .building(
                                completed: progressCount,
                                total: chunks.count
                            )
                        }
                    }
                }
                return AIBookRetrievalIndex(
                    bookID: bookID,
                    chunks: chunks,
                    sectionTitleByID: adapter.sectionTitleByID,
                    tier: embedding == nil ? .keyword : .hybrid,
                    embeddingIdentifier: embedding?.identifier,
                    vectors: vectors,
                    contentFingerprint: adapter.contentFingerprint
                )
            }
            indexState[bookID] = .ready(chunkCount: index.chunks.count, tier: index.tier)
            return index
        } catch {
            indexState[bookID] = .failed(error.localizedDescription)
            throw error
        }
    }

    // MARK: - Use cases

    /// Answer a question about the book, limited to what the reader has already read.
    func answer(
        question: String,
        bookID: UUID,
        adapter: AIBookContentAdapter,
        progress: Double
    ) async throws -> LLMGenerationResult {
        let provider = try resolveProvider()
        let index = try await index(forBook: bookID, adapter: adapter)
        let hits = try await index.retrieve(
            query: question,
            maximumProgress: progress,
            limit: 8,
            embedding: AIEmbeddingModelStore.shared.readyProvider()
        )
        return try await AIRAGPipeline.answer(
            query: question,
            hits: hits,
            provider: provider,
            sectionTitleByID: index.sectionTitleByID,
            spoilerLimited: progress < 1
        )
    }

    /// 前情提要 for everything up to the reader's position.
    func recap(
        bookID: UUID,
        bookTitle: String,
        adapter: AIBookContentAdapter,
        progress: Double,
        stored: AIRecap?
    ) async throws -> AIRecap? {
        if AIRecap.canReuse(stored, atProgress: progress) { return stored }
        let provider = try resolveProvider()
        let index = try await index(forBook: bookID, adapter: adapter)
        // The most recent already-read passages, oldest first, so the recap reads forwards.
        let readable = AISpoilerSafeFilter.chunks(index.chunks, maximumProgress: progress)
        let seed = Array(readable.suffix(12))
        guard !seed.isEmpty else { return nil }
        return try await AIRecap.generate(
            chunks: seed,
            bookTitle: bookTitle,
            progress: progress,
            provider: provider
        )
    }

    /// A character card. Searches the **whole book**, which is this feature's documented
    /// exception to the spoiler boundary — the card screen tells the reader that.
    func characterCard(
        name: String,
        bookID: UUID,
        adapter: AIBookContentAdapter,
        onStep: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> AICharacterProfile {
        let provider = try resolveProvider()
        let index = try await index(forBook: bookID, adapter: adapter)
        let result = try await AIAgenticAssistant.run(
            task: AICharacterProfile.task,
            userInput: name,
            index: index,
            provider: provider,
            embedding: AIEmbeddingModelStore.shared.readyProvider(),
            scope: 1.0,
            maxSteps: 3,
            onStep: onStep
        )
        let profile = AICharacterProfile.parse(
            fromAnswer: result.answer,
            name: name,
            gatheredChunkIDs: result.retrievedChunks.map(\.id),
            provider: result.provider,
            model: result.model
        )
        AICharacterCardStore.shared.upsert(profile, forBook: bookID)
        return profile
    }

    /// Asks the model which of the heuristic's candidates are actually people.
    ///
    /// One call for the whole book. Without it the cast list fills with 試探, 一邊, 劉癩子苦 —
    /// artefacts of stripping a speech verb off the end of a sentence, which no amount of
    /// hand-written character rules fixes in Chinese.
    func buildSpeakerRoster(
        bookID: UUID,
        adapter: AIBookContentAdapter,
        candidates: [AISpeakerRoster.Candidate]
    ) async throws -> [String: String] {
        let provider = try resolveProvider()
        guard !candidates.isEmpty else { return [:] }
        let roster = try await AISpeakerRoster.build(candidates: candidates, provider: provider)
        AISpeakerRosterStore.shared.save(roster, forBook: bookID)
        return roster
    }

    // MARK: - Availability

    var isConfigured: Bool {
        if case .success = AIProviderAssembly.makeProvider() { return true }
        return false
    }

    private func resolveProvider() throws -> any LLMProviding {
        switch AIProviderAssembly.makeProvider() {
        case let .success(provider): return provider
        case let .failure(reason): throw Failure.unavailable(reason)
        }
    }
}
