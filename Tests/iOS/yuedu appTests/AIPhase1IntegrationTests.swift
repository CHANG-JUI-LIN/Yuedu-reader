import Foundation
import Testing
@testable import yuedu_app

@Suite("AI Phase 1 integration (testFixture)", .serialized)
struct AIPhase1IntegrationTests {
    let bookID = UUID()
    func adapter(_ texts: [String?], transform: String = "fixture.v1") -> AIBookContentAdapter {
        .init(bookID: bookID, chapters: texts.indices.map { BookChapter(index: $0, title: "Chapter \($0)", content: "") }, transformationVersion: transform) { texts[$0] }
    }
    func end(_ source: AIBookContentAdapter, spine: Int = 0, offset: Int? = nil, whole: Bool = false) -> AIReadingBoundary {
        .init(sourceVersion: source.contentFingerprint, sectionID: source.chunkSections[spine].id,
            spineIndex: spine, utf16Offset: offset ?? source.chunkSections[spine].text.utf16.count, wholeBook: whole)
    }
    func index(_ source: AIBookContentAdapter) -> AIBookRetrievalIndex {
        .init(bookID: bookID, chunks: AIPublicationChunker(maximumCharacters: 20, overlapCharacters: 0).chunks(from: source),
            contentFingerprint: source.contentFingerprint, manifest: source.manifest, chunkerConfiguration: "20/0/0")
    }
    struct Embedding: AIEmbeddingProviding {
        let identifier = "fixture"
        let dimensions: Int
        let vector: [Float]
        func embed(_ texts: [String]) async throws -> [[Float]] { texts.map { _ in vector } }
    }
    enum Unexpected: Error { case build }

    @Test func manifestIsDeterministicAndVersioned() {
        #expect(adapter(["same", nil]).manifest == adapter(["same", nil]).manifest)
        #expect(adapter(["same"]).contentFingerprint != adapter(["same"], transform: "fixture.v2").contentFingerprint)
        #expect(adapter(["same", nil]).manifest.chapters[1].status == .notDownloaded)
        #expect(adapter(["same", nil]).manifest.chapters[1].digest == nil)
    }

