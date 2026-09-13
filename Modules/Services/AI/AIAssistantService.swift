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

    @Published private(set) var indexedChapterCounts: [UUID: Int] = [:]
    @Published private(set) var indexState: [UUID: IndexState] = [:]

    private let store: AIBookIndexStore
    private let injectedProvider: (any LLMProviding)?
    private let cards: AICharacterCardStore
    private let diagnosticOrigin: AIDiagnostics.Origin
    private var latestSnapshots: [UUID: String] = [:]

    func activate(_ adapter: AIBookContentAdapter) {
        if latestSnapshots[adapter.chunkBookID] != adapter.contentFingerprint {
            indexedChapterCounts[adapter.chunkBookID] = 0
            indexState[adapter.chunkBookID] = .idle
        }
        latestSnapshots[adapter.chunkBookID] = adapter.contentFingerprint
    }

    init(store: AIBookIndexStore = .shared, provider: (any LLMProviding)? = nil, cards: AICharacterCardStore? = nil, diagnosticOrigin: AIDiagnostics.Origin = .observed) {
        self.store = store
        self.injectedProvider = provider
        self.cards = cards ?? .shared
        self.diagnosticOrigin = diagnosticOrigin
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
        try Task.checkCancellation()
        let indexStarted = Date()
        if AIDiagnostics.current == nil { activate(adapter) }
        guard latestSnapshots[bookID] == adapter.contentFingerprint else { throw CancellationError() }
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
                        try AIEmbeddingContract.validate(encoded, count: slice.count, dimensions: embedding.dimensions)
                        for (chunk, vector) in zip(slice, encoded) {
                            vectors[chunk.id] = vector
                        }
                        completed += slice.count
                        let progressCount = completed
                        await MainActor.run {
                            guard self.latestSnapshots[bookID] == adapter.contentFingerprint else { return }
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
                    contentFingerprint: adapter.contentFingerprint,
                    manifest: adapter.manifest
                )
            }
            if latestSnapshots[bookID] == adapter.contentFingerprint {
                indexedChapterCounts[bookID] = Set(index.chunks.map { $0.start.spineIndex }).count
                indexState[bookID] = .ready(chunkCount: index.chunks.count, tier: index.tier)
            }
            AIDiagnostics.current?.event("indexReady", ["indexedChapters": "\(Set(index.chunks.map { $0.start.spineIndex }).count)",
                "elapsedMs": "\(Date().timeIntervalSince(indexStarted) * 1000)",
                "tier": index.tier.rawValue, "embedding": index.embeddingIdentifier ?? "none",
                "embeddingDimensions": embedding.map { String($0.dimensions) } ?? "none",
                "contract": embedding == nil ? "notApplicable" : "passed", "semanticQuality": "notEvaluated"])
            return index
        } catch {
            if latestSnapshots[bookID] == adapter.contentFingerprint { indexState[bookID] = .failed(error.localizedDescription) }
            throw error
        }
    }

    // MARK: - Use cases

    /// Answer a question about the book, limited to what the reader has already read.
    func answer(
        question: String,
        bookID: UUID,
        adapter: AIBookContentAdapter,
        progress: Double,
        boundary: AIReadingBoundary? = nil
    ) async throws -> LLMGenerationResult {
        let boundary = boundary ?? adapter.boundary()
        return try await traced("answer", adapter: adapter, boundary: boundary) {
            let provider = try resolveProvider()
            let index = try await index(forBook: bookID, adapter: adapter)
            let hits = try await index.retrieve(
                query: question,
                maximumProgress: progress,
                limit: 8,
                embedding: AIEmbeddingModelStore.shared.readyProvider(),
                boundary: boundary
            )
            return try await AIRAGPipeline.answer(
                query: question,
                hits: hits,
                provider: provider,
                sectionTitleByID: index.sectionTitleByID,
                spoilerLimited: !boundary.wholeBook
            )
        }
    }

    /// Recap of at most twelve recent eligible chunks.
    func recap(
        bookID: UUID,
        bookTitle: String,
        adapter: AIBookContentAdapter,
        progress: Double,
        stored: AIRecap?,
        boundary: AIReadingBoundary? = nil
    ) async throws -> AIRecap? {
        let boundary = boundary ?? adapter.boundary()
        return try await traced("recap", adapter: adapter, boundary: boundary) {
            if AIRecap.canReuse(stored, atProgress: progress, boundary: boundary) {
                AIDiagnostics.current?.event("recapCache", ["result": "safeHit"])
                return stored
            }
            let provider = try resolveProvider()
            let index = try await index(forBook: bookID, adapter: adapter)
            // The most recent already-read passages, oldest first, so the recap reads forwards.
            let selectionStarted = Date()
            let readable = index.chunks.filter { boundary.contains($0) }
            let seed = Array(readable.suffix(12))
            AIDiagnostics.current?.retrieval(total: index.chunks.count, eligible: readable.count, candidates: [seed.count],
                hits: seed.map { .init(chunk: $0, score: 0) }, scoreType: "recentReadingOrder", degradation: nil, elapsed: Date().timeIntervalSince(selectionStarted))
            guard !seed.isEmpty else { return nil }
            return try await AIRecap.generate(
                chunks: seed,
                bookTitle: bookTitle,
                progress: progress,
                provider: provider,
                boundary: boundary
            )
        }
    }

    /// A character card with an explicit, versioned scope selected by the reader.
    func characterCard(
        name: String,
        bookID: UUID,
        adapter: AIBookContentAdapter,
        boundary: AIReadingBoundary,
        onStep: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> AICharacterProfile {
        return try await traced("characterCard", adapter: adapter, boundary: boundary) {
            let provider = try resolveProvider()
            let index = try await index(forBook: bookID, adapter: adapter)
            let result = try await AIAgenticAssistant.run(
                task: AICharacterProfile.task,
                userInput: name,
                index: index,
                provider: provider,
                embedding: AIEmbeddingModelStore.shared.readyProvider(),
                scope: boundary.wholeBook ? 1 : adapter.progress(forSpine: boundary.spineIndex, charOffset: boundary.utf16Offset),
                boundary: boundary,
                maxSteps: 3,
                onStep: onStep
            )
            var profile = try AICharacterProfile.parse(
                fromAnswer: result.answer,
                name: name,
                gatheredChunkIDs: result.retrievedChunks.map(\.id),
                provider: result.provider,
                model: result.model,
                citedChunkIDs: result.citationChunkIDs
            )
            profile.sourceBoundary = boundary
            profile.retrievedEvidenceIDs = result.retrievedChunks.map(\.id)
            profile.maximumEvidencePosition = result.retrievedChunks.map(\.end).max {
                $0.spineIndex == $1.spineIndex ? $0.charOffset < $1.charOffset : $0.spineIndex < $1.spineIndex
            }
            try Task.checkCancellation()
            guard latestSnapshots[bookID] == adapter.contentFingerprint else { throw CancellationError() }
            AIDiagnostics.current?.event("characterParsing", ["result": "valid", "retrieved": "\(result.retrievedChunks.count)", "cited": "\(profile.citationChunkIDs.count)"])
            cards.upsert(profile, forBook: bookID)
            return profile
        }
    }

    /// Asks the model which of the heuristic's candidates are actually people.
    ///
    /// One call for the whole book. Without it the cast list fills with 試探, 一邊, 劉癩子苦 —
    /// artefacts of stripping a speech verb off the end of a sentence, which no amount of
    /// hand-written character rules fixes in Chinese.
    func buildSpeakerRoster(
        bookID: UUID,
        adapter: AIBookContentAdapter,
        candidates: [AISpeakerRoster.Candidate],
        boundary: AIReadingBoundary
    ) async throws -> [String: String] {
        return try await traced("speakerRoster", adapter: adapter, boundary: boundary) {
            let provider = try resolveProvider()
            guard !candidates.isEmpty else { return [:] }
            let roster = try await AISpeakerRoster.build(candidates: candidates, provider: provider)
            try Task.checkCancellation()
            guard latestSnapshots[bookID] == adapter.contentFingerprint else { throw CancellationError() }
            AISpeakerRosterStore.shared.save(roster, forBook: bookID, boundary: boundary)
            return roster
        }
    }

    // MARK: - Availability

    var isConfigured: Bool {
        if case .success = AIProviderAssembly.makeProvider() { return true }
        return false
    }

    private func traced<T>(_ feature: String, adapter: AIBookContentAdapter, boundary: AIReadingBoundary, operation: () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        activate(adapter)
        let trace = AIDiagnosticStore.shared.begin(feature: feature, bookID: adapter.chunkBookID, adapter: adapter, boundary: boundary, origin: diagnosticOrigin)
        defer { AIDiagnosticStore.shared.finish(trace) }
        return try await AIDiagnostics.$current.withValue(trace) {
            do {
                guard boundary.sourceVersion == adapter.contentFingerprint else { throw CancellationError() }
                let result = try await operation()
                try Task.checkCancellation()
                guard latestSnapshots[adapter.chunkBookID] == adapter.contentFingerprint else { throw CancellationError() }
                trace.event("complete", ["result": "success"])
                return result
            } catch {
                trace.event("complete", ["result": error is CancellationError ? "cancelled" : "failed", "kind": String(describing: type(of: error))])
                throw error
            }
        }
    }

    private func resolveProvider() throws -> any LLMProviding {
        if let injectedProvider { return AITracedProvider(base: injectedProvider) }
        switch AIProviderAssembly.makeProvider() {
        case let .success(provider): return AITracedProvider(base: provider)
        case let .failure(reason): throw Failure.unavailable(reason)
        }
    }
}
