import Foundation
import Testing
@testable import yuedu_app

@Suite("AI assistant features")
struct AIAssistantFeatureTests {

    // MARK: - Citations

    @Test("a citation resolves to a position the reader can jump to")
    func citationsCarryAReadingPosition() {
        let chunks = [makeChunk(ordinal: 0, spineIndex: 3, charOffset: 144)]
        let citations = AICitationParser.parse(
            in: "他在那時離開了 [\(chunks[0].id)]。",
            from: chunks,
            sectionTitleByID: ["c0": "第四章"]
        )
        #expect(citations.count == 1)
        #expect(citations[0].spineIndex == 3)
        #expect(citations[0].charOffset == 144)
        #expect(citations[0].sectionTitle == "第四章")
    }

    /// A marker naming a chunk that was never in the prompt is a hallucination; turning it
    /// into a tappable citation would send the reader to a position nothing supports.
    @Test("a marker for an unknown chunk is dropped, not invented")
    func dropsUnknownCitations() {
        let chunks = [makeChunk(ordinal: 0)]
        let citations = AICitationParser.parse(in: "據說如此 [made-up-id]。", from: chunks)
        #expect(citations.isEmpty)
    }

    @Test("the same chunk cited repeatedly yields one citation, in first-mention order")
    func collapsesRepeatedCitations() {
        let chunks = [makeChunk(ordinal: 0), makeChunk(ordinal: 1)]
        let text = "甲 [\(chunks[1].id)]，乙 [\(chunks[0].id)]，丙 [\(chunks[1].id)]。"
        let citations = AICitationParser.parse(in: text, from: chunks)
        #expect(citations.map(\.chunkID) == [chunks[1].id, chunks[0].id])
    }

    // MARK: - Answering

    @Test("no retrieved evidence answers without spending a request")
    func refusesWithoutEvidence() async throws {
        let provider = CountingProvider(reply: "should never be asked")
        let result = try await AIRAGPipeline.answer(query: "結局是什麼？", hits: [], provider: provider)
        #expect(!result.hasEvidence)
        #expect(result.citations.isEmpty)
        #expect(provider.callCount == 0)
    }

    @Test("an answer citing nothing is reported as unsourced")
    func answerWithoutCitationsHasNoEvidence() async throws {
        let chunk = makeChunk(ordinal: 0)
        let provider = CountingProvider(reply: "我覺得應該是這樣。")
        let result = try await AIRAGPipeline.answer(
            query: "他去哪了？",
            hits: [AIRetrievalHit(chunk: chunk, score: 1)],
            provider: provider
        )
        #expect(provider.callCount == 1)
        #expect(!result.hasEvidence)
    }

    /// The envelope is an internal control channel; a user must never see a sentinel.
    @Test("the self-assessment envelope is stripped from a non-streamed answer")
    func stripsEnvelopeFromAnswer() async throws {
        let chunk = makeChunk(ordinal: 0)
        let provider = EnvelopeEchoProvider(chunkID: chunk.id)
        let result = try await AIRAGPipeline.answer(
            query: "他去哪了？",
            hits: [AIRetrievalHit(chunk: chunk, score: 1)],
            provider: provider
        )
        #expect(!result.content.contains("SELFASS"))
        #expect(result.hasEvidence)
        #expect(result.citations.count == 1)
        #expect(result.promptVersion == AIRAGPipeline.promptVersion)
    }

    /// Novel text is untrusted data and must not receive system authority.
    @Test("passages and the question go in the data message")
    func promptKeepsBookTextOutOfTheUserTurn() {
        let chunk = makeChunk(ordinal: 0, text: "池瑤走出房門。")
        let request = AIRAGPipeline.request(query: "她去哪了？", chunks: [chunk], nonce: "ABC123")
        #expect(request.messages.map(\.role) == [.system, .user])
        #expect(!request.messages[0].content.contains("池瑤走出房門。"))
        #expect(request.messages[1].content.contains(chunk.id))
        #expect(request.messages[1].content.contains("她去哪了？"))
        #expect(request.messages[1].content.contains("池瑤走出房門。"))
    }

    // MARK: - Recap reuse