    @Test func oldSchemaRebuildsOnceAndInvalidatesOldCitations() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"identifier":"legacy","chunks":[]}"#.utf8).write(to: dir.appendingPathComponent("\(bookID).json"))
        let source = adapter(["same fixture"])
        let built = index(source)
        _ = try await AIBookIndexStore(directory: dir).index(for: bookID, expectedIdentifier: built.identifier) { built }
        let reloaded = try await AIBookIndexStore(directory: dir).index(for: bookID, expectedIdentifier: built.identifier) { throw Unexpected.build }
        #expect(reloaded.manifest == source.manifest)
        let old = LLMCitation(chunkID: built.chunks[0].id, quote: "same", spineIndex: 0, charOffset: 0)
        #expect(AITextCoordinates.citationOffset(old, sourceVersion: source.contentFingerprint, sourceText: "same", renderedText: "same") == nil)
        var current = old; current.sourceVersion = source.contentFingerprint; current.coordinateUnit = "sourceUTF16"
        #expect(AITextCoordinates.citationOffset(current, sourceVersion: adapter(["edit"]).contentFingerprint, sourceText: "edit", renderedText: "edit") == nil)
    }

    @Test(arguments: [false, true]) func vectorAndHybridRetrieveBeyondThirtyTwo(hybrid: Bool) async throws {
        let source = adapter(["read answer"] + Array(repeating: "unread answer", count: 40))
        let chunks = AIPublicationChunker().chunks(from: source)
        let vectors = Dictionary(uniqueKeysWithValues: chunks.map { ($0.id, $0.start.spineIndex == 0 ? [Float(0.5), 1] : [1, 0]) })
        let built = AIBookRetrievalIndex(bookID: bookID, chunks: chunks, tier: .hybrid, embeddingIdentifier: "fixture", vectors: vectors, contentFingerprint: source.contentFingerprint)
        let hits = try await built.retrieve(query: hybrid ? "answer" : "nonmatching", maximumProgress: 1,
            embedding: Embedding(dimensions: 2, vector: [1, 0]), boundary: end(source))
        #expect(hits.map(\.chunk.start.spineIndex) == [0])
        #expect(hits.allSatisfy { !$0.chunk.text.contains("unread") })
    }

    @Test func boundaryIsIndependentOfAvailableTextDenominatorAndExcludesStraddlers() async throws {
        let partial = adapter(["read answer", nil])
        let full = adapter(["read answer", "long unread body"])
        let partialEnd = end(partial, offset: 4)
        let fullEnd = end(full, offset: 4)
        #expect(partialEnd.utf16Offset == fullEnd.utf16Offset)
        #expect(partial.progress(forSpine: 0, charOffset: 4) != full.progress(forSpine: 0, charOffset: 4))
        #expect(try await index(full).retrieve(query: "answer", maximumProgress: 1, boundary: fullEnd).isEmpty)
        #expect(full.sections(in: fullEnd).first?.text == "read")
        #expect(try await index(full).retrieve(query: "answer", maximumProgress: 1, boundary: partialEnd).isEmpty)
    }

    @Test func literalMappingAndGraphemeBoundaries() throws {
        let source = "前言𠮷👩🏽‍🚀e\u{301}葛\u{E0100}正文"
        let rendered = "章名\n" + source
        var citation = LLMCitation(chunkID: "fixture", quote: "𠮷👩🏽‍🚀e\u{301}", spineIndex: 0, charOffset: 2)
        citation.sourceVersion = "v1"; citation.coordinateUnit = "sourceUTF16"
        #expect(AITextCoordinates.citationOffset(citation, sourceVersion: "v1", sourceText: source, renderedText: rendered) == 5)
        #expect(AITextCoordinates.citationOffset(citation, sourceVersion: "v1", sourceText: source, renderedText: rendered + rendered) == nil)
        #expect(AITextCoordinates.citationOffset(citation, sourceVersion: "v1", sourceText: source, renderedText: "ruby 注音不同") == nil)
        #expect(AITextCoordinates.prefix("𠮷👩🏽‍🚀x", throughUTF16: 3) == "𠮷")
        #expect(AITextCoordinates.sourceBoundaryOffset(source: source, rendered: "不同文字", renderedOffset: 4) == 0)
    }

    @Test func embeddingFailuresAreExplicitAndDistinguishContracts() async throws {
        let source = adapter(["answer"])
        let chunks = index(source).chunks
        let built = AIBookRetrievalIndex(bookID: bookID, chunks: chunks, tier: .hybrid, embeddingIdentifier: "fixture", vectors: [chunks[0].id: [1, 0]], contentFingerprint: source.contentFingerprint)
        for (dimensions, vector, reason) in [(2, [Float(1), 0, 1], "queryDocumentMismatch"), (3, [Float(1), 0], "declaredDimensionMismatch")] {
            let trace = AIRequestTrace(feature: "embeddingTest", bookID: bookID, adapter: source, boundary: end(source), origin: .testFixture)
            let hits = try await AIDiagnostics.$current.withValue(trace) {
                try await built.retrieve(query: "answer", maximumProgress: 1, embedding: Embedding(dimensions: dimensions, vector: vector), boundary: end(source))
            }
            #expect(hits.count == 1)
            #expect(String(decoding: try trace.export(), as: UTF8.self).contains(reason))
        }
        // Consistent 256-dimensional vectors can be compared; a separate 512 contract rejects them.
        let vector = Array(repeating: Float(1), count: 256)
        try AIEmbeddingContract.validate([vector, vector], count: 2, dimensions: 256)
        #expect(throws: AIEmbeddingContract.Failure.declaredDimensionMismatch) {
            try AIEmbeddingContract.validate([vector, vector], count: 2, dimensions: 512)
        }
        #expect(throws: AIEmbeddingContract.Failure.nonFiniteOrZero) {
            try AIEmbeddingContract.validate([[.nan, 1]], count: 1, dimensions: 2)
        }
    }

    @Test @MainActor func scansRefreshAfterMoreLocalContent() async {
        let scanGate = ScanGate()
        let scanner = AISpeakerScanCoordinator { sections, aliases in
            if sections.first?.text.hasPrefix("SLOW") == true { await scanGate.suspend() }
            return AIBookSpeakerScan.scan(sections: sections, aliases: aliases)
        }
        let old = adapter(["張三說：「早安。」", nil])
        let new = adapter(["張三說：「早安。」", "李四說：「你好。」"])
        await scanner.scan(adapter: old, boundary: end(old, whole: true), aliases: [:])
        #expect(!scanner.speakers.contains { $0.name == "李四" })
        await scanner.scan(adapter: new, boundary: end(new, spine: 1), aliases: [:])
        #expect(scanner.speakers.contains { $0.name == "李四" })
        let long = adapter(["SLOW\n" + String(repeating: "張三說：「早安。」\n", count: 1000)])
        let task = Task { await scanner.scan(adapter: long, boundary: end(long), aliases: [:]) }
        await scanGate.waitForStart()
        await scanner.scan(adapter: new, boundary: end(new, spine: 1), aliases: [:])
        await scanGate.release()
        await task.value
        #expect(scanner.speakers.contains { $0.name == "李四" })
    }

    @Test func diagnosticsOnlyExportSelectedOptedInContent() throws {
        let source = adapter(["PRIVATE_NOVEL"])
        let trace = AIRequestTrace(feature: "diagnosticTest", bookID: bookID, adapter: source, boundary: end(source), origin: .testFixture)
        trace.content("messages", ["PRIVATE_QUESTION"])
        let metadata = String(decoding: try trace.export(including: ["messages", "evidence"]), as: UTF8.self)
        #expect(!metadata.contains("PRIVATE_"))
        #expect(metadata.contains("testFixture"))
        let captured = AIRequestTrace(feature: "diagnosticTest", bookID: bookID, adapter: source, boundary: end(source), origin: .testFixture, captureContent: true)
        captured.content("messages", ["PRIVATE_QUESTION Bearer TOPSECRET https://private.example/?token=abc me@example.org"])
        captured.content("evidence", ["PRIVATE_NOVEL"])
        #expect(!String(decoding: try captured.export(), as: UTF8.self).contains("PRIVATE_"))
        let selected = String(decoding: try captured.export(including: ["messages"]), as: UTF8.self)
        #expect(selected.contains("PRIVATE_QUESTION"))
        #expect(!selected.contains("PRIVATE_NOVEL"))
        for secret in ["TOPSECRET", "private.example", "token=abc", "me@example.org"] { #expect(!selected.contains(secret)) }
    }

    @Test @MainActor func failedGenerationPreservesExistingCardAndSeparatesCitations() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cards = AICharacterCardStore(directory: dir)
        let source = adapter(Array(repeating: "hero answer", count: 5))
        let boundary = end(source, spine: 4)
        let chunks = AIPublicationChunker(maximumCharacters: 800, overlapCharacters: 120, minimumCharacters: 200).chunks(from: source)
        let profileJSON = #"{"firstAppearance":"early","role":"hero","relationships":[],"aliasCandidates":["lateAlias"],"summary":"valid fixture"}"#
        let finish: [String: Any] = ["action": "finish", "answer": profileJSON, "citations": [chunks[0].id]]
        let finishJSON = String(decoding: try JSONSerialization.data(withJSONObject: finish), as: UTF8.self)
        let provider = ScriptProvider(replies: [.init(content: #"{"action":"retrieve","query":"hero"}"#, provider: "fixture", model: "fixture"), .init(content: finishJSON, provider: "fixture", model: "fixture", finishReason: "stop")])
        let service = AIAssistantService(store: .init(directory: dir.appendingPathComponent("index")), provider: provider, cards: cards, diagnosticOrigin: .testFixture)
        let good = try await service.characterCard(name: "hero", bookID: bookID, adapter: source, boundary: boundary)
        #expect(good.retrievedEvidenceIDs?.count == 5)
        #expect(good.citationChunkIDs == [chunks[0].id])
        #expect(cards.aliasMap(forBook: bookID, boundary: boundary)["lateAlias"] == "hero")
        #expect(cards.aliasMap(forBook: bookID, boundary: end(source, spine: 0)).isEmpty)
        var full = good; full.sourceBoundary = end(source, spine: 4, whole: true)
        #expect(!full.isSafe(at: boundary))
        var legacy = good; legacy.sourceBoundary = nil
        #expect(!legacy.isSafe(at: boundary))
        for reply in [LLMRawResponse(content: finishJSON, provider: "fixture", model: "fixture", finishReason: "length"),
                      .init(content: "broken JSON", provider: "fixture", model: "fixture"),
                      .init(content: "", provider: "fixture", model: "fixture"),
                      .init(content: #"{"action":"finish","answer":"{}"}"#, provider: "fixture", model: "fixture")] {
            let failing = ScriptProvider(replies: [reply])
            let attempt = AIAssistantService(store: .init(directory: dir.appendingPathComponent("index")), provider: failing, cards: cards, diagnosticOrigin: .testFixture)
            await #expect(throws: (any Error).self) {
                try await attempt.characterCard(name: "hero", bookID: bookID, adapter: source, boundary: boundary)
            }
            #expect(cards.profiles(forBook: bookID) == [good])
            #expect(await failing.calls == 1)
        }
    }

    actor ScriptProvider: LLMProviding {
        nonisolated let identifier = "fixture"
        nonisolated let defaultModel = "fixture"
        var replies: [LLMRawResponse]
        var calls = 0
        init(replies: [LLMRawResponse]) { self.replies = replies }
        func generate(_ request: LLMGenerationRequest, model: String?) async throws -> LLMRawResponse {
            calls += 1
            guard !replies.isEmpty else { throw LLMError.invalidSchema }
            return replies.removeFirst()
        }
    }
}

extension AIPhase1IntegrationTests {
    actor ScanGate {
        var started = false
        var waiter: CheckedContinuation<Void, Never>?
        var startWaiter: CheckedContinuation<Void, Never>?
        func suspend() async {
            started = true; startWaiter?.resume(); startWaiter = nil
            await withCheckedContinuation { waiter = $0 }
        }
        func waitForStart() async {
            if started { return }
            await withCheckedContinuation { startWaiter = $0 }
        }
        func release() { waiter?.resume(); waiter = nil }
    }
    actor BuildGate {
        var started = false
        var releaseWaiter: CheckedContinuation<Void, Never>?
        var startWaiters: [CheckedContinuation<Void, Never>] = []
        var count = 0
        var shared = false
        var sharedWaiter: CheckedContinuation<Void, Never>?
        func releaseSharedSignal() { shared = true; sharedWaiter?.resume(); sharedWaiter = nil }
        func waitForSharedSignal() async {
            if shared { return }
            await withCheckedContinuation { sharedWaiter = $0 }
        }
        func build(_ value: AIBookRetrievalIndex) async -> AIBookRetrievalIndex {
            count += 1
            started = true
            startWaiters.forEach { $0.resume() }; startWaiters = []
            await withCheckedContinuation { releaseWaiter = $0 }
            return value
        }
        func waitForStart() async {
            if started { return }
            await withCheckedContinuation { startWaiters.append($0) }
        }
        func release() { releaseWaiter?.resume(); releaseWaiter = nil }
    }

    @Test func concurrentBuildsShareWorkAndOldSnapshotCannotOverwriteNew() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AIBookIndexStore(directory: dir)
        let first = index(adapter(["old content"]))
        let newer = index(adapter(["new content"]))
        let gate = BuildGate()
        let original = Task { try await store.index(for: bookID, expectedIdentifier: first.identifier) { await gate.build(first) } }
        await gate.waitForStart()
        let shared: Task<AIBookRetrievalIndex, Error> = await withCheckedContinuation { joined in
            let task = Task {
                try await store.index(for: bookID, expectedIdentifier: first.identifier, onCacheDecision: { decision in
                    #expect(decision == "sharedBuild")
                    Task { await gate.releaseSharedSignal() }
                }) { throw Unexpected.build }
            }
            joined.resume(returning: task)
        }
        await gate.waitForSharedSignal()
        _ = try await store.index(for: bookID, expectedIdentifier: newer.identifier) { newer }
        await gate.release()
        #expect(try await original.value.identifier == first.identifier)
        #expect(try await shared.value.identifier == first.identifier)
        #expect(await gate.count == 1)
        let cold = try await AIBookIndexStore(directory: dir).index(for: bookID, expectedIdentifier: newer.identifier) { throw Unexpected.build }
        #expect(cold.identifier == newer.identifier)
    }

    @Test func recapRequiresMatchingVersionAndSafeEvidenceBoundary() {
        let source = adapter(["first", "second"])
        let later = end(source, spine: 1)
        var recap = AIRecap(text: "summary", progress: 0.8, generatedAt: Date(), provider: "fixture", model: "fixture", promptVersion: AIRecap.currentPromptVersion)
        recap.sourceBoundary = later
        recap.evidenceChunkIDs = ["fixture"]
        #expect(AIRecap.canReuse(recap, atProgress: 0.81, boundary: later))
        #expect(!AIRecap.canReuse(recap, atProgress: 0.79, boundary: end(source, spine: 0)))
        #expect(!AIRecap.canReuse(recap, atProgress: 0.81, boundary: end(adapter(["changed", "second"]), spine: 1)))
    }

    @Test @MainActor func rosterUnknownOrWholeBookScopeIsNotSafe() {
        let suite = "AIPhase1-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AISpeakerRosterStore(defaults: defaults)
        let source = adapter(["first", "second"])
        let boundary = end(source, spine: 1)
        store.save(["lateAlias": "hero"], forBook: bookID)
        #expect(store.safeRoster(forBook: bookID, boundary: boundary).isEmpty)
        store.save(["lateAlias": "hero"], forBook: bookID, boundary: end(source, spine: 1, whole: true))
        #expect(store.safeRoster(forBook: bookID, boundary: boundary).isEmpty)
        store.save(["earlyAlias": "hero"], forBook: bookID, boundary: end(source, spine: 0))
        #expect(store.safeRoster(forBook: bookID, boundary: boundary)["earlyAlias"] == "hero")
    }
}

extension AIPhase1IntegrationTests {
    @Test @MainActor func localOnlineGatherReportsMissingWithoutDownloading() async {
        var book = ReadingBook(title: "fixture", source: "https://fixture.invalid/book", contentFilename: "")
        book.isOnline = true
        book.bookSourceId = UUID()
        book.onlineChapters = [OnlineChapterRef(index: 0, title: "fixture", url: "https://fixture.invalid/1")]
        let service = OnlineChapterContentService(book: book, store: nil)
        let provider = OnlineBookContentProvider(service: service)
        let builder = OnlineProviderAttributedStringBuilder(provider: provider, renderSize: .init(width: 320, height: 600))
        let result = await builder.localChapterText(at: 0)
        #expect(result.status == .notDownloaded)
        #expect(result.text == nil)
    }

    @Test func providerRetainsWireMetadataAndCompatibleLegacyResponse() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Phase1HTTPFixture.self]
        let provider = OpenAICompatibleProvider(endpoint: URL(string: "https://fixture.invalid/length")!, apiKey: "fixture-key", defaultModel: "requested", configuration: config)
        let raw = try await provider.generate(.init(messages: [.init(role: .user, content: "fixture")]))
        #expect(raw.finishReason == "length")
        #expect(raw.model == "served-model")
        #expect(raw.usage?.completionTokens == 5)
        #expect(raw.httpStatus == 200)
        #expect(throws: LLMError.incompleteOutput) { try raw.validateCompletion() }
        let legacy = OpenAICompatibleProvider(endpoint: URL(string: "https://fixture.invalid/legacy")!, apiKey: "fixture-key", defaultModel: "requested", configuration: config)
        let old = try await legacy.generate(.init(messages: []))
        #expect(old.finishReason == nil)
        #expect(old.usage == nil)
        #expect(old.model == "requested")
        try old.validateCompletion()
    }

    @Test func exportsSanitizedFixtureTraceFromProductionRetrieval() async throws {
        let source = adapter(["hero found a key beside the door."])
        let built = index(source)
        let trace = AIRequestTrace(feature: "answer", bookID: bookID, adapter: source, boundary: end(source), origin: .testFixture, captureContent: true)
        try await AIDiagnostics.$current.withValue(trace) {
            let hits = try await built.retrieve(query: "key", maximumProgress: 1, boundary: end(source))
            let cited = try #require(hits.first?.id)
            let provider = AITracedProvider(base: ScriptProvider(replies: [.init(content: "A key was by the door. [\(cited)]", provider: "fixture", model: "fixture-model", finishReason: "stop", httpStatus: 200)]))
            let result = try await AIRAGPipeline.answer(query: "Where was the key?", hits: hits, provider: provider)
            #expect(result.citations.count == 1)
        }
        trace.event("complete", ["result": "success", "note": "synthetic fixture; no real model or user data"])
        print("AI_PHASE1_TRACE_BASE64=" + (try trace.export(including: ["messages", "evidence", "response"])).base64EncodedString())
    }
}

