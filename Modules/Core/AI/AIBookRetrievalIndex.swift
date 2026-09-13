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
        try await embed([text])[0]
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
        contentFingerprint: String = ""
    ) {
        self.bookID = bookID
        self.chunks = chunks
        self.sectionTitleByID = sectionTitleByID
        self.tier = tier
        self.embeddingIdentifier = embeddingIdentifier
        self.identifier = Self.identifier(
            tier: tier,
            embeddingIdentifier: embeddingIdentifier,
            contentFingerprint: contentFingerprint
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
        contentFingerprint: String = ""
    ) -> String {
        "\(tier.rawValue)@\(embeddingIdentifier ?? "none")@\(AIPublicationChunker.version)@\(contentFingerprint)"
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
        embedding: (any AIEmbeddingProviding)? = nil
    ) async throws -> [AIRetrievalHit] {
        guard limit > 0 else { return [] }
        // Over-fetch, because the filter below removes candidates.
        let candidateLimit = max(limit * 4, 32)
        var rankings: [[AIRetrievalHit]] = [keyword.search(query: query, limit: candidateLimit)]
        var weights: [Double] = [Self.keywordWeight]

        if tier == .hybrid, let embedding, !vectors.isEmpty {
            let queryVector = try await embedding.embedQuery(query)
            rankings.append(vectorHits(for: queryVector, limit: candidateLimit))
            weights.append(Self.vectorWeight)
        }

        var merged = rankings.count == 1
            ? rankings[0]
            : AIReciprocalRankFusion.merge(rankings: rankings, weights: weights)
        if let restrictToSectionIDs {
            merged = merged.filter { restrictToSectionIDs.contains($0.chunk.sectionID) }
        }
        return Array(
            AISpoilerSafeFilter.apply(to: merged, maximumProgress: maximumProgress).prefix(limit)
        )
    }

    private func vectorHits(for query: [Float], limit: Int) -> [AIRetrievalHit] {
        let queryNorm = Self.norm(query)
        guard queryNorm > 0 else { return [] }
        var best: [AIRetrievalHit] = []
        for chunk in chunks {
            guard let vector = vectors[chunk.id], vector.count == query.count else { continue }
            let norm = Self.norm(vector)
            guard norm > 0 else { continue }
            var dot: Float = 0
            for index in 0..<vector.count { dot += vector[index] * query[index] }
            let score = Double(dot) / (Double(norm) * Double(queryNorm))
            AIRetrievalRanking.consider(
                AIRetrievalHit(chunk: chunk, score: score),
                in: &best,
                limit: limit
            )
        }
        return best
    }

    private static func norm(_ vector: [Float]) -> Float {
        var total: Float = 0
        for value in vector { total += value * value }
        return total.squareRoot()
    }
}
