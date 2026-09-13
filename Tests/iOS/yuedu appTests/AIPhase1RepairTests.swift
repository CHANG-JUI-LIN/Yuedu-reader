import Foundation
import Testing
@testable import yuedu_app

@Suite("AI Phase 1 repair", .serialized)
struct AIPhase1RepairTests {
    let bookID = UUID()
    enum FixtureError: Error { case unexpectedBuild }

    func adapter(_ texts: [String?]) -> AIBookContentAdapter {
        AIBookContentAdapter(bookID: bookID, chapters: texts.indices.map {
            BookChapter(index: $0, title: "Chapter \($0)", content: "")
        }) { texts[$0] }
    }

    @Test func coldStoreReusesFingerprint() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = adapter(["local fixture"])
        let index = AIBookRetrievalIndex(bookID: bookID, chunks: AIPublicationChunker().chunks(from: source), contentFingerprint: source.contentFingerprint)
        _ = try await AIBookIndexStore(directory: dir).index(for: bookID, expectedIdentifier: index.identifier) { index }
        let reloaded = try await AIBookIndexStore(directory: dir).index(for: bookID, expectedIdentifier: index.identifier) {
            throw FixtureError.unexpectedBuild
        }
        #expect(reloaded.identifier == index.identifier)
    }

    @Test func equalLengthChangesInvalidate() {
        #expect(adapter(["alpha"]).contentFingerprint != adapter(["bravo"]).contentFingerprint)
        #expect(adapter(["alpha", nil]).contentFingerprint != adapter([nil, "alpha"]).contentFingerprint)
    }

    @Test func thirtyThreeCandidates() async throws {
        var chunks = (0..<33).map { i in
            AIContentChunk(id: "c\(i)", bookID: bookID, sectionID: "0", ordinal: i,
                text: i == 32 ? "answer " + String(repeating: "filler ", count: 80) : "answer answer answer",
                start: .init(spineIndex: 0, charOffset: i, progress: i == 32 ? 0 : 0.8),
                end: .init(spineIndex: 0, charOffset: i + 1, progress: i == 32 ? 0.1 : 0.9))
        }
        let index = AIBookRetrievalIndex(bookID: bookID, chunks: chunks)
        #expect(try await index.retrieve(query: "answer", maximumProgress: 0.2).map(\.id) == ["c32"])
        chunks.removeFirst(32)
        #expect(try await AIBookRetrievalIndex(bookID: bookID, chunks: chunks).retrieve(query: "answer", maximumProgress: 0.2).map(\.id) == ["c32"])
    }

    @Test func unicodeCoordinatesRoundTrip() {
        let text = "𠮷👩🏽‍🚀e\u{301}葛\u{E0100}尾"
        let chunks = AIPublicationChunker(maximumCharacters: 2, overlapCharacters: 0).chunks(from: adapter([text]))
        for chunk in chunks {
            let range = NSRange(location: chunk.start.charOffset, length: chunk.end.charOffset - chunk.start.charOffset)
            #expect(Range(range, in: text).map { String(text[$0]) } == chunk.text)
        }
    }

    @Test func bookTextHasNoSystemAuthority() {
        let chunks = AIPublicationChunker().chunks(from: adapter(["SECRET_FIXTURE_NOVEL"]))
        let request = AIRAGPipeline.request(query: "question", chunks: chunks, nonce: "test")
        #expect(!request.messages.filter { $0.role == .system }.contains { $0.content.contains("SECRET_FIXTURE_NOVEL") })
        #expect(request.messages.filter { $0.role == .user }.contains { $0.content.contains("SECRET_FIXTURE_NOVEL") })
        #expect(!AIRecap.systemPrompt(for: chunks).contains("SECRET_FIXTURE_NOVEL"))
    }

    @Test func backwardRecapIsUnsafe() {
        let recap = AIRecap(text: "future evidence", progress: 0.8, generatedAt: Date(), provider: "fixture", model: "fixture", promptVersion: AIRecap.currentPromptVersion)
        #expect(!AIRecap.canReuse(recap, atProgress: 0.79))
    }
}