private final class Phase1HTTPFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = request.url?.path == "/length"
            ? #"{"model":"served-model","choices":[{"message":{"content":"partial"},"finish_reason":"length"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}"#
            : #"{"choices":[{"message":{"content":"legacy response"}}]}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

extension AIPhase1IntegrationTests {
    @Test func malformedRosterIsNotMarkedVerified() async {
        let provider = ScriptProvider(replies: [.init(content: "{}", provider: "fixture", model: "fixture")])
        await #expect(throws: LLMError.invalidSchema) {
            try await AISpeakerRoster.build(candidates: [.init(name: "hero", lineCount: 1, sample: "fixture")], provider: provider)
        }
    }
}

extension AIPhase1IntegrationTests {
    actor PausedFinishProvider: LLMProviding {
        nonisolated let identifier = "fixture"
        nonisolated let defaultModel = "fixture"
        let gate: ScanGate
        let finish: String
        var calls = 0
        init(gate: ScanGate, finish: String) { self.gate = gate; self.finish = finish }
        func generate(_ request: LLMGenerationRequest, model: String?) async throws -> LLMRawResponse {
            calls += 1
            if calls == 1 { return .init(content: #"{"action":"retrieve","query":"hero"}"#, provider: identifier, model: defaultModel) }
            await gate.suspend()
            return .init(content: finish, provider: identifier, model: defaultModel, finishReason: "stop")
        }
    }

    @Test @MainActor func obsoleteCharacterRequestCannotSaveAfterSourceChanges() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cards = AICharacterCardStore(directory: dir)
        let old = adapter(["hero old content"])
        let new = adapter(["hero new content"])
        let fields = #"{"summary":"fixture","relationships":[],"aliasCandidates":[]}"#
        let finish = String(decoding: try JSONSerialization.data(withJSONObject: ["action": "finish", "answer": fields, "citations": []] as [String: Any]), as: UTF8.self)
        let gate = ScanGate()
        let provider = PausedFinishProvider(gate: gate, finish: finish)
        let service = AIAssistantService(store: .init(directory: dir.appendingPathComponent("index")), provider: provider, cards: cards, diagnosticOrigin: .testFixture)
        let request = Task { try await service.characterCard(name: "hero", bookID: bookID, adapter: old, boundary: end(old)) }
        await gate.waitForStart()
        service.activate(new)
        await gate.release()
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(cards.profiles(forBook: bookID).isEmpty)
    }

    @Test func requiredCharacterFieldTypesAreValidated() {
        for answer in [#"{"summary":4,"relationships":[],"aliasCandidates":[]}"#,
                       #"{"summary":"valid","relationships":"wrong","aliasCandidates":[]}"#,
                       #"{"summary":"","relationships":[],"aliasCandidates":[]}"#] {
            #expect(throws: LLMError.invalidSchema) {
                try AICharacterProfile.parse(fromAnswer: answer, name: "hero", gatheredChunkIDs: [], provider: "fixture", model: "fixture")
            }
        }
    }
}
