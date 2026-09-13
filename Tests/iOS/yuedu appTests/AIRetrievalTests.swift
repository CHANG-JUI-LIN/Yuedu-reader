import Foundation
import Testing
@testable import yuedu_app

@Suite("AI chunking and retrieval")
struct AIRetrievalTests {

    // MARK: - Chunking

    @Test("chunks never span two chapters")
    func chunksStayInsideOneChapter() {
        let book = FakeBook(sections: [
            AIChunkableSection(id: "c0", title: "第一章", text: String(repeating: "甲", count: 300)),
            AIChunkableSection(id: "c1", title: "第二章", text: String(repeating: "乙", count: 300)),
        ])
        let chunks = AIPublicationChunker(maximumCharacters: 1_000).chunks(from: book)
        #expect(chunks.count == 2)
        #expect(chunks.allSatisfy { Set($0.text).count == 1 })
        #expect(chunks.map(\.sectionID) == ["c0", "c1"])
    }

    @Test("a long chapter is cut on sentence boundaries, not mid-sentence")
    func cutsOnSentenceBoundaries() {
        let sentence = String(repeating: "他走進門", count: 20) + "。"
        let book = FakeBook(sections: [
            AIChunkableSection(id: "c0", text: String(repeating: sentence, count: 6)),
        ])
        let chunks = AIPublicationChunker(maximumCharacters: 200, overlapCharacters: 20).chunks(from: book)
        #expect(chunks.count > 1)
        // Every chunk but possibly the last ends where a sentence ended.
        for chunk in chunks.dropLast() {
            #expect(chunk.text.hasSuffix("。"))
        }
    }

    @Test("chunk ids and ordinals are stable whether a book is cut whole or chapter by chapter")
    func perSectionChunkingMatchesWholeBook() {
        let book = FakeBook(sections: (0..<4).map {
            AIChunkableSection(id: "c\($0)", text: String(repeating: "章節內容。", count: 60))
        })
        let chunker = AIPublicationChunker(maximumCharacters: 120, overlapCharacters: 20)
        let whole = chunker.chunks(from: book)

        var streamed: [AIContentChunk] = []
        var ordinal = 0
        for index in book.chunkSections.indices {
            let (chunks, next) = chunker.chunks(inSectionAt: index, content: book, startingOrdinal: ordinal)
            streamed.append(contentsOf: chunks)
            ordinal = next
        }
        #expect(streamed.map(\.id) == whole.map(\.id))
        #expect(streamed.map(\.text) == whole.map(\.text))
    }

    /// A trailing sliver retrieves badly and cites badly.
    @Test("a short trailing chunk is folded into the one before it")
    func foldsShortTrailingChunk() {
        let body = String(repeating: "内容，", count: 70) + "尾。"
        let book = FakeBook(sections: [AIChunkableSection(id: "c0", text: body)])
        let folded = AIPublicationChunker(
            maximumCharacters: 100, overlapCharacters: 0, minimumCharacters: 40
        ).chunks(from: book)
        #expect(folded.allSatisfy { $0.text.count >= 40 })
    }

    /// A position the reader cannot navigate to is worse than no citation at all.
    @Test("a chunk whose position cannot be resolved is dropped, not cited")
    func dropsUnlocatableChunks() {
        let book = FakeBook(
            sections: [AIChunkableSection(id: "c0", text: "一些文字。")],
            resolvesLocations: false
        )
        #expect(AIPublicationChunker().chunks(from: book).isEmpty)
    }

    @Test("empty chapters contribute nothing")
    func skipsEmptySections() {
        let book = FakeBook(sections: [
            AIChunkableSection(id: "c0", text: ""),
            AIChunkableSection(id: "c1", text: "有內容。"),
        ])
        let chunks = AIPublicationChunker().chunks(from: book)
        #expect(chunks.map(\.sectionID) == ["c1"])
    }

    // MARK: - Spoiler boundary

    /// The boundary that matters: a chunk that *starts* before the reader's progress but
    /// *ends* after it still carries unread text, and must not reach the model.
    @Test("a chunk straddling the reading position is unsafe, not half-safe")
    func straddlingChunkIsFiltered() {
        let read = makeChunk(ordinal: 0, progressStart: 0.10, progressEnd: 0.40)
        let straddling = makeChunk(ordinal: 1, progressStart: 0.45, progressEnd: 0.60)
        let unread = makeChunk(ordinal: 2, progressStart: 0.80, progressEnd: 0.90)
        let hits = [read, straddling, unread].map { AIRetrievalHit(chunk: $0, score: 1) }

        let safe = AISpoilerSafeFilter.apply(to: hits, maximumProgress: 0.5)
        #expect(safe.map(\.chunk.ordinal) == [0])
        #expect(AISpoilerSafeFilter.chunks([read, straddling, unread], maximumProgress: 0.5).map(\.ordinal) == [0])
    }

    @Test("a chunk ending exactly at the reading position is safe")
    func boundaryIsInclusive() {
        let chunk = makeChunk(ordinal: 0, progressStart: 0.2, progressEnd: 0.5)
        #expect(AISpoilerSafeFilter.chunks([chunk], maximumProgress: 0.5).count == 1)
        #expect(AISpoilerSafeFilter.chunks([chunk], maximumProgress: 0.499).isEmpty)
    }

