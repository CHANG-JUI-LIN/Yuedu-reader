import Foundation
import Testing
@testable import yuedu_app

@Suite("AI book and volume summaries", .serialized)
struct AIBookSummaryTests {

    // MARK: - Volumes

    @Test("volume headings in titles group the chapters after them")
    func titleHeadingsGroupChapters() {
        let volumes = AIBookVolumes.volumes(
            titles: ["楔子", "第一卷 風起", "第1章 初見", "第2章 離家", "第二卷 雲湧", "第3章 入門"],
            levels: Array(repeating: 0, count: 6))
        #expect(volumes.map(\.chapters) == [0...0, 1...3, 4...5])
        #expect(volumes.map(\.title) == [nil, "第一卷 風起", "第二卷 雲湧"])
    }

    @Test("a nested table of contents groups by its top-level parents only")
    func nestedContentsGroupByTopParents() {
        let parts = AIBookVolumes.volumes(titles: ["Part One", "Ch 1", "Ch 2", "Part Two", "Ch 3"], levels: [0, 1, 1, 0, 1])
        #expect(parts.map(\.chapters) == [0...2, 3...4])
        // A chapter with sections under it is not a volume when there are parts above it.
        let deep = AIBookVolumes.volumes(titles: ["Part", "Ch 1", "Section", "Ch 2"], levels: [0, 1, 2, 1])
        #expect(deep.map(\.chapters) == [0...3])
    }

    @Test("a book without headings is cut into fixed stretches")
    func noHeadingsMeansStretches() {
        let volumes = AIBookVolumes.volumes(titles: (1...120).map { "第\($0)章" }, levels: Array(repeating: 0, count: 120))
        #expect(volumes.map(\.chapters) == [0...49, 50...99, 100...119])
        #expect(volumes.allSatisfy { $0.title == nil })
    }

    // MARK: - Splitting

    @Test("long chapters split within the limit, after a line break, never inside a character")
    func splitRespectsLimitAndCharacters() {
        let line = "他抬頭望向遠方的山。👩🏽‍🚀\n"
        let text = String(repeating: line, count: 40)
        let ranges = AIBookSummaryPlanner.split(text, throughUTF16: text.utf16.count, maximum: 100)
        #expect(ranges.first?.lowerBound == 0)
        #expect(ranges.last?.upperBound == text.utf16.count)
        for (previous, next) in zip(ranges, ranges.dropFirst()) { #expect(previous.upperBound == next.lowerBound) }
        #expect(ranges.allSatisfy { $0.count <= 100 })
        for range in ranges {
            // Every cut lands on a character boundary and, here, right after a line break.
            let substring = Range(NSRange(location: range.lowerBound, length: range.count), in: text).map { String(text[$0]) }
            #expect(substring?.hasSuffix("\n") == true)
        }
    }

    // MARK: - Planning

    @Test("the plan covers read chapters with local text, up to the reading position")
    func planStopsAtTheReadingPosition() {
        let source = adapter(texts: ["第一章正文。", nil, "第三章正文，讀到一半。後面還沒讀。", "第四章還沒讀。"], readingAt: (2, 11))
        let plan = AIBookSummaryPlanner.plan(source: source, record: AIBookSummaryRecord(), language: .traditionalChinese)
        let parts = plan.batches.flatMap(\.parts)
        #expect(parts.map(\.order) == [0, 2])
        #expect(parts.last?.end == 11)
        #expect(plan.missingChapters == [1])
        #expect(plan.throughChapter == 2)
        #expect(!plan.isUpToDate)
    }

    @Test("stored digests are reused, and a chapter read further is digested again")
    func planReusesDigestsUntilReadFurther() {
        let texts: [String?] = ["第一章正文。", "第二章正文，後面還有。"]
        let source = adapter(texts: texts, readingAt: (1, 5))
        var record = AIBookSummaryRecord()
        for part in AIBookSummaryPlanner.plan(source: source, record: record, language: .traditionalChinese).batches.flatMap(\.parts) {
            record.digests[part.order] = AIChapterDigest(order: part.order, title: nil, sourceDigest: source.manifest.chapters[part.order].digest!,
                endUTF16: part.end, promptVersion: AIBookSummaryPlanner.recipe(.traditionalChinese), text: "摘要")
        }
        #expect(AIBookSummaryPlanner.plan(source: source, record: record, language: .traditionalChinese).batches.isEmpty)
        let further = adapter(texts: texts, readingAt: (1, 9))
        let next = AIBookSummaryPlanner.plan(source: further, record: record, language: .traditionalChinese)
        #expect(next.batches.flatMap(\.parts).map(\.order) == [1])
    }

    /// Digests are written in the reader's language. After a switch of interface language the
    /// old ones are redone rather than mixed into a summary in the new language.
    @Test("a digest in another language counts as missing")
    func planRedoesDigestsInAnotherLanguage() {
        let source = adapter(texts: ["第一章正文。", "第二章正文。"], readingAt: (1, 6))
        var record = AIBookSummaryRecord()
        for part in AIBookSummaryPlanner.plan(source: source, record: record, language: .traditionalChinese).batches.flatMap(\.parts) {
            record.digests[part.order] = AIChapterDigest(order: part.order, title: nil, sourceDigest: source.manifest.chapters[part.order].digest!,
                endUTF16: part.end, promptVersion: AIBookSummaryPlanner.recipe(.traditionalChinese), text: "摘要")
        }
        #expect(AIBookSummaryPlanner.plan(source: source, record: record, language: .traditionalChinese).batches.isEmpty)
        let switched = AIBookSummaryPlanner.plan(source: source, record: record, language: .simplifiedChinese)
        #expect(switched.batches.flatMap(\.parts).map(\.order) == [0, 1])
        #expect(AIBookSummaryPrompt.inputDigest(["甲"], language: .traditionalChinese)
            != AIBookSummaryPrompt.inputDigest(["甲"], language: .simplifiedChinese))
    }

