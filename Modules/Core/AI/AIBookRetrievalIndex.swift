//
// Derived from ChatBook (https://github.com/bsnmldb/ChatBook),
// Sources/ChatBookCore/Retrieval/BookRetrievalIndex.swift — Apache License 2.0.
// See NOTICE at the repository root.
//
import Foundation

/// Turns a passage into a vector. Absent until the user chooses to download a model.
protocol AIEmbeddingProviding: Sendable {
    var identifier: String { get }
    var dimensions: Int { get }
    func embed(_ texts: [String]) async throws -> [[Float]]
    /// Queries and passages are not always encoded the same way — instruction-tuned models
    /// prefix one and not the other — so this is separate even though it usually forwards.
    func embedQuery(_ text: String) async throws -> [Float]
}

extension AIEmbeddingProviding {
    func embedQuery(_ text: String) async throws -> [Float] {
        let vectors = try await embed([text])
        guard vectors.count == 1 else { throw AIEmbeddingContract.Failure.countMismatch }
        return vectors[0]
    }
}

/// How a book's index was built.
///
/// This is what the user's download choice selects, and it is **encoded into the index
/// identifier**. Without that, downloading a model would leave the keyword-only index in place
/// and vector queries would run against an index that has no vectors in it.
enum AIRetrievalTier: String, Codable, Sendable, Equatable {
    /// No model downloaded: keyword retrieval only. Not a degraded mode so much as the
    /// cheaper one — exact hits on names and terms are most of what readers ask about, which
    /// is why keyword weight sits above vector weight even when both are available.
    case keyword
    /// Model downloaded and verified: vectors fused with keywords.
    case hybrid
}

/// One book's searchable index.
struct AIBookRetrievalIndex: Sendable {
    /// Keyword weight above vector weight, on purpose: Chinese readers ask about names,
    /// places and terms, where an exact match beats a nearest neighbour.
    static let keywordWeight = 1.2
    static let vectorWeight = 1.0

    let bookID: UUID
    let tier: AIRetrievalTier
    /// Everything needed to decide whether a stored index is still the right one. A change to
    /// any component forces a rebuild rather than a silent mismatch.
    let identifier: String
    let contentFingerprint: String
    let manifest: AISourceManifest?
    let chunkerConfiguration: String
    let chunks: [AIContentChunk]
    let sectionTitleByID: [String: String]
    /// Which embedding model produced `vectors`, or `nil` in the keyword tier. Persisted so a
    /// stored index can be checked against the model the app would use today.
    let embeddingIdentifier: String?
    private let keyword: AIBM25Index
    private let vectors: [String: [Float]]

    /// The vectors, for persistence. Empty in the keyword tier.
    var storedVectors: [String: [Float]] { vectors }

    init(
        bookID: UUID,
        chunks: [AIContentChunk],
        sectionTitleByID: [String: String] = [:],
        tier: AIRetrievalTier = .keyword,
        embeddingIdentifier: String? = nil,
        vectors: [String: [Float]] = [:],
        contentFingerprint: String = "",
        manifest: AISourceManifest? = nil,
        chunkerConfiguration: String = "800/120/200"
    ) {
        self.contentFingerprint = contentFingerprint
        self.manifest = manifest
        self.chunkerConfiguration = chunkerConfiguration
        self.bookID = bookID
        self.chunks = chunks
        self.sectionTitleByID = sectionTitleByID
        self.tier = tier
        self.embeddingIdentifier = embeddingIdentifier
        self.identifier = Self.identifier(
            tier: tier,
            embeddingIdentifier: embeddingIdentifier,
            contentFingerprint: contentFingerprint,
            chunkerConfiguration: chunkerConfiguration
        )
        self.keyword = AIBM25Index(chunks: chunks)
        self.vectors = vectors
    }

    /// `tier@embedding@chunker@content` — a stored index whose identifier differs from what
    /// the app would build today is rebuilt, not queried.
    ///
    /// `contentFingerprint` is the load-bearing one for a book being read: the text available
    /// to index grows as chapters are gathered, and without it the first index — built from
    /// whatever happened to be laid out — would be reused forever.
    static func identifier(
        tier: AIRetrievalTier,
        embeddingIdentifier: String?,
        contentFingerprint: String = "",
        chunkerConfiguration: String = "800/120/200"
    ) -> String {
        "\(tier.rawValue)@\(embeddingIdentifier ?? "none")@\(AIPublicationChunker.version)@\(chunkerConfiguration)@\(contentFingerprint)"
    }