    @Test("a recap is reused until the reader has actually moved on")
    func recapReusePolicy() {
        let now = Date()
        var stored = AIRecap(
            text: "前情提要內容。",
            progress: 0.40,
            generatedAt: now,
            provider: "p",
            model: "m",
            promptVersion: AIRecap.currentPromptVersion
        )
        let boundary = AIReadingBoundary(sourceVersion: "fixture", sectionID: "0", spineIndex: 0, utf16Offset: 100)
        stored.sourceBoundary = boundary
        stored.evidenceChunkIDs = ["fixture-chunk"]
        #expect(AIRecap.canReuse(stored, atProgress: 0.42, now: now, boundary: boundary))
        #expect(!AIRecap.canReuse(stored, atProgress: 0.50, now: now))
        #expect(!AIRecap.canReuse(stored, atProgress: 0.42, now: now.addingTimeInterval(25 * 3600)))
        #expect(!AIRecap.canReuse(nil, atProgress: 0.42, now: now))
    }

    @Test("a recap from an older prompt version is never reused")
    func recapVersionGate() {
        let stored = AIRecap(
            text: "舊版提要。",
            progress: 0.40,
            generatedAt: Date(),
            provider: "p",
            model: "m",
            promptVersion: "yuedu.recap.v0"
        )
        #expect(!AIRecap.canReuse(stored, atProgress: 0.40))
    }

    @Test("an empty stored recap is not reusable")
    func recapEmptyGate() {
        let stored = AIRecap(
            text: "   ",
            progress: 0.4,
            generatedAt: Date(),
            provider: "p",
            model: "m",
            promptVersion: AIRecap.currentPromptVersion
        )
        #expect(!AIRecap.canReuse(stored, atProgress: 0.4))
    }

    // MARK: - Character cards → voices

    @Test("a character card parses, fenced or not")
    func parsesCharacterCard() throws {
        let json = """
        ```json
        {"firstAppearance":"第一章","role":"主角","relationships":["池瑤：同門"],
         "aliasCandidates":["若塵","塵哥","張若塵"],"summary":"神石傳人。"}
        ```
        """
        let profile = try AICharacterProfile.parse(
            fromAnswer: json,
            name: "張若塵",
            gatheredChunkIDs: ["a", "b"],
            provider: "p",
            model: "m",
            citedChunkIDs: ["a", "b"]
        )
        #expect(profile.role == "主角")
        #expect(profile.firstAppearance == "第一章")
        // The character's own name is not an alias of itself.
        #expect(profile.aliasCandidates == ["若塵", "塵哥"])
        #expect(profile.citationChunkIDs == ["a", "b"])
        #expect(profile.promptVersion == AICharacterProfile.currentPromptVersion)
    }