    @Test("digests and summaries are written in the reader's language, not the book's")
    func promptsNameTheReadersLanguage() {
        #expect(AIBookSummaryPrompt.digestSystem(.simplifiedChinese).contains("用簡體中文寫"))
        #expect(AIBookSummaryPrompt.reduceSystem(scope: "全書", language: .english).contains("全文用英文寫"))
        for system in [AIBookSummaryPrompt.digestSystem(.english), AIBookSummaryPrompt.reduceSystem(scope: "全書", language: .english)] {
            #expect(!system.contains("正文使用的語言"))
            #expect(!system.contains("與摘要相同的語言"))
        }
    }

    // MARK: - Parsing

    @Test("a digest response must answer every part exactly once")
    func digestParsingIsStrict() throws {
        let batch = AIBookSummaryPlan.Batch(parts: [
            .init(order: 0, index: 0, count: 1, start: 0, end: 5),
            .init(order: 1, index: 0, count: 1, start: 0, end: 5),
        ])
        func raw(_ json: String) -> LLMRawResponse { .init(content: json, provider: "fake", model: "fake", finishReason: "stop") }
        let parsed = try AIBookSummaryPrompt.parseDigests(raw("```json\n{\"summaries\":[{\"id\":\"c0p0\",\"summary\":\"甲\"},{\"id\":\"c1p0\",\"summary\":\"乙\"}]}\n```"), batch: batch)
        #expect(parsed == ["c0p0": "甲", "c1p0": "乙"])
        #expect(throws: AIBookSummaryPrompt.Failure.invalidSchema) {
            try AIBookSummaryPrompt.parseDigests(raw("{\"summaries\":[{\"id\":\"c0p0\",\"summary\":\"甲\"}]}"), batch: batch)
        }
        #expect(throws: AIBookSummaryPrompt.Failure.invalidSchema) {
            try AIBookSummaryPrompt.parseDigests(raw("{\"summaries\":[{\"id\":\"c0p0\",\"summary\":\"甲\"},{\"id\":\"c9p0\",\"summary\":\"丙\"}]}"), batch: batch)
        }
        #expect(throws: AIBookSummaryPrompt.Failure.invalidSchema) {
            try AIBookSummaryPrompt.parseDigests(raw("{\"summaries\":[{\"id\":\"c0p0\",\"summary\":\" \"},{\"id\":\"c1p0\",\"summary\":\"乙\"}]}"), batch: batch)
        }
    }

    // MARK: - Runs

    @Test @MainActor func runBuildsDigestsVolumesAndBookThenCostsNothingUntilReadFurther() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = SummaryProvider()
        let service = AIBookSummaryService(store: AIBookSummaryStore(directory: directory), provider: provider, origin: .testFixture)
        let titles = ["第一卷 風起", "第1章", "第2章", "第二卷 雲湧", "第3章", "第4章"]
        let texts: [String?] = ["", "張若塵離開家。", "張若塵拜入師門。", "", "池瑤出場。", "兩人交手。"]

        let source = adapter(texts: texts, titles: titles, readingAt: (4, 5))
        let plan = try await service.plan(source: source)
        #expect(plan.readVolumes.map(\.id) == ["v0", "v3"])
        // The two volume title pages have no prose and are not reported as missing chapters.
        #expect(plan.missingChapters.isEmpty)
        try service.start(plan: plan, source: source)
        await service.wait(book: source.chunkBookID)
        #expect(service.runs[source.chunkBookID] == .idle)
        let record = try #require(service.records[source.chunkBookID])
        #expect(Set(record.digests.keys) == [1, 2, 4])
        #expect(Set(record.volumes.keys) == ["v0", "v3"])
        #expect(record.book != nil)
        #expect(record.callsSpent <= plan.estimatedCalls)
        #expect(await provider.calls == record.callsSpent)

        let again = try await service.plan(source: source)
        #expect(again.isUpToDate)

        let further = adapter(texts: texts, titles: titles, readingAt: (5, 4))
        let next = try await service.plan(source: further)
        #expect(next.batches.flatMap(\.parts).map(\.order) == [5])
        #expect(Set(next.volumeUpdates.keys) == ["v3"])
        #expect(next.bookCalls == 1)
    }

    @Test @MainActor func runPausesAtTheConfirmedCallCountAndKeepsWhatFinished() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = AIBookSummaryService(store: AIBookSummaryStore(directory: directory), provider: SummaryProvider(), origin: .testFixture)
        let source = adapter(texts: ["張若塵離開家。", "張若塵拜入師門。"], readingAt: (1, 4))
        let full = try await service.plan(source: source)
        // Confirmed for the digests only: the volume and book summaries must wait for a new
        // confirmation instead of being charged anyway.
        let digestsOnly = AIBookSummaryPlan(bookID: full.bookID, sourceVersion: full.sourceVersion, boundary: full.boundary,
            language: full.language, volumes: full.volumes, batches: full.batches, readEnds: full.readEnds, missingChapters: full.missingChapters,
            throughChapter: full.throughChapter, volumeUpdates: [:], bookCalls: 0)
        try service.start(plan: digestsOnly, source: source)
        await service.wait(book: source.chunkBookID)
        #expect(service.runs[source.chunkBookID] == .budgetReached)
        let record = try #require(service.records[source.chunkBookID])
        #expect(Set(record.digests.keys) == [0, 1])
        #expect(record.book == nil)
        #expect(record.callsSpent == digestsOnly.estimatedCalls)
    }

    // MARK: - Batches (maintainer, 2026-10-15: bigger batches, three at a time)

    @Test("digest batches carry up to 48K UTF-16 and 32 chapters: a long book is a quarter of the requests")
    func batchesAreLarge() {
        #expect(AIBookSummaryPlanner.batchUTF16 == 48_000)
        #expect(AIBookSummaryPlanner.batchParts == 32)
        // 100 chapters of 4,000 characters: 12 to a batch. It was 34 batches at 12K.
        let long = String(repeating: "張若塵盤膝而坐，運轉神石。", count: 4_000 / 13 + 1).prefix(4_000)
        let plan = AIBookSummaryPlanner.plan(source: adapter(texts: Array(repeating: String(long), count: 100), readingAt: (99, 4_000)),
                                             record: AIBookSummaryRecord(), language: .traditionalChinese)
        #expect(plan.batches.count == 9)
        #expect(plan.batches.allSatisfy { $0.parts.count <= 32 && $0.parts.reduce(0) { $0 + $1.end - $1.start } <= 48_000 })
        // 200 short chapters: 32 to a batch.
        let short = AIBookSummaryPlanner.plan(source: adapter(texts: Array(repeating: "短章。", count: 200), readingAt: (199, 3)),
                                              record: AIBookSummaryRecord(), language: .traditionalChinese)
        #expect(short.batches.count == 7)
    }

    @Test(.timeLimit(.minutes(1))) @MainActor func digestBatchesRunThreeAtATime() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        // The first three digest requests are held until all three have arrived: a run that
        // sent them one at a time would never get past the first.
        let provider = SummaryProvider(holdFirst: 3)
        let service = AIBookSummaryService(store: AIBookSummaryStore(directory: directory), provider: provider, origin: .testFixture)
        let source = adapter(texts: Array(repeating: "短章。", count: 200), readingAt: (199, 3))
        let plan = try await service.plan(source: source)
        #expect(plan.batches.count == 7)
        try service.start(plan: plan, source: source)
        await service.wait(book: source.chunkBookID)
        #expect(service.runs[source.chunkBookID] == .idle)
        #expect(await provider.mostInFlight == AIBookSummaryService.concurrentDigests)
        let record = try #require(service.records[source.chunkBookID])
        #expect(record.digests.count == 200)
        #expect(record.callsSpent == (await provider.calls))
    }

    @Test(.timeLimit(.minutes(1))) @MainActor func aFailedBatchStopsTheRunAndKeepsTheFinishedOnes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = SummaryProvider(failingDigestCall: 4)
        let service = AIBookSummaryService(store: AIBookSummaryStore(directory: directory), provider: provider, origin: .testFixture)
        let source = adapter(texts: Array(repeating: "短章。", count: 200), readingAt: (199, 3))
        let plan = try await service.plan(source: source)
        try service.start(plan: plan, source: source)
        await service.wait(book: source.chunkBookID)
        guard case .failed = service.runs[source.chunkBookID] else {
            Issue.record("expected the run to fail, got \(String(describing: service.runs[source.chunkBookID]))")
            return
        }
        let record = try #require(service.records[source.chunkBookID])
        #expect(!record.digests.isEmpty)
        #expect(record.digests.count < 200)
        #expect(record.book == nil)
    }

    // MARK: - Fixtures

    private func adapter(texts: [String?], titles: [String]? = nil, readingAt position: (Int, Int)) -> AIBookContentAdapter {
        let bookID = UUID(uuidString: "00000000-0000-0000-0000-0000000000B5")!
        let chapters = texts.indices.map { BookChapter(index: $0, title: titles?[$0] ?? "第\($0 + 1)章", content: "") }
        let rendered = texts[position.0] ?? ""
        return AIBookContentAdapter(bookID: bookID, chapters: chapters, readingPosition: (spine: position.0, utf16Offset: position.1),
            renderedText: rendered) { texts[$0] }
    }

    /// Answers digest requests with one summary per id, and reduce requests with a short
    /// overview, counting every call.
    private actor SummaryProvider: LLMProviding {
        let identifier = "summary-fixture"
        let defaultModel = "fixture"
        private(set) var calls = 0
        private(set) var mostInFlight = 0
        private var inFlight = 0
        private var digestCalls = 0
        private var held: [CheckedContinuation<Void, Never>] = []
        private var holdFirst: Int
        private let failingDigestCall: Int?

        init(holdFirst: Int = 0, failingDigestCall: Int? = nil) {
            self.holdFirst = holdFirst
            self.failingDigestCall = failingDigestCall
        }

        func generate(_ request: LLMGenerationRequest, model: String?) async throws -> LLMRawResponse {
            calls += 1
            inFlight += 1
            mostInFlight = max(mostInFlight, inFlight)
            defer { inFlight -= 1 }
            let isDigest = request.messages.first?.content == AIBookSummaryPrompt.digestSystem(.current)
            if isDigest {
                digestCalls += 1
                if digestCalls == failingDigestCall { throw LLMError.providerError("fixture failure") }
                if holdFirst > 0 {
                    if digestCalls < holdFirst {
                        await withCheckedContinuation { held.append($0) }
                    } else if digestCalls == holdFirst {
                        holdFirst = 0
                        held.forEach { $0.resume() }
                        held = []
                    }
                }
            }
            if isDigest,
               let data = request.messages.last?.content.data(using: .utf8),
               let payload = try JSONSerialization.jsonObject(with: data) as? [String: [[String: String]]],
               let items = payload["items"] {
                let summaries = items.compactMap { $0["id"] }.map { ["id": $0, "summary": "摘要 \($0)"] }
                let json = try JSONSerialization.data(withJSONObject: ["summaries": summaries])
                return .init(content: String(decoding: json, as: UTF8.self), provider: identifier, model: defaultModel, finishReason: "stop")
            }
            return .init(content: "總覽：張若塵踏上修行之路。\n\n關鍵人物：張若塵", provider: identifier, model: defaultModel, finishReason: "stop")
        }

        nonisolated func stream(_ request: LLMGenerationRequest, model: String?) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }
}
