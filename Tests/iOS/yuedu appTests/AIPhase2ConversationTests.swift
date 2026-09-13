import Foundation
import Testing
@testable import yuedu_app

@Suite("AI Phase 2 conversation and retrieval (testFixture)", .serialized)
struct AIPhase2ConversationTests {
    let book = UUID()
    let conversation = UUID()
    func source(_ texts: [String], offset: Int? = nil, spine: Int? = nil) -> AIBookContentAdapter {
        let i = spine ?? texts.count - 1
        return AIBookContentAdapter(bookID: book, chapters: texts.indices.map { .init(index: $0, title: "Fixture \($0)", content: "") }) { texts[$0] }
            .atReadingPosition(spine: i, renderedOffset: offset ?? texts[i].utf16.count, renderedText: texts[i])
    }
    func context(_ source: AIBookContentAdapter, _ question: String, history: [AIChatMessage] = [], budget: AIQuestionBudget = .init()) -> AIQuestionContext {
        .init(bookID: book, conversationID: conversation, question: question, source: source, boundary: source.boundary(), history: history, budget: budget)
    }
    func index(_ source: AIBookContentAdapter) -> AIBookRetrievalIndex {
        .init(bookID: book, chunks: AIPublicationChunker().chunks(from: source), contentFingerprint: source.contentFingerprint,
              manifest: source.manifest)
    }
    func historical(_ source: AIBookContentAdapter, _ text: String, role: AIChatMessage.Role = .user,
                    boundary: AIReadingBoundary? = nil) -> AIChatMessage {
        var message = AIChatMessage(role: role, text: text)
        message.provenance = .init(requestID: UUID(), bookID: book, conversationID: conversation,
            boundary: boundary ?? source.boundary(), status: .completed)
        return message
    }
    actor Provider: LLMProviding {
        enum Reply: Sendable {
            case answer(String = "full"), plan(String, [String], [String]), raw(String, String?), failure(LLMError)
        }
        let identifier = "phase2-mock"
        let defaultModel = "scripted-external-model"
        var replies: [Reply]
        var requests: [LLMGenerationRequest] = []
        init(_ replies: [Reply]) { self.replies = replies }
        func generate(_ request: LLMGenerationRequest, model: String?) async throws -> LLMRawResponse {
            requests.append(request)
            guard !replies.isEmpty else { throw LLMError.providerError("unexpected call") }
            switch replies.removeFirst() {
            case let .failure(error): throw error
            case let .raw(text, reason): return .init(content: text, provider: identifier, model: defaultModel, finishReason: reason)
            case let .plan(question, queries, unresolved):
                let data = try JSONSerialization.data(withJSONObject: ["rewrittenQuestion": question, "retrievalQueries": queries,
                    "unresolvedReferences": unresolved, "purpose": "fixture missing event"])
                return .init(content: String(decoding: data, as: UTF8.self), provider: identifier, model: defaultModel)
            case let .answer(state):
                let system = request.messages[0].content
                let start = system.range(of: "[[SELFASSESS:")!.upperBound
                let end = system.range(of: "]]", range: start..<system.endIndex)!.lowerBound
                let nonce = String(system[start..<end])
                let body = request.messages.last!.content
                let pattern = #"\[([^\]\n]+)\]\n"#
                let regex = try NSRegularExpression(pattern: pattern)
                let ids = regex.matches(in: body, range: NSRange(body.startIndex..., in: body)).compactMap { match -> String? in
                    guard let r = Range(match.range(at: 1), in: body) else { return nil }; return String(body[r])
                }
                return .init(content: "Fixture answer " + ids.map { "[\($0)]" }.joined() +
                    "[[SELFASSESS:\(nonce)]]{\"sufficient\":\"\(state)\",\"missing\":\"origin event\"}[[/SELFASSESS:\(nonce)]]",
                    provider: identifier, model: defaultModel, finishReason: "stop", usage: .init(promptTokens: 100, completionTokens: 20, totalTokens: 120), httpStatus: 200)
            }
        }
    }
    func run(_ context: AIQuestionContext, _ provider: Provider) async throws -> LLMGenerationResult {
        try await AIAgenticAssistant.answerQuestion(context: context, index: index(context.source), provider: provider)
    }