    /// Retrieval, with the spoiler boundary applied **before** the results are trimmed to
    /// `limit`.
    ///
    /// Order matters: filtering after the cut would let unread passages take up slots and
    /// hand back fewer usable ones than asked for — sometimes none, making a well-evidenced
    /// question look unanswerable.
    func retrieve(
        query: String,
        maximumProgress: Double,
        limit: Int = 8,
        restrictToSectionIDs: Set<String>? = nil,
        embedding: (any AIEmbeddingProviding)? = nil,
        boundary: AIReadingBoundary? = nil
    ) async throws -> [AIRetrievalHit] {
        guard limit > 0 else { return [] }
        let started = Date()
        AIDiagnostics.current?.event("query", ["characters": "\(query.count)"])
        let eligible = chunks.filter { chunk in
            let within = boundary.map { $0.contains(chunk) } ?? (chunk.progressEnd <= maximumProgress)
            return within && (restrictToSectionIDs?.contains(chunk.sectionID) ?? true)
        }
        let eligibleIDs = Set(eligible.map(\.id))
        let candidateLimit = max(limit * 4, 32)
        var rankings = [keyword.search(query: query, limit: candidateLimit, eligibleIDs: eligibleIDs)]
        var weights = [Self.keywordWeight]
        var degradation: String?
        if tier == .hybrid {
            do {
                guard let embedding, embedding.identifier == embeddingIdentifier else {
                    throw AIEmbeddingContract.Failure.artifactMismatch
                }
                guard !vectors.isEmpty else { throw AIEmbeddingContract.Failure.missingVectors }
                // Validate the whole space, including unavailable candidates, before comparing.
                try AIEmbeddingContract.validate(chunks.compactMap { vectors[$0.id] }, count: chunks.count, dimensions: embedding.dimensions)
                let queryVector = try await embedding.embedQuery(query)
                if let document = vectors.values.first, queryVector.count != document.count {
                    throw AIEmbeddingContract.Failure.queryDocumentMismatch
                }
                try AIEmbeddingContract.validate([queryVector], count: 1, dimensions: embedding.dimensions)
                rankings.append(vectorHits(for: queryVector, eligible: eligible, limit: candidateLimit))
                weights.append(Self.vectorWeight)
            } catch is CancellationError { throw CancellationError() }
            catch {
                // A missing/incompatible external artifact cannot supply a shared vector space.
                // Keyword remains supported; remove this downgrade if hybrid becomes mandatory.
                degradation = (error as? AIEmbeddingContract.Failure)?.rawValue ?? "embeddingUnavailable"
            }
        }
        let merged = rankings.count == 1 ? rankings[0] : AIReciprocalRankFusion.merge(rankings: rankings, weights: weights)
        let result = Array(merged.prefix(limit))
        AIDiagnostics.current?.retrieval(total: chunks.count, eligible: eligible.count,
            candidates: rankings.map(\.count), hits: result, scoreType: rankings.count == 1 ? "BM25" : "RRF(BM25,cosine)",
            degradation: degradation, elapsed: Date().timeIntervalSince(started))
        return result
    }

    private func vectorHits(for query: [Float], eligible: [AIContentChunk], limit: Int) -> [AIRetrievalHit] {
        let queryNorm = Self.norm(query)
        var best: [AIRetrievalHit] = []
        for chunk in eligible {
            guard let vector = vectors[chunk.id] else { continue } // validated above
            let norm = Self.norm(vector)
            var dot: Double = 0
            for index in vector.indices { dot += Double(vector[index]) * Double(query[index]) }
            AIRetrievalRanking.consider(AIRetrievalHit(chunk: chunk, score: dot / (norm * queryNorm)), in: &best, limit: limit)
        }
        return best
    }

    private static func norm(_ vector: [Float]) -> Double {
        var total: Double = 0
        for value in vector { total += Double(value) * Double(value) }
        return total.squareRoot()
    }
}

/// Contract validity and query/document comparability are distinct checks.
enum AIEmbeddingContract {
    enum Failure: String, Error, LocalizedError {
        case artifactMismatch, missingVectors, countMismatch, declaredDimensionMismatch, queryDocumentMismatch, nonFiniteOrZero
        var errorDescription: String? {
            switch self {
            case .artifactMismatch: return localized("語意模型版本與索引不相容")
            case .missingVectors: return localized("索引缺少語意向量")
            case .countMismatch: return localized("語意模型回傳的向量數量錯誤")
            case .declaredDimensionMismatch: return localized("語意向量不符合模型宣告的維度")
            case .queryDocumentMismatch: return localized("查詢與正文向量維度不相容")
            case .nonFiniteOrZero: return localized("語意模型回傳無效向量")
            }
        }
    }
    static func validate(_ vectors: [[Float]], count: Int, dimensions: Int) throws {
        guard vectors.count == count else { throw Failure.countMismatch }
        for vector in vectors {
            guard dimensions > 0, vector.count == dimensions else { throw Failure.declaredDimensionMismatch }
            guard vector.allSatisfy(\.isFinite), vector.contains(where: { $0 != 0 }) else { throw Failure.nonFiniteOrZero }
        }
    }
}
