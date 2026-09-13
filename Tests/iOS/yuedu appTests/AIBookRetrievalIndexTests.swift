import Foundation
import Testing
@testable import yuedu_app

@Suite("AI book index")
struct AIBookRetrievalIndexTests {

    private let bookID = UUID(uuidString: "00000000-0000-0000-0000-0000000000CC")!

    /// The failure this guards: a user downloads the embedding model, and the app keeps the
    /// keyword-only index it already had — then runs vector queries against an index with no
    /// vectors in it. Encoding the tier in the identifier makes the mismatch visible.
    @Test("downloading a model changes the index identity, forcing a rebuild")
    func tierIsPartOfIndexIdentity() {
        let keyword = AIBookRetrievalIndex.identifier(tier: .keyword, embeddingIdentifier: nil)
        let hybrid = AIBookRetrievalIndex.identifier(tier: .hybrid, embeddingIdentifier: "distiluse-v2")
        #expect(keyword != hybrid)
        // A different embedding model is also a different index.
        #expect(hybrid != AIBookRetrievalIndex.identifier(tier: .hybrid, embeddingIdentifier: "other"))
        // So is a change to how chunks are cut.
        #expect(keyword.contains(AIPublicationChunker.version))
    }

    /// The failure this guards, seen on a real book: the panel opened while five chapters
    /// were laid out, indexed those, and cached the result. Every later question — and 前情提要
    /// at 51% — was answered out of five chapters of a whole novel, because the identity did
    /// not mention how much text went in.
    @Test("gathering more of the book changes the index identity")
    func contentFingerprintIsPartOfIndexIdentity() {
        let partial = AIBookRetrievalIndex.identifier(
            tier: .keyword,
            embeddingIdentifier: nil,
            contentFingerprint: "300/5/12000"
        )
        let whole = AIBookRetrievalIndex.identifier(
            tier: .keyword,
            embeddingIdentifier: nil,
            contentFingerprint: "300/300/4200000"
        )
        #expect(partial != whole)
    }

    @Test("the adapter's fingerprint moves when chapters gain text")
    func adapterFingerprintTracksAvailableText() {
        let bookID = UUID()
        let chapters = (0..<3).map { BookChapter(index: $0, title: "第\($0)章", content: "") }
        let laidOutOnly = AIBookContentAdapter(bookID: bookID, chapters: chapters) { index in
            index == 0 ? "第一章的內容" : nil
        }
        let gathered = AIBookContentAdapter(bookID: bookID, chapters: chapters) { index in
            "第\(index)章的內容，長度不一樣"
        }
        #expect(laidOutOnly.contentFingerprint != gathered.contentFingerprint)
    }

    @Test("without a model the index still answers, on keywords alone")
    func keywordTierWorksWithoutAModel() async throws {
        let index = makeIndex(tier: .keyword)
        let hits = try await index.retrieve(query: "張若塵", maximumProgress: 1.0, limit: 5)
        #expect(!hits.isEmpty)
        #expect(hits.first?.chunk.text.contains("張若塵") == true)
    }

    /// Filtering after the cut would let unread passages occupy the slots and hand back
    /// fewer — sometimes none — making an answerable question look unanswerable.
    @Test("the spoiler boundary is applied before results are trimmed to the limit")
    func filtersBeforeTrimming() async throws {
        // Ten chunks all matching the query; only the earliest two are within progress.
        let chunks = (0..<10).map { ordinal in
            makeChunk(
                ordinal: ordinal,
                text: "張若塵在第\(ordinal)段出現。",
                progressStart: Double(ordinal) / 10,
                progressEnd: Double(ordinal + 1) / 10
            )
        }
        let index = AIBookRetrievalIndex(bookID: bookID, chunks: chunks)
        let hits = try await index.retrieve(query: "張若塵", maximumProgress: 0.2, limit: 5)
        #expect(!hits.isEmpty)
        #expect(hits.allSatisfy { $0.chunk.progressEnd <= 0.2 + 0.000_001 })
        #expect(hits.count <= 2)
    }