    @Test func clearQuestionUsesOneCallAndOnlyActualEvidence() async throws {
        let source = source(["柳青在橋邊找到銅鑰匙。"])
        let provider = Provider([.answer()])
        let result = try await run(context(source, "柳青找到什麼？"), provider)
        #expect(await provider.requests.count == 1)
        #expect(result.hasEvidence)
        #expect(result.provenance?.finalEvidenceIDs == result.citations.map(\.chunkID))
        #expect(result.provenance?.boundary == source.boundary())
    }

    @Test @MainActor func serviceCarriesSafeFollowupThroughPlanningRetrievalAndAnswerAndExportsTrace() async throws {
        let source = source(["柳青受了沈舟的恩情。沈舟把乾糧分給柳青。", "柳青後來幫沈舟送信。"])
        let history = [historical(source, "柳青為什麼幫沈舟？"), historical(source, "可能是報恩，但需要原文確認。", role: .assistant)]
        let provider = Provider([.plan("柳青最早是哪次受了沈舟的恩情？", ["柳青 沈舟 恩情"], []), .answer()])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = AIAssistantService(store: AIBookIndexStore(directory: dir), provider: provider, diagnosticOrigin: .testFixture)
        AIDiagnosticStore.shared.captureNextRequestContent = true
        let result = try await service.answer(context: context(source, "那他最早是哪次受了沈舟的恩情？", history: history))
        let requests = await provider.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.messages.contains { $0.content.contains(history[0].text) && $0.role == .user } })
        #expect(requests.last!.messages.last!.content.contains("柳青最早是哪次"))
        #expect(result.citations.contains { $0.quote.contains("乾糧") })
        #expect(result.notices.contains(localized("這次檢索未完整遍歷全書，無法保證第一次、全部或從未發生的判斷。")))
        #expect(requests.allSatisfy { !$0.messages[0].content.contains("柳青") })
        let trace = try #require(AIDiagnosticStore.shared.latest)
        #expect(trace.requestID == result.provenance?.requestID)
        let data = try trace.export(including: ["messages", "evidence", "response", "assessment"])
        print("PHASE2_TRACE_BASE64=" + data.base64EncodedString())
        #expect(String(decoding: data, as: UTF8.self).contains("testFixture"))
    }

    @Test func ambiguousReferenceIsAClarificationWithoutSearchGuess() async throws {
        let source = source(["柳青和沈舟都在。"])
        let provider = Provider([.plan("他去哪裡？", [], ["柳青或沈舟"])])
        let result = try await run(context(source, "他去哪裡？", history: [historical(source, "柳青和沈舟誰先到？")]), provider)
        #expect(!result.hasEvidence)
        #expect(result.content == localized("目前無法確定你指的是哪位人物或哪件事，請補上人名或事件。"))
        #expect(await provider.requests.count == 1)
        #expect(result.provenance?.sentEvidence.isEmpty == true)
    }

    @Test func noSafeHistoryDoesNotGuessAName() async throws {
        let source = source(["柳青知道秘密。"])
        let provider = Provider([])
        let result = try await run(context(source, "那他是誰？", history: [AIChatMessage(role: .user, text: "secret guessed name")]), provider)
        #expect(result.content == localized("目前無法確定你指的是哪位人物或哪件事，請補上人名或事件。"))
        #expect(await provider.requests.isEmpty)
    }

    @Test func scopeBookConversationLegacyVersionAndFailureFilter() {
        let source = source(["read", "late"])
        let early = source.atReadingPosition(spine: 0, renderedOffset: 4, renderedText: "read")
        var wrongBook = historical(source, "wrongBook"); wrongBook.provenance = .init(requestID: UUID(), bookID: UUID(), conversationID: conversation, boundary: early.boundary(), status: .completed)
        var wrongConversation = historical(source, "wrongConversation"); wrongConversation.provenance = .init(requestID: UUID(), bookID: book, conversationID: UUID(), boundary: early.boundary(), status: .completed)
        var failed = historical(early, "failed"); failed.provenance?.status = .failed
        let whole = historical(source, "whole", boundary: source.boundary(wholeBook: true))
        let changed = self.source(["edit", "late"])
        let messages = [wrongBook, wrongConversation, failed, whole, historical(source, "late"), historical(changed, "old version"),
                        AIChatMessage(role: .assistant, text: "legacy"), historical(early, "safe")]
        #expect(context(early, "clear", history: messages).safeHistory().map(\.text) == ["safe"])
        #expect(messages.count == 8)
    }

    @Test func safeHistoryNeverBecomesSourceOrCharacterFact() async throws {
        let source = source(["柳青撿起一枚銅錢。"])
        let provider = Provider([.answer()])
        let result = try await run(context(source, "柳青撿到什麼？", history: [historical(source, "柳青是皇帝，這是猜測。", role: .assistant)]), provider)
        #expect(result.citations.allSatisfy { !$0.quote.contains("皇帝") })
        let request = try #require(await provider.requests.first)
        #expect(request.messages.contains { $0.role == .assistant && $0.content.contains("evidence=\"false\"") })
        #expect(!request.messages.last!.content.contains("皇帝"))
    }

    @Test func adjacentSourceReadHasSubjectAndRoundTripsWithDefaultChunks() async throws {
        let source = source([String(repeating: "柳青走過長街。", count: 105) + "\n他拾起獨特琉璃珠。" + String(repeating: "風從巷口吹過。", count: 160)])
        let built = index(source)
        #expect(built.chunkerConfiguration == "800/120/200")
        #expect(built.chunks.count >= 3)
        let hits = try await built.retrieve(query: "獨特琉璃珠", maximumProgress: 1, boundary: source.boundary())
        let evidence = AIQuestionSourceReader.collect(hits: hits, index: built, context: context(source, "獨特琉璃珠"), query: "獨特琉璃珠", kind: .initial)
        #expect(evidence.contains { $0.kind == .adjacent })
        #expect(evidence.contains { $0.chunk.text.contains("柳青") })
        assertRanges(evidence, source: source)
    }
    func assertRanges(_ evidence: [AIQuestionEvidence], source: AIBookContentAdapter) {
        for item in evidence {
            let c = item.chunk
            let text = source.chunkSections[c.start.spineIndex].text
            let range = Range(NSRange(location: c.start.charOffset, length: c.end.charOffset - c.start.charOffset), in: text)
            #expect(range.map { String(text[$0]) } == c.text)
            #expect(source.boundary().contains(c))
        }
        for (i, a) in evidence.enumerated() {
            for b in evidence.dropFirst(i + 1) where a.chunk.sectionID == b.chunk.sectionID {
                #expect(!(a.chunk.start.charOffset..<a.chunk.end.charOffset).overlaps(b.chunk.start.charOffset..<b.chunk.end.charOffset))
            }
        }
    }

    @Test func prefixCannotExposeUnreadSuffixOrBorrowWholeChunkID() async throws {
        let safe = "柳青拿起𠮷👩🏽‍🚀e\u{301}銅鑰匙。"
        let source = source([safe + "UNREAD_IDENTITY_REVEAL"], offset: safe.utf16.count)
        let provider = Provider([.answer()])
        let result = try await run(context(source, "銅鑰匙"), provider)
        let evidence = try #require(result.provenance?.sentEvidence)
        #expect(!evidence.isEmpty)
        #expect(evidence.allSatisfy { $0.kind == .prefix && $0.chunk.id != $0.parentChunkID })
        assertRanges(evidence, source: source)
        #expect(await provider.requests.allSatisfy { !$0.messages.map(\.content).joined().contains("UNREAD_IDENTITY_REVEAL") })
        #expect(index(source).chunks[0].text.contains("UNREAD_IDENTITY_REVEAL"))
    }

    @Test func neighborDoesNotCrossBoundary() async throws {
        let read = String(repeating: "柳青手持信物。", count: 180)
        let source = source([read + "UNREAD_REVEAL"], offset: read.utf16.count)
        let provider = Provider([.answer()])
        let result = try await run(context(source, "柳青信物"), provider)
        assertRanges(result.provenance!.sentEvidence, source: source)
        #expect(await provider.requests.allSatisfy { !$0.messages.map(\.content).joined().contains("UNREAD_REVEAL") })
    }

    @Test func unverifiedAnchorStaysZeroAndDisplaysCoverageReason() async throws {
        let source = source(["earlier key", "current secret"]).atReadingPosition(spine: 1, renderedOffset: 10, renderedText: "unmapped ruby")
        #expect(source.boundary().utf16Offset == 0)
        let result = try await run(context(source, "earlier key"), Provider([.answer()]))
        #expect(result.notices.contains(localized("目前章節位置尚無法驗證，本次只使用此前可確認的內容。")))
        #expect(result.provenance!.sentEvidence.allSatisfy { $0.chunk.start.spineIndex == 0 })
    }

    @Test func unicodeOverlapDedupCreatesExactFragments() {
        let source = source([String(repeating: "𠮷👩🏽‍🚀e\u{301}柳青持劍。", count: 250)])
        let chunks = index(source).chunks
        #expect(chunks.count > 2)
        let evidence = AIQuestionSourceReader.deduplicated(chunks.map { .init(chunk: $0, parentChunkID: $0.id, kind: .initial) }, context: context(source, "劍"))
        assertRanges(evidence, source: source)
        #expect(evidence.contains { $0.chunk.id.hasPrefix("fragment:") })
    }

    @Test func contextRemovalCannotRemainInFinalCitations() throws {
        let source = source(["key " + String(repeating: "a", count: 700), "coin " + String(repeating: "b", count: 700)])
        let evidence = index(source).chunks.map { AIQuestionEvidence(chunk: $0, parentChunkID: $0.id, kind: .initial) }
        var budget = AIQuestionBudget(); budget.maximumInputCharacters = 1_000; budget.maximumInputBytes = 2_000
        let selected = try AIQuestionPrompt.assemble(system: "rules", data: "key", history: [], evidence: evidence, budget: budget, requireHistory: false)
        #expect(selected.evidence.count == 1)
        let raw = LLMRawResponse(content: evidence.map { "[\($0.chunk.id)]" }.joined(), provider: "mock", model: "mock")
        let result = try AIRAGPipeline.result(raw: raw, chunks: selected.evidence.map(\.chunk), nonce: "test", sectionTitleByID: [:])
        #expect(result.citations.map(\.chunkID) == selected.evidence.map { $0.chunk.id })
    }

    @Test func zeroHitsCanPlanOnceThenActuallyRetrieve() async throws {
        let source = source(["copper key beside the door"])
        let provider = Provider([.plan("copper key", ["copper key"], []), .answer()])
        let result = try await run(context(source, "zyxwvnonmatch"), provider)
        #expect(result.citations.contains { $0.quote.contains("copper key") })
        #expect(await provider.requests.count == 2)
    }

    @Test func partialDraftGetsDistantEvidenceInOneRevision() async throws {
        let source = source(["signal amber pledge", "unrelated scenery", "origin quartz rescue"])
        let provider = Provider([.answer("partial"), .plan("origin quartz", ["origin quartz"], []), .answer()])
        let result = try await run(context(source, "signal amber"), provider)
        #expect(await provider.requests.count == 3)
        #expect(Set(result.citations.map(\.spineIndex)) == [0, 2])
        #expect(result.provenance!.sentEvidence.count >= 2)
    }

    @Test func repeatedQueryAndNoNewEvidenceStopWithoutAnotherAnswer() async throws {
        let source = source(["amber key"])
        for queries in [["amber"], ["key"]] {
            let provider = Provider([.answer("partial"), .plan("amber", queries, [])])
            let result = try await run(context(source, "amber"), provider)
            #expect(result.hasEvidence)
            #expect(await provider.requests.count == 2)
        }
    }

    @Test(arguments: [1, 2, 3, 4]) func nestedCallsRespectWholeRequestBudget(calls: Int) async throws {
        let source = source(["amber key", "quartz origin"])
        var budget = AIQuestionBudget(); budget.maximumModelCalls = calls; budget.maximumQueries = 2
        let provider = Provider([.answer("partial"), .plan("quartz", ["quartz", "quartz", "other"], []), .answer("partial")])
        let trace = AIRequestTrace(feature: "budgetFixture", bookID: book, adapter: source, boundary: source.boundary(), origin: .testFixture)
        _ = try await AIDiagnostics.$current.withValue(trace) {
            try await run(context(source, "amber", budget: budget), provider)
        }
        #expect(await provider.requests.count <= calls)
        let export = try JSONDecoder().decode(AIRequestTrace.Export.self, from: trace.export())
        let stopped = try #require(export.events.last(where: { $0.stage == "questionStopped" }))
        #expect(Int(stopped.values["queries"]!)! <= budget.maximumQueries)
        #expect(Int(stopped.values["modelCalls"]!)! <= calls)
    }

    @Test func zeroQueryBudgetAndNoEvidenceRemainLimited() async throws {
        let source = source(["amber key"])
        var budget = AIQuestionBudget(); budget.maximumQueries = 0
        let provider = Provider([])
        let result = try await run(context(source, "amber", budget: budget), provider)
        #expect(result.content == localized("目前可用、已讀範圍內的檢索結果不足以確認。"))
        #expect(!result.content.contains("書中沒有"))
        #expect(await provider.requests.isEmpty)
    }

    @Test func historyAndInputBudgetsPreserveQuestionOrFailExplicitly() throws {
        let source = source(["柳青有鑰匙。"])
        let history = (0..<10).map { historical(source, "history \($0) " + String(repeating: "x", count: 100)) }
        var budget = AIQuestionBudget(); budget.maximumInputCharacters = 500
        let request = context(source, "necessary question", history: history, budget: budget)
        #expect(request.safeHistory().count == 6)
        let selected = try AIQuestionPrompt.assemble(system: "rule", data: request.question, history: request.safeHistory(), evidence: [], budget: budget, requireHistory: false)
        #expect(selected.request.messages.last!.content.contains(request.question))
        #expect(throws: AIQuestionFailure.self) {
            try AIQuestionPrompt.assemble(system: "rule", data: request.question, history: request.safeHistory(), evidence: [], budget: budget, requireHistory: true)
        }
    }

    @Test(arguments: ["length", "content_filter", "empty", "malformed", "rate", "network"])
    func generationFailuresNeverBecomeSuccessOrRetry(kind: String) async throws {
        let source = source(["amber key"])
        let reply: Provider.Reply
        switch kind {
        case "rate": reply = .failure(.rateLimited)
        case "network": reply = .failure(.networkError("fixture"))
        case "empty": reply = .raw("  ", nil)
        case "malformed": reply = .raw("not JSON", nil)
        default: reply = .raw("truncated", kind)
        }
        let provider = Provider([reply])
        do {
            if kind == "malformed" {
                _ = try await run(context(source, "他是誰？", history: [historical(source, "柳青")]), provider)
            } else { _ = try await run(context(source, "amber"), provider) }
            Issue.record("Expected explicit failure")
        } catch { #expect(await provider.requests.count == 1) }
    }

    @Test func plannerTypesAndLengthsAreStrict() {
        for text in [#"{"rewrittenQuestion":"","retrievalQueries":[],"unresolvedReferences":[],"purpose":"x"}"#,
                     #"{"rewrittenQuestion":"a","retrievalQueries":[1],"unresolvedReferences":[],"purpose":"x"}"#,
                     #"{"rewrittenQuestion":"a","retrievalQueries":["a","b","c","d"],"unresolvedReferences":[],"purpose":"x"}"#] {
            #expect(throws: (any Error).self) { try AIAgenticAssistant.QuestionPlan.decode(text) }
        }
    }

    @Test func oldOwnerCannotPublishIntoNewSessionOrNarrowScope() {
        let source = source(["early", "late"])
        let id = UUID()
        let owner = AIChatRequestOwner(requestID: id, conversationID: conversation, bookID: book, boundary: source.boundary())
        #expect(owner.canPublish(requestID: id, conversationID: conversation, bookID: book, boundary: source.boundary(wholeBook: true)))
        #expect(!owner.canPublish(requestID: UUID(), conversationID: conversation, bookID: book, boundary: source.boundary()))
        #expect(!owner.canPublish(requestID: id, conversationID: UUID(), bookID: book, boundary: source.boundary()))
        #expect(!owner.canPublish(requestID: id, conversationID: conversation, bookID: book,
            boundary: source.atReadingPosition(spine: 0, renderedOffset: 5, renderedText: "early").boundary()))
    }

    @Test func legacyPersistenceRemainsReadableAndRetryUpsertsOneSession() {
        let name = "phase2.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = AIChatStore(defaults: defaults)
        let session = AIChatSession(messages: [AIChatMessage(role: .user, text: "legacy")])
        store.save(session, forBook: book)
        store.save(session, forBook: book)
        #expect(store.sessions(forBook: book).count == 1)
        #expect(store.sessions(forBook: book)[0].messages[0].provenance == nil)
    }

    @Test func diagnosticsOptInStillControlsPlannerInputs() async throws {
        let source = source(["amber key"])
        let trace = AIRequestTrace(feature: "fixture", bookID: book, adapter: source, boundary: source.boundary(), origin: .testFixture)
        let provider = Provider([.plan("amber", ["amber"], []), .answer()])
        _ = try await AIDiagnostics.$current.withValue(trace) {
            try await AIAgenticAssistant.answerQuestion(context: context(source, "private question zyxw"), index: index(source), provider: AITracedProvider(base: provider))
        }
        let export = String(decoding: try trace.export(including: ["messages", "response"]), as: UTF8.self)
        #expect(!export.contains("private question"))
        #expect(!export.contains("amber"))
        #expect(export.contains("unavailableContentCategories"))
    }

    @Test func hundredsOfChaptersUseProductionChunkerAndDistantSources() async throws {
        var texts = (0..<320).map { i in String(repeating: "Wind moved through the empty valley. ", count: 35) + " chapter \(i)" }
        texts[2] += "\nUniqueAmberPledge was made."
        texts[250] += "\nUniqueQuartzRescue explains the pledge."
        texts[310] += "\nUNREAD_FUTURE_DISCLOSURE"
        let source = source(texts, spine: 270)
        let started = Date()
        let built = index(source)
        #expect(built.chunks.count > 320)
        let provider = Provider([.answer("partial"), .plan("UniqueQuartzRescue", ["UniqueQuartzRescue"], []), .answer()])
        let result = try await AIAgenticAssistant.answerQuestion(context: context(source, "UniqueAmberPledge"), index: built, provider: provider)
        #expect(Set(result.citations.map(\.spineIndex)).isSuperset(of: [2, 250]))
        #expect(result.provenance!.sentEvidence.allSatisfy { $0.chunk.start.spineIndex <= 270 })
        #expect(await provider.requests.allSatisfy { !$0.messages.map(\.content).joined().contains("UNREAD_FUTURE_DISCLOSURE") })
        print("PHASE2_LONG_FIXTURE chapters=320 chunks=\(built.chunks.count) utf16=\(texts.reduce(0) { $0 + $1.utf16.count }) elapsedMs=\(Date().timeIntervalSince(started) * 1000)")
    }
    @Test func retryReusesUserTurnAndRejectsDuplicatePendingOrSuccess() throws {
        let source = source(["key"])
        var session = AIChatSession(id: conversation)
        let metadata = AIChatProvenance(requestID: UUID(), bookID: book, conversationID: conversation, boundary: source.boundary(), status: .pending)
        let preparedFirst = session.prepareQuestion("key", metadata: metadata)
        let first = try #require(preparedFirst)
        let duplicate = session.prepareQuestion("key", metadata: metadata)
        #expect(duplicate == nil)
        session.messages[1].isPending = false
        session.messages[1].errorMessage = "fixture failure"
        let preparedSecond = session.prepareQuestion("key", metadata: metadata, retrying: first.user)
        let second = try #require(preparedSecond)
        #expect(second.user == first.user)
        #expect(session.messages.count == 2)
        session.messages[1].isPending = false
        let completedRetry = session.prepareQuestion("key", metadata: metadata, retrying: first.user)
        #expect(completedRetry == nil)
    }

    actor PausedProvider: LLMProviding {
        let identifier = "paused-mock", defaultModel = "fixture"
        var pending: CheckedContinuation<LLMRawResponse, Never>?
        var started: CheckedContinuation<Void, Never>?
        var didStart = false
        func waitUntilStarted() async {
            if didStart { return }
            await withCheckedContinuation { started = $0 }
        }
        func generate(_ request: LLMGenerationRequest, model: String?) async throws -> LLMRawResponse {
            await withCheckedContinuation {
                pending = $0; didStart = true; started?.resume(); started = nil
            }
        }
        func finish() { pending?.resume(returning: .init(content: "late fixture answer", provider: identifier, model: defaultModel)); pending = nil }
    }

    @Test @MainActor func cancellationAfterProviderStartsCannotPublishLateAnswer() async throws {
        let source = source(["amber key"])
        let provider = PausedProvider()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = AIAssistantService(store: AIBookIndexStore(directory: dir), provider: provider, diagnosticOrigin: .testFixture)
        let request = context(source, "amber")
        let task = Task { try await service.answer(context: request) }
        await provider.waitUntilStarted()
        task.cancel()
        await provider.finish()
        do { _ = try await task.value; Issue.record("Cancelled answer published") }
        catch { #expect(error is CancellationError) }
    }

    @Test func incompleteLegacyProvenancePreservesTextButCannotEnterContext() throws {
        let source = source(["key"])
        let message = historical(source, "older visible answer", role: .assistant)
        let encoded = try JSONEncoder().encode(message)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["provenance"] = ["requestID": UUID().uuidString]
        let decoded = try JSONDecoder().decode(AIChatMessage.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.text == message.text)
        #expect(decoded.provenance == nil)
        #expect(context(source, "key", history: [decoded]).safeHistory().isEmpty)
    }

}