    @Test("an unparseable card fails explicitly instead of inventing a successful summary")
    func characterCardFallbackInventsNothing() {
        #expect(throws: LLMError.invalidSchema) {
            try AICharacterProfile.parse(fromAnswer: "他是主角，來自青雲門。", name: "張若塵",
                gatheredChunkIDs: [], provider: "p", model: "m")
        }
    }

    /// The whole reason the AI work touches the TTS work: without this table the dialogue
    /// heuristic gives 張若塵, 若塵 and 塵哥 three different voices.
    @Test("aliases fold onto one character so one voice reads them all")
    func aliasTableFoldsNames() {
        let profiles = [
            makeProfile(name: "張若塵", aliases: ["若塵", "塵哥"]),
            makeProfile(name: "池瑤", aliases: ["瑤兒"]),
        ]
        let map = AICharacterAliasTable.aliasMap(for: profiles)
        #expect(map["若塵"] == "張若塵")
        #expect(map["塵哥"] == "張若塵")
        #expect(map["張若塵"] == "張若塵")
        #expect(map["瑤兒"] == "池瑤")
    }

    /// Merging two characters onto one voice is worse than leaving an ambiguous name to the
    /// narrator, so a contested alias belongs to nobody.
    @Test("an alias two characters both claim is given to neither")
    func contestedAliasIsDropped() {
        let profiles = [
            makeProfile(name: "張若塵", aliases: ["公子"]),
            makeProfile(name: "李道人", aliases: ["公子"]),
        ]
        let map = AICharacterAliasTable.aliasMap(for: profiles)
        #expect(map["公子"] == nil)
        #expect(map["張若塵"] == "張若塵")
        #expect(map["李道人"] == "李道人")
    }

    @Test("blank and duplicate aliases are cleaned up before they become voices")
    func normalisesAliases() {
        let cleaned = AICharacterProfile.normalizedAliases(
            ["  若塵 ", "若塵", "", "   ", "張若塵", "塵哥"],
            excluding: "張若塵"
        )
        #expect(cleaned == ["若塵", "塵哥"])
    }

    // MARK: - Fixtures

    private func makeProfile(name: String, aliases: [String]) -> AICharacterProfile {
        AICharacterProfile(
            name: name,
            firstAppearance: nil,
            role: nil,
            relationships: [],
            aliasCandidates: aliases,
            summary: "",
            citationChunkIDs: [],
            provider: "p",
            model: "m",
            promptVersion: AICharacterProfile.currentPromptVersion
        )
    }

    private func makeChunk(
        ordinal: Int,
        text: String = "內容",
        spineIndex: Int = 0,
        charOffset: Int = 0
    ) -> AIContentChunk {
        let bookID = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!
        return AIContentChunk(
            id: "\(bookID.uuidString):c0:\(ordinal)",
            bookID: bookID,
            sectionID: "c0",
            ordinal: ordinal,
            text: text,
            start: AIChunkLocation(spineIndex: spineIndex, charOffset: charOffset, progress: 0.1),
            end: AIChunkLocation(spineIndex: spineIndex, charOffset: charOffset + 10, progress: 0.2)
        )
    }

    private final class CountingProvider: LLMProviding, @unchecked Sendable {
        let identifier = "counting"
        let defaultModel = "counting-model"
        private let reply: String
        private(set) var callCount = 0

        init(reply: String) { self.reply = reply }

        func generate(_ request: LLMGenerationRequest, model: String?) async throws -> LLMRawResponse {
            callCount += 1
            return LLMRawResponse(content: reply, provider: identifier, model: defaultModel)
        }
    }

    private struct EnvelopeEchoProvider: LLMProviding {
        let identifier = "envelope"
        let defaultModel = "envelope-model"
        let chunkID: String

        func generate(_ request: LLMGenerationRequest, model: String?) async throws -> LLMRawResponse {
            // Echo back the nonce the pipeline put in the system prompt.
            let system = request.messages.first(where: { $0.role == .system })?.content ?? ""
            let nonce = system
                .components(separatedBy: "[[SELFASSESS:").dropFirst().first?
                .components(separatedBy: "]]").first ?? "X"
            return LLMRawResponse(
                content: "他離開了 [\(chunkID)]。[[SELFASSESS:\(nonce)]]{\"sufficient\":\"full\"}[[/SELFASSESS:\(nonce)]]",
                provider: identifier,
                model: defaultModel
            )
        }
    }

    // MARK: - What the reader actually sees

    /// Seen on screen: `主角是陳慶。[75FFD7E5-5139-41EF-BE0B-BE5E858E66E0:0:0]`. The marker is
    /// a protocol between the prompt and the parser, not prose.
    @Test("chunk id markers never reach the answer text")
    func stripsCitationMarkers() {
        let chunk = makeChunk(ordinal: 0)
        let text = "主角是陳慶。[\(chunk.id)]"
        let stripped = AICitationParser.strippingMarkers(in: text, from: [chunk])
        #expect(stripped == "主角是陳慶。")
        #expect(!stripped.contains(chunk.id))
    }

    @Test("stripping leaves ordinary brackets alone")
    func keepsUnrelatedBrackets() {
        let chunk = makeChunk(ordinal: 0)
        let text = "他說「好」[註]，然後走了。[\(chunk.id)]"
        let stripped = AICitationParser.strippingMarkers(in: text, from: [chunk])
        #expect(stripped.contains("[註]"))
        #expect(!stripped.contains(chunk.id))
    }

    @Test("several markers in one answer all go")
    func stripsEveryMarker() {
        let chunks = [makeChunk(ordinal: 0), makeChunk(ordinal: 1)]
        let text = "一 [\(chunks[0].id)] 二 [\(chunks[1].id)][\(chunks[0].id)] 三"
        let stripped = AICitationParser.strippingMarkers(in: text, from: chunks)
        #expect(!stripped.contains("00000000"))
        #expect(stripped.contains("一"))
        #expect(stripped.contains("三"))
    }

    /// The refusal used to blame the spoiler limit even when the reader had switched it off.
    ///
    /// Compared against the localised strings rather than a literal, because the tests run
    /// under whatever locale the simulator is in — asserting the Chinese wording passed on a
    /// Chinese device and failed on an English one.
    @Test("the refusal only mentions the spoiler limit when one applies")
    func refusalMatchesTheActualLimit() {
        let provider = CountingProvider(reply: "")
        let limited = AIRAGPipeline.noEvidenceResult(provider: provider, spoilerLimited: true)
        let unlimited = AIRAGPipeline.noEvidenceResult(provider: provider, spoilerLimited: false)
        #expect(limited.content == localized("目前可用、已讀範圍內的檢索結果不足以確認。"))
        #expect(unlimited.content == localized("目前可用正文的檢索結果不足以確認。"))
        #expect(limited.content != unlimited.content)
        #expect(!limited.hasEvidence)
        #expect(!unlimited.hasEvidence)
    }
}