    @Test("progress outside 0…1 clamps rather than opening the whole book")
    func clampsProgress() {
        let ending = makeChunk(ordinal: 0, progressStart: 0.99, progressEnd: 1.0)
        #expect(AISpoilerSafeFilter.chunks([ending], maximumProgress: -5).isEmpty)
        #expect(AISpoilerSafeFilter.chunks([ending], maximumProgress: 99).count == 1)
    }

    // MARK: - BM25

    @Test("an exact name match outranks a chapter that never mentions it")
    func bm25FindsNames() {
        let chunks = [
            makeChunk(ordinal: 0, text: "池瑤走出房門，天色已暗。"),
            makeChunk(ordinal: 1, text: "張若塵盤膝而坐，運轉神石。"),
            makeChunk(ordinal: 2, text: "山下的村莊燃起炊煙。"),
        ]
        let hits = AIBM25Index(chunks: chunks).search(query: "張若塵", limit: 3)
        #expect(hits.first?.chunk.ordinal == 1)
        #expect(!hits.contains { $0.chunk.ordinal == 2 })
    }

    @Test("a query with nothing in common returns nothing rather than a weak guess")
    func bm25ReturnsEmptyForNoMatch() {
        let chunks = [makeChunk(ordinal: 0, text: "池瑤走出房門。")]
        #expect(AIBM25Index(chunks: chunks).search(query: "量子色動力學", limit: 5).isEmpty)
        #expect(AIBM25Index(chunks: chunks).search(query: "", limit: 5).isEmpty)
        #expect(AIBM25Index(chunks: chunks).search(query: "池瑤", limit: 0).isEmpty)
        #expect(AIBM25Index(chunks: []).search(query: "池瑤", limit: 5).isEmpty)
    }

    @Test("ranking is bounded and ties break on reading order")
    func rankingIsStableAndBounded() {
        let hits = (0..<10).map { AIRetrievalHit(chunk: makeChunk(ordinal: 9 - $0), score: 1) }
        let top = AIRetrievalRanking.topK(hits, limit: 3)
        #expect(top.count == 3)
        #expect(top.map(\.chunk.ordinal) == [0, 1, 2])
    }

    // MARK: - Fusion

    @Test("fusion merges two rankings that are not on the same scale")
    func fusionMergesRankings() {
        let keyword = [
            AIRetrievalHit(chunk: makeChunk(ordinal: 1), score: 18.2),
            AIRetrievalHit(chunk: makeChunk(ordinal: 2), score: 4.1),
        ]
        let vector = [
            AIRetrievalHit(chunk: makeChunk(ordinal: 2), score: 0.81),
            AIRetrievalHit(chunk: makeChunk(ordinal: 3), score: 0.79),
        ]
        let merged = AIReciprocalRankFusion.merge(rankings: [keyword, vector], weights: [1.2, 1.0])
        #expect(Set(merged.map(\.chunk.ordinal)) == [1, 2, 3])
        // Ranked first by one list and second by the other beats appearing in only one.
        #expect(merged.first?.chunk.ordinal == 2 || merged.first?.chunk.ordinal == 1)
        #expect(merged.last?.chunk.ordinal == 3)
    }

    @Test("fusing one ranking with nothing leaves it intact")
    func fusionHandlesEmptyRankings() {
        let only = [AIRetrievalHit(chunk: makeChunk(ordinal: 5), score: 1)]
        #expect(AIReciprocalRankFusion.merge(rankings: [only, []]).map(\.chunk.ordinal) == [5])
        #expect(AIReciprocalRankFusion.merge(rankings: []).isEmpty)
    }

    // MARK: - Fixtures

    private struct FakeBook: AIChunkableContent {
        let chunkBookID = UUID()
        let chunkSections: [AIChunkableSection]
        var resolvesLocations = true

        init(sections: [AIChunkableSection], resolvesLocations: Bool = true) {
            self.chunkSections = sections
            self.resolvesLocations = resolvesLocations
        }

        func chunkLocation(sectionIndex: Int, characterOffset: Int) -> AIChunkLocation? {
            guard resolvesLocations else { return nil }
            let sectionCount = max(chunkSections.count, 1)
            let within = Double(characterOffset) / Double(max(chunkSections[sectionIndex].text.count, 1))
            let progress = (Double(sectionIndex) + min(within, 1)) / Double(sectionCount)
            return AIChunkLocation(spineIndex: sectionIndex, charOffset: characterOffset, progress: progress)
        }
    }

    private func makeChunk(
        ordinal: Int,
        text: String = "內容",
        progressStart: Double = 0,
        progressEnd: Double = 0
    ) -> AIContentChunk {
        let bookID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
        return AIContentChunk(
            id: "\(bookID.uuidString):c0:\(ordinal)",
            bookID: bookID,
            sectionID: "c0",
            ordinal: ordinal,
            text: text,
            start: AIChunkLocation(spineIndex: 0, charOffset: ordinal * 10, progress: progressStart),
            end: AIChunkLocation(spineIndex: 0, charOffset: ordinal * 10 + 5, progress: progressEnd)
        )
    }
}
