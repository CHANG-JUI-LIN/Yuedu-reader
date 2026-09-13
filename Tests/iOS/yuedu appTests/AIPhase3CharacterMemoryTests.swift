import Foundation
import Testing
@testable import yuedu_app

@Suite("AI Phase 3 character memory (testFixture)", .serialized)
struct AIPhase3CharacterMemoryTests {
    let book = UUID()
    func source(_ texts: [String?], spine: Int? = nil, offset: Int? = nil) -> AIBookContentAdapter {
        let i = spine ?? max(0, texts.count - 1)
        return AIBookContentAdapter(bookID: book, chapters: texts.indices.map { .init(index: $0, title: "Fixture \($0)", content: "") }) { texts[$0] }
            .atReadingPosition(spine: i, renderedOffset: offset ?? (texts[i]?.utf16.count ?? 0), renderedText: texts[i] ?? "")
    }
    func plan(_ source: AIBookContentAdapter, budget: AIMemoryBudget = .init(), whole: Bool = true) throws -> AIMemoryJob {
        try AIMemoryPlanner.plan(source: source, boundary: source.boundary(wholeBook: whole), provider: "memory-mock", model: "scripted-fixture", budget: budget)
    }
    func temporary() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("memory-fixture-\(UUID())") }
    static func payload(_ request: LLMGenerationRequest) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(request.messages.last!.content.utf8)) as? [String: Any])
    }
    /// Only the external model is scripted. Source selection, evidence validation,
    /// request accounting, persistence and scope projection are production code.
    static func response(_ request: LLMGenerationRequest) throws -> LLMRawResponse {
        let data = try payload(request)
        let segments = data["segments"] as! [[String: Any]]
        let background = data["background"] as! [[String: Any]]
        var mentions: [[String: Any]] = [], facts: [[String: Any]] = [], aliases: [[String: Any]] = []
        for segment in segments where segment["primary"] as? Bool == true {
            let text = segment["text"] as! String, id = segment["id"] as! String
            let regex = try NSRegularExpression(pattern: "蒙面人|柳青|人物[0-9]+")
            let names = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { String(text[Range($0.range, in: text)!]) }
            for name in Set(names).sorted() {
                let reference = "m\(mentions.count)"
                let proof: [String: Any] = ["segmentID": id, "quote": text]
                mentions.append(["id": reference, "surface": name, "type": "person", "unresolved": name == "蒙面人", "evidence": proof])
                let kind = text.contains("謊稱") ? "statement" : text.contains("傳聞") ? "rumor" : text.contains("其實未死") ? "correction" : "narration"
                facts.append(["entities": [reference], "kind": kind, "text": text, "evidence": [proof]])
                if text.contains("就是柳青"), let earlier = background.first(where: { $0["surface"] as? String == "蒙面人" }) {
                    aliases.append(["first": reference, "second": earlier["reference"]!, "evidence": [proof]])
                }
            }
        }
        let json = try JSONSerialization.data(withJSONObject: ["complete": true, "mentions": mentions, "facts": facts, "aliases": aliases], options: [.sortedKeys])
        return .init(content: String(decoding: json, as: UTF8.self), provider: "memory-mock", model: "scripted-fixture", finishReason: "stop")
    }
    actor Provider: LLMProviding {
        let identifier = "memory-mock", defaultModel = "scripted-fixture"
        var requests: [LLMGenerationRequest] = []
        var failures: [LLMError]
        init(_ failures: [LLMError] = []) { self.failures = failures }
        func generate(_ request: LLMGenerationRequest, model: String?) async throws -> LLMRawResponse {
            requests.append(request)
            if !failures.isEmpty { throw failures.removeFirst() }
            return try AIPhase3CharacterMemoryTests.response(request)
        }
    }
    func record(_ source: AIBookContentAdapter, _ job: AIMemoryJob, index: Int = 0, previous: [AIMemoryRecord] = []) throws -> AIMemoryRecord {
        let input = try AIMemoryExtraction.input(unit: job.units[index], source: source, job: job, previous: previous)
        return try AIMemoryExtraction.validate(raw: Self.response(input.request), input: input, source: source)
    }

    @Test @MainActor func consentProposalIsReadOnlyAndScopeIsFixedWithMissingCoverage() async throws {
        let source = source(["人物1在書信中被提及。", nil, "人物2在遠處。"], spine: 0)
        let dir = temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = AICharacterMemoryStore(directory: dir), provider = Provider()
        let service = AICharacterMemoryService(store: store, provider: provider, origin: .testFixture)
        let proposal = try service.prepare(source: source, wholeBook: false, budget: .init())
        #expect(await provider.requests.isEmpty)
        #expect(try await store.load(book: book) == nil)
        #expect(proposal.units.count == 1)
        try await service.start(confirmed: proposal, source: source); await service.wait(book: book)
        #expect(await provider.requests.count == 1)
        #expect(service.jobs[book]?.state == .completedAvailable)
        let whole = try plan(source)
        let coverage = try await service.coverage(job: whole, source: source)
        #expect(whole.targetChapters == 3 && coverage.availableChapters == 2)
        #expect(coverage.missing.count == 1 && coverage.committedUnits == 1)
    }

    @Test func longUnicodeChapterCoversEveryPrimaryCharacterWithoutOverlap() throws {
        let text = String(repeating: "𠮷👩🏽‍🚀e\u{301}人物1在信裡被提及。\n", count: 400)
        let source = source([text]), job = try plan(source)
        #expect(job.units.count > 2)
        #expect(job.units.compactMap { $0.primary.text(in: source) }.joined() == text)
        #expect(job.units.reduce(0) { $0 + $1.primary.end - $1.primary.start } == text.utf16.count)
        for (index, unit) in job.units.enumerated() {
            #expect(unit.primary.text(in: source) != nil)
            if index > 0 { #expect(job.units[index - 1].primary.end == unit.primary.start); #expect(unit.auxiliary != nil) }
        }
    }

    @Test func prefixAndUnmappedPositionNeverBorrowUnreadText() throws {
        let prefix = "人物1拿起𠮷👩🏽‍🚀銅鑰匙。"
        let source = source([prefix + "UNREAD_REVEAL"], offset: prefix.utf16.count)
        let job = try plan(source, whole: false)
        #expect(job.units.compactMap { $0.primary.text(in: source) }.joined() == prefix)
        let unmapped = source.atReadingPosition(spine: 0, renderedOffset: 5, renderedText: "unknown mapping")
        #expect(try plan(unmapped, whole: false).units.isEmpty)
    }

    @Test func sameBatchLaterUnderstandingCannotUseEarlyCitationAtMidpoint() throws {
        let text = "蒙面人到了。" + String(repeating: "風在吹。", count: 30) + "蒙面人就是柳青。"
        let source = source([text]), job = try plan(source)
        let input = try AIMemoryExtraction.input(unit: job.units[0], source: source, job: job, previous: [])
        let raw = LLMRawResponse(content: #"{"complete":true,"mentions":[{"id":"m","surface":"蒙面人","type":"person","unresolved":true,"evidence":{"segmentID":"s0","quote":"蒙面人到了。"}}],"facts":[],"aliases":[]}"#, provider: "mock", model: "mock")
        let value = try AIMemoryExtraction.validate(raw: raw, input: input, source: source)
        #expect(value.mentions[0].evidence.span.end == "蒙面人到了。".utf16.count)
        #expect(value.safeAfter.utf16 == text.utf16.count)
        let early = source.atReadingPosition(spine: 0, renderedOffset: 10, renderedText: text).boundary()
        #expect(AIMemoryProjection.make(records: [value], decisions: [], source: source, boundary: early).cards.isEmpty)
    }

    @Test(arguments: ["badID", "mismatch", "repeat", "overlap", "length", "empty", "schema", "incomplete", "nonperson"])
    func invalidOutputsNeverBecomeRecords(kind: String) throws {
        let source = source([kind == "overlap" ? "人人人" : "人物1。人物1。"]), job = try plan(source)
        let input = try AIMemoryExtraction.input(unit: job.units[0], source: source, job: job, previous: [])
        var json: [String: Any] = ["complete": true, "mentions": [["id": "m", "surface": kind == "overlap" ? "人人" : "人物1", "type": kind == "nonperson" ? "place" : "person", "unresolved": false,
            "evidence": ["segmentID": kind == "badID" ? "forged" : "s0", "quote": kind == "mismatch" ? "人物1走了。" : kind == "repeat" ? "人物1" : kind == "overlap" ? "人人" : "人物1。人物1。"]]], "facts": [], "aliases": []]
        if kind == "incomplete" { json["complete"] = false }
        var content = String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
        if kind == "empty" { content = " " }; if kind == "schema" { content = "{}" }
        let raw = LLMRawResponse(content: content, provider: "mock", model: "mock", finishReason: kind == "length" ? "length" : "stop")
        #expect(throws: (any Error).self) { try AIMemoryExtraction.validate(raw: raw, input: input, source: source) }
    }

    @Test func sameNameAndSimilarEventsStayDistinctAndAllFactKindsPersist() throws {
        let source = source(["人物1謊稱殺了別人。", "人物1傳聞已死。", "人物1其實未死。"]), job = try plan(source)
        let records = try job.units.indices.map { try record(source, job, index: $0) }
        let view = AIMemoryProjection.make(records: records, decisions: [], source: source, boundary: source.boundary())
        #expect(view.count == 3)
        #expect(Set(view.cards.flatMap(\.facts).map(\.kind)) == [.statement, .rumor, .correction])
        #expect(view.cards.allSatisfy { $0.earliest?.evidence.citation(source: source)?.coordinateUnit == "sourceUTF16" })
    }

    @Test @MainActor func successfulLedgerIsIdempotentAndSurvivesCheckpointAfterCommit() async throws {
        let source = source(["人物1走過橋。"]), dir = temporary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AICharacterMemoryStore(directory: dir)
        var job = try plan(source); job.calls = 1; job.inFlightUnitID = job.units[0].id
        try await store.create(job)
        let value = try record(source, job)
        try await store.commit(value, job: job); try await store.commit(value, job: job)
        let reopened = AICharacterMemoryStore(directory: dir)
        let loaded = try #require(try await reopened.load(book: book))
        #expect(loaded.calls == 1 && loaded.inFlightUnitID == nil)
        #expect(try await reopened.view(book: book, source: source, boundary: source.boundary()).count == 1)
        let provider = Provider()
        let service = AICharacterMemoryService(store: reopened, provider: provider, origin: .testFixture)
        try await service.resume(source: source, acknowledgeUnknown: false); await service.wait(book: book)
        #expect(await provider.requests.isEmpty)
        #expect(service.jobs[book]?.state == .completedAvailable)
    }

    @Test @MainActor func reservedAttemptSurvivesRestartAndRequiresExplicitAcknowledgement() async throws {
        let source = source(["人物1走過橋。"]), dir = temporary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AICharacterMemoryStore(directory: dir)
        var job = try plan(source); job.calls = 1; job.inFlightUnitID = job.units[0].id; job.state = .running
        try await store.create(job)
        let provider = Provider(), service = AICharacterMemoryService(store: AICharacterMemoryStore(directory: dir), provider: provider, origin: .testFixture)
        try await service.load(source: source)
        #expect(service.jobs[book]?.state == .resultUnknown)
        do { try await service.resume(source: source, acknowledgeUnknown: false); Issue.record("Unknown request resumed without acknowledgement") }
        catch { #expect(error as? AIMemoryFailure == .resultUnknown) }
        #expect(await provider.requests.isEmpty)
        try await service.resume(source: source, acknowledgeUnknown: true); await service.wait(book: book)
        #expect(service.jobs[book]?.calls == 2 && service.coverages[book]?.committedUnits == 1)
    }

    @Test func realDiskFailureDoesNotAdvanceCommittedCoverage() async throws {
        let source = source(["人物1走過橋。"]), dir = temporary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AICharacterMemoryStore(directory: dir), job = try plan(source)
        try await store.create(job)
        _ = try await store.validatedRecords(job: job, source: source)
        let file = dir.appendingPathComponent("\(book.uuidString)/records/\(job.units[0].id).json")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let value = try record(source, job)
        do { try await store.commit(value, job: job); Issue.record("Expected actual disk failure") } catch {}
        #expect(try await store.validatedRecords(job: job, source: source).isEmpty)
        try FileManager.default.removeItem(at: file)
        try await store.commit(value, job: job)
        #expect(try await AICharacterMemoryStore(directory: dir).validatedRecords(job: job, source: source).count == 1)
    }

    @Test @MainActor func lengthSplitIsOptInBoundedAndSharesTotalBudget() async throws {
        let source = source([String(repeating: "風徐徐吹過。", count: 40)]), dir = temporary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let provider = Provider([.incompleteOutput]), store = AICharacterMemoryStore(directory: dir)
        let service = AICharacterMemoryService(store: store, provider: provider, origin: .testFixture)
        var budget = AIMemoryBudget(); budget.maximumCalls = 2; budget.automaticSplitDepth = 1
        try await service.start(confirmed: plan(source, budget: budget), source: source); await service.wait(book: book)
        #expect(service.jobs[book]?.state == .budgetPaused && service.jobs[book]?.calls == 2)
        #expect(service.coverages[book]?.plannedUnits == 2 && service.coverages[book]?.committedUnits == 1)
        try await service.resume(source: source, acknowledgeUnknown: false, additionalCalls: 1); await service.wait(book: book)
        #expect(service.jobs[book]?.calls == 3 && service.jobs[book]?.state == .completedAvailable)
        #expect(service.coverages[book]?.committedUTF16 == source.chunkSections[0].text.utf16.count)
    }

    @Test @MainActor func defaultFailureDoesNotAutomaticallyRetryAndManualSplitNeedsBudget() async throws {
        let source = source(["人物1走過橋。人物2看著河流。"]), dir = temporary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let provider = Provider([.incompleteOutput]), service = AICharacterMemoryService(store: .init(directory: dir), provider: provider, origin: .testFixture)
        var budget = AIMemoryBudget(); budget.maximumCalls = 1
        try await service.start(confirmed: plan(source, budget: budget), source: source); await service.wait(book: book)
        #expect(service.jobs[book]?.state == .failed && service.coverages[book]?.committedUnits == 0)
        #expect(await provider.requests.count == 1)
        try await service.splitFailed(source: source)
        do { try await service.resume(source: source, acknowledgeUnknown: false); Issue.record("Budget silently reset") }
        catch { #expect(error as? AIMemoryFailure == .budget) }
    }

    @Test func appendReusesIdentityButEarlierEditFillAndConfigurationInvalidate() throws {
        let initial = source(["人物1前行。", nil, "人物2遠行。"]), old = try plan(initial)
        let records = try old.units.indices.map { try record(initial, old, index: $0) }
        let append = source(["人物1前行。", nil, "人物2遠行。", "人物3來了。"]), appended = try plan(append)
        #expect(records.allSatisfy { AIMemoryPlanner.matches($0, source: append, job: appended) })
        let edit = source(["人物1後退。", nil, "人物2遠行。"]), edited = try plan(edit)
        #expect(records.allSatisfy { !AIMemoryPlanner.matches($0, source: edit, job: edited) })
        let fill = source(["人物1前行。", "人物4原來在此。", "人物2遠行。"]), filled = try plan(fill)
        #expect(AIMemoryPlanner.matches(records[0], source: fill, job: filled))
        #expect(!AIMemoryPlanner.matches(records[1], source: fill, job: filled))
        let version = try AIMemoryPlanner.plan(source: initial, boundary: initial.boundary(), provider: old.provider, model: old.model, analysisVersion: "next")
        #expect(!AIMemoryPlanner.matches(records[0], source: initial, job: version))
        var budget = AIMemoryBudget(); budget.maximumBackgroundRecords = 1
        #expect(!AIMemoryPlanner.matches(records[0], source: initial, job: try plan(initial, budget: budget)))
    }

    @Test func backgroundIsBoundedAndNeverReadsLaterRecords() throws {
        let source = source(["蒙面人走過橋。", "蒙面人在船上。", "蒙面人就是柳青。"]), job = try plan(source)
        let early = try record(source, job), late = try record(source, job, index: 2, previous: [early])
        let input = try AIMemoryExtraction.input(unit: job.units[1], source: source, job: job, previous: [early, late])
        #expect(input.background.count == 1 && input.background[0].recordID == early.unit.id)
        #expect(!input.request.messages.last!.content.contains("柳青"))
        #expect(input.safeAfter == job.units[1].primary.endPosition)
    }

    @Test func missingBackgroundDependencyInvalidatesDescendant() async throws {
        let source = source(["蒙面人走過橋。", "蒙面人就是柳青。"]), job = try plan(source), dir = temporary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AICharacterMemoryStore(directory: dir)
        try await store.create(job)
        let first = try record(source, job), second = try record(source, job, index: 1, previous: [first])
        try await store.commit(second, job: job)
        #expect(try await store.validatedRecords(job: job, source: source).isEmpty)
        try await store.commit(first, job: job)
        #expect(try await store.validatedRecords(job: job, source: source).count == 2)
    }

    @Test @MainActor func staleJobCannotCommitAndClearOnlyRemovesThisBookMemory() async throws {
        let source = source(["人物1走過橋。"]), dir = temporary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AICharacterMemoryStore(directory: dir), old = try plan(source), newer = try plan(source)
        try await store.create(old); try await store.create(newer)
        do { try await store.commit(record(source, old), job: old); Issue.record("Stale job published") }
        catch { #expect(error as? AIMemoryFailure == .sourceChanged) }
        try await store.commit(record(source, newer), job: newer)
        let unrelated = dir.appendingPathComponent("other-book"); try Data("preserved".utf8).write(to: unrelated)
        let service = AICharacterMemoryService(store: store, provider: Provider(), origin: .testFixture)
        try await service.clear(book: book)
        #expect(try await store.load(book: book) == nil)
        #expect(try String(contentsOf: unrelated, encoding: .utf8) == "preserved")
    }

    @Test @MainActor func everyCharacterHasLocalCardsAndPagingNeedsNoAdditionalModelCalls() async throws {
        let source = source((0..<85).map { "人物\($0)在一封書信裡被提及。" }), dir = temporary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let provider = Provider(), service = AICharacterMemoryService(store: .init(directory: dir), provider: provider, origin: .testFixture)
        try await service.start(confirmed: plan(source), source: source); await service.wait(book: book)
        let view = try await service.view(source: source, boundary: source.boundary())
        #expect(view.count == 85)
        #expect(view.page().count == 40 && view.page(offset: 40).count == 40 && view.page(offset: 80).count == 5)
        #expect(view.cards.allSatisfy { !$0.facts.isEmpty && $0.earliest != nil })
        #expect(await provider.requests.count == 85)
    }

    @Test @MainActor func hundredsOfChaptersResumeIncrementAndScopeWithoutFutureIdentity() async throws {
        var texts: [String?] = (0..<650).map { "合成章節\($0 + 1)：風從空谷吹過。" }
        texts[39] = "蒙面人交出一封書信後離開。"
        texts[619] = "蒙面人就是柳青，今天終於揭下了面罩。"
        let source = source(texts), dir = temporary(), started = Date()
        defer { try? FileManager.default.removeItem(at: dir) }
        let provider = Provider()
        var budget = AIMemoryBudget(); budget.maximumCalls = 39
        var service = AICharacterMemoryService(store: .init(directory: dir), provider: provider, origin: .testFixture)
        try await service.start(confirmed: plan(source, budget: budget), source: source); await service.wait(book: book)
        #expect(service.jobs[book]?.calls == 39)
        AIDiagnosticStore.shared.captureNextRequestContent = true
        try await service.resume(source: source, acknowledgeUnknown: false, additionalCalls: 1); await service.wait(book: book)
        let earlyTrace = try #require(AIDiagnosticStore.shared.latest).export(including: ["messages", "response", "evidence"])
        service = AICharacterMemoryService(store: .init(directory: dir), provider: provider, origin: .testFixture)
        try await service.resume(source: source, acknowledgeUnknown: false, additionalCalls: 579); await service.wait(book: book)
        #expect(service.jobs[book]?.calls == 619 && service.coverages[book]?.committedUnits == 619)
        AIDiagnosticStore.shared.captureNextRequestContent = true
        try await service.resume(source: source, acknowledgeUnknown: false, additionalCalls: 1); await service.wait(book: book)
        let revealTrace = try #require(AIDiagnosticStore.shared.latest).export(including: ["messages", "response", "evidence"])
        service = AICharacterMemoryService(store: .init(directory: dir), provider: provider, origin: .testFixture)
        try await service.resume(source: source, acknowledgeUnknown: false, additionalCalls: 30); await service.wait(book: book)
        #expect(service.jobs[book]?.state == .completedAvailable && service.coverages[book]?.committedUnits == 650)
        let safeSource = source.atReadingPosition(spine: 499, renderedOffset: texts[499]!.utf16.count, renderedText: texts[499]!)
        let lateBoundary = source.boundary()
        let late = try await service.view(source: source, boundary: lateBoundary)
        #expect(late.count == 3 && late.aliases.count == 2)
        for alias in late.aliases { try await service.decide(alias: alias, approved: true, source: source, boundary: lateBoundary) }
        let trace = AIRequestTrace(feature: "characterMemoryScopeFixture", bookID: book, adapter: source, boundary: safeSource.boundary(), origin: .testFixture)
        let safe = try await AIDiagnostics.$current.withValue(trace) { try await service.view(source: source, boundary: safeSource.boundary()) }
        let merged = try await AIDiagnostics.$current.withValue(trace) { try await service.view(source: source, boundary: lateBoundary) }
        #expect(safe.count == 1 && safe.lookup("柳青").isEmpty && safe.aliases.isEmpty)
        #expect(safe.cards[0].names == ["蒙面人"] && safe.cards[0].earliest?.evidence.span.spine == 39)
        #expect(safe.cards[0].facts.allSatisfy { !$0.text.contains("柳青") })
        #expect(merged.count == 1 && merged.cards[0].names == ["柳青", "蒙面人"])
        for alias in late.aliases { try await service.decide(alias: alias, approved: false, source: source, boundary: lateBoundary) }
        #expect(try await service.view(source: source, boundary: lateBoundary).count == 3)
        let extended = self.source(texts + ["人物9在新章登場。", "人物8在信裡出現。"])
        let extendedJob = try plan(extended)
        #expect(try await service.coverage(job: extendedJob, source: extended).committedUnits == 650)
        try await service.start(confirmed: extendedJob, source: extended); await service.wait(book: book)
        #expect(await provider.requests.count == 652)
        #expect(service.jobs[book]?.calls == 2 && service.coverages[book]?.committedUnits == 652)
        let snapshot: [String: Any] = ["origin": "testFixture", "externalModel": "mock", "chapters": 652, "storeInstances": 3,
            "characters": extended.chunkSections.reduce(0) { $0 + $1.text.count }, "utf16": extended.chunkSections.reduce(0) { $0 + $1.text.utf16.count },
            "bytes": extended.chunkSections.reduce(0) { $0 + $1.text.utf8.count }, "savedUnits": service.coverages[book]!.committedUnits,
            "calls": await provider.requests.count, "elapsedMilliseconds": Date().timeIntervalSince(started) * 1000,
            "traces": [try JSONSerialization.jsonObject(with: earlyTrace), try JSONSerialization.jsonObject(with: revealTrace), try JSONSerialization.jsonObject(with: trace.export())]]
        print("PHASE3_TRACE_BASE64 " + (try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys])).base64EncodedString())
    }

    @Test func diagnosticsDoNotCaptureSensitiveMemoryByDefault() async throws {
        let source = source(["人物1私下交出秘密信件。"]), job = try plan(source)
        let trace = AIRequestTrace(feature: "characterMemory", bookID: book, adapter: source, boundary: source.boundary(), origin: .testFixture)
        _ = try await AIDiagnostics.$current.withValue(trace) {
            let input = try AIMemoryExtraction.input(unit: job.units[0], source: source, job: job, previous: [])
            let raw = try await AITracedProvider(base: Provider()).generate(input.request)
            return try AIMemoryExtraction.validate(raw: raw, input: input, source: source)
        }
        let export = String(decoding: try trace.export(including: ["messages", "response", "evidence"]), as: UTF8.self)
        #expect(!export.contains("人物1") && !export.contains("秘密信件"))
        #expect(export.contains("unavailableContentCategories"))
    }
    actor HeldProvider: LLMProviding {
        let identifier = "memory-mock", defaultModel = "scripted-fixture"
        var request: LLMGenerationRequest?
        var pending: CheckedContinuation<LLMRawResponse, any Error>?
        var observer: CheckedContinuation<Void, Never>?
        var held = false
        func started() async {
            if held { return }
            await withCheckedContinuation { observer = $0 }
        }
        func generate(_ value: LLMGenerationRequest, model: String?) async throws -> LLMRawResponse {
            if held { return try AIPhase3CharacterMemoryTests.response(value) }
            request = value; held = true
            return try await withCheckedThrowingContinuation { pending = $0; observer?.resume(); observer = nil }
        }
        func finish() throws {
            pending?.resume(returning: try AIPhase3CharacterMemoryTests.response(request!)); pending = nil
        }
    }

    @Test @MainActor func lateCancelledReplyCannotOverwriteResumedBudgetOrRecords() async throws {
        let source = source(["人物1在橋上。"]), dir = temporary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let provider = HeldProvider(), store = AICharacterMemoryStore(directory: dir)
        let service = AICharacterMemoryService(store: store, provider: provider, origin: .testFixture)
        try await service.start(confirmed: plan(source), source: source)
        await provider.started()
        let draining = service.pause(book: book)
        #expect(service.jobs[book]?.state == .resultUnknown)
        try await service.resume(source: source, acknowledgeUnknown: true, additionalCalls: 2)
        await service.wait(book: book)
        try await provider.finish(); await draining?.value
        let loaded = try #require(try await store.load(book: book))
        #expect(loaded.calls == 2 && loaded.budget.maximumCalls == 102 && loaded.state == .completedAvailable)
        #expect(try await store.validatedRecords(job: loaded, source: source).count == 1)
    }

    @Test @MainActor func networkFailureRetainsPossibleBillingAndNoAutomaticRetry() async throws {
        let source = source(["人物1在橋上。"]), dir = temporary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let provider = Provider([.networkError("fixture disconnect")])
        let service = AICharacterMemoryService(store: .init(directory: dir), provider: provider, origin: .testFixture)
        try await service.start(confirmed: plan(source), source: source); await service.wait(book: book)
        #expect(service.jobs[book]?.state == .resultUnknown && service.jobs[book]?.inFlightUnitID != nil)
        #expect(service.coverages[book]?.committedUnits == 0 && service.jobs[book]?.calls == 1)
        #expect(await provider.requests.count == 1)
    }

    @Test @MainActor func existingChatCardsRosterAndManualVoicesRemainIsolated() async throws {
        let source = source(["蒙面人出現。", "蒙面人就是柳青。"]), dir = temporary()
        let name = "memory-isolation-\(UUID())", defaults = UserDefaults(suiteName: name)!
        defer { try? FileManager.default.removeItem(at: dir); defaults.removePersistentDomain(forName: name) }
        let chats = AIChatStore(defaults: defaults), cards = AICharacterCardStore(directory: dir.appendingPathComponent("legacy-cards"))
        let roster = AISpeakerRosterStore(defaults: defaults)
        let session = AIChatSession(messages: [.init(role: .user, text: "Existing conversation")])
        chats.save(session, forBook: book)
        let profile = AICharacterProfile(name: "Manual", firstAppearance: nil, role: nil, relationships: [], aliasCandidates: ["Alias"], summary: "Existing profile", citationChunkIDs: [], provider: "manual", model: "none", promptVersion: "legacy")
        cards.upsert(profile, forBook: book)
        roster.save(["Manual": "Manual"], forBook: book, boundary: source.boundary())
        defaults.set(TTSRoleVoiceCast.setting(voiceIdentifier: "system:manual", forSpeaker: "Manual", bookID: book, in: [:]), forKey: "manual-cast")
        let before = defaults.persistentDomain(forName: name)! as NSDictionary
        let service = AICharacterMemoryService(store: .init(directory: dir.appendingPathComponent("memory")), provider: Provider(), origin: .testFixture)
        try await service.start(confirmed: plan(source), source: source); await service.wait(book: book)
        let view = try await service.view(source: source, boundary: source.boundary())
        for alias in view.aliases { try await service.decide(alias: alias, approved: true, source: source, boundary: source.boundary()) }
        #expect(roster.safeRoster(forBook: book, boundary: source.boundary())["蒙面人"] == nil)
        #expect(cards.aliasMap(forBook: book, boundary: source.boundary())["蒙面人"] == nil)
        try await service.clear(book: book)
        #expect(chats.sessions(forBook: book).first?.id == session.id)
        #expect(cards.profiles(forBook: book) == [profile])
        #expect((defaults.persistentDomain(forName: name)! as NSDictionary) == before)
    }

    @Test @MainActor func concurrentResumeReservesOneActivationAndOneBudgetIncrease() async throws {
        let source = source(["人物1在橋上。"]), dir = temporary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AICharacterMemoryStore(directory: dir), provider = Provider()
        let service = AICharacterMemoryService(store: store, provider: provider, origin: .testFixture)
        try await store.create(plan(source))
        async let first: Void = service.resume(source: source, acknowledgeUnknown: false, additionalCalls: 1)
        async let second: Void = service.resume(source: source, acknowledgeUnknown: false, additionalCalls: 1)
        _ = try await (first, second)
        await service.wait(book: book)
        #expect(await provider.requests.count == 1)
        #expect(service.jobs[book]?.budget.maximumCalls == 101 && service.jobs[book]?.calls == 1)
    }

    @Test @MainActor func cancelledLaunchAndResumeNeverStartModelCalls() async throws {
        let source = source(["人物1在橋上。"]), dir = temporary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AICharacterMemoryStore(directory: dir), provider = Provider()
        let service = AICharacterMemoryService(store: store, provider: provider, origin: .testFixture)
        let job = try plan(source)
        let launch = Task { try await service.start(confirmed: job, source: source) }
        launch.cancel()
        do { try await launch.value; Issue.record("Cancelled launch proceeded") } catch { #expect(error is CancellationError) }
        #expect(try await store.load(book: book) == nil)
        try await store.create(job)
        let resume = Task { try await service.resume(source: source, acknowledgeUnknown: false) }
        resume.cancel()
        do { try await resume.value; Issue.record("Cancelled resume proceeded") } catch { #expect(error is CancellationError) }
        #expect(await provider.requests.isEmpty)
        #expect(try await store.load(book: book)?.calls == 0)
    }

}