    @Test("a section restriction narrows retrieval to those chapters")
    func restrictsToSections() async throws {
        let chunks = [
            makeChunk(ordinal: 0, sectionID: "c0", text: "張若塵在第一章。"),
            makeChunk(ordinal: 1, sectionID: "c1", text: "張若塵在第二章。"),
        ]
        let index = AIBookRetrievalIndex(bookID: bookID, chunks: chunks)
        let hits = try await index.retrieve(
            query: "張若塵",
            maximumProgress: 1.0,
            limit: 5,
            restrictToSectionIDs: ["c1"]
        )
        #expect(hits.map(\.chunk.sectionID) == ["c1"])
    }

    @Test("a keyword-tier index ignores an embedding provider rather than half-using it")
    func keywordTierIgnoresEmbedding() async throws {
        let index = makeIndex(tier: .keyword)
        let embedding = CountingEmbedding()
        _ = try await index.retrieve(
            query: "張若塵",
            maximumProgress: 1.0,
            embedding: embedding
        )
        #expect(embedding.queryCount == 0)
    }

    @Test("a hybrid index fuses vectors with keywords")
    func hybridTierUsesVectors() async throws {
        let chunks = [
            makeChunk(ordinal: 0, text: "池瑤走出房門。"),
            makeChunk(ordinal: 1, text: "張若塵盤膝而坐。"),
        ]
        let index = AIBookRetrievalIndex(
            bookID: bookID,
            chunks: chunks,
            tier: .hybrid,
            embeddingIdentifier: "fake",
            vectors: [chunks[0].id: [1, 0], chunks[1].id: [0, 1]]
        )
        let embedding = CountingEmbedding(vector: [0, 1])
        let hits = try await index.retrieve(
            query: "張若塵",
            maximumProgress: 1.0,
            embedding: embedding
        )
        #expect(embedding.queryCount == 1)
        #expect(hits.first?.chunk.ordinal == 1)
    }

    /// A hybrid index whose vectors never got written must not silently claim to be hybrid;
    /// it still has to answer, on keywords.
    @Test("a hybrid index with no vectors still answers on keywords")
    func hybridWithoutVectorsFallsBackToKeywords() async throws {
        let index = AIBookRetrievalIndex(
            bookID: bookID,
            chunks: [makeChunk(ordinal: 0, text: "張若塵盤膝而坐。")],
            tier: .hybrid,
            embeddingIdentifier: "fake",
            vectors: [:]
        )
        let embedding = CountingEmbedding()
        let hits = try await index.retrieve(query: "張若塵", maximumProgress: 1.0, embedding: embedding)
        #expect(!hits.isEmpty)
        #expect(embedding.queryCount == 0)
    }

    // MARK: - Fixtures

    private func makeIndex(tier: AIRetrievalTier) -> AIBookRetrievalIndex {
        AIBookRetrievalIndex(
            bookID: bookID,
            chunks: [
                makeChunk(ordinal: 0, text: "池瑤走出房門，天色已暗。"),
                makeChunk(ordinal: 1, text: "張若塵盤膝而坐，運轉神石。"),
            ],
            tier: tier,
            embeddingIdentifier: tier == .hybrid ? "fake" : nil
        )
    }

    private func makeChunk(
        ordinal: Int,
        sectionID: String = "c0",
        text: String = "內容",
        progressStart: Double = 0,
        progressEnd: Double = 0.1
    ) -> AIContentChunk {
        AIContentChunk(
            id: "\(bookID.uuidString):\(sectionID):\(ordinal)",
            bookID: bookID,
            sectionID: sectionID,
            ordinal: ordinal,
            text: text,
            start: AIChunkLocation(spineIndex: 0, charOffset: ordinal * 10, progress: progressStart),
            end: AIChunkLocation(spineIndex: 0, charOffset: ordinal * 10 + 5, progress: progressEnd)
        )
    }

    private final class CountingEmbedding: AIEmbeddingProviding, @unchecked Sendable {
        let identifier = "fake"
        let dimensions = 2
        private let vector: [Float]
        private(set) var queryCount = 0

        init(vector: [Float] = [1, 0]) { self.vector = vector }

        func embed(_ texts: [String]) async throws -> [[Float]] {
            texts.map { _ in vector }
        }

        func embedQuery(_ text: String) async throws -> [Float] {
            queryCount += 1
            return vector
        }
    }
}
