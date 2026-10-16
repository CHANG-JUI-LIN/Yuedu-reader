import XCTest
@testable import yuedu_app

/// Opt-in device integration. No network calls unless an operator provisions this private
/// configuration in the app container. Never put credentials or copyrighted fixtures in Git.
final class AILiveBookVerificationTests: XCTestCase {
    private struct Configuration: Decodable {
        let apiKey: String
        let model: String
        let bookFilename: String
        let memoryCalls: Int
    }

    @MainActor func testProvisionedBookAtHalfProgress() async throws {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let configurationURL = documents.appendingPathComponent("ai-live-verification.json")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: configurationURL.path), "Explicit live verification was not provisioned")
        let configuration = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: configurationURL))
        try FileManager.default.removeItem(at: configurationURL)
        _ = AIAPIKeyStore.save(configuration.apiKey)
        AIProviderStore.shared.save(.init(endpoint: "https://api.deepseek.com/v1", defaultModel: configuration.model))
        let probe = await AIConnectionTest.run(endpoint: "https://api.deepseek.com/v1", apiKey: configuration.apiKey, model: configuration.model)
        guard case .success = probe else { XCTFail("Live provider probe failed"); return }

        var report: [String: Any] = ["model": configuration.model, "origin": "observed-simulator-integration"]
        let output = documents.appendingPathComponent("ai-live-verification-result.json")
        func saveReport() throws {
            try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
                .write(to: output, options: [.atomic, .completeFileProtection])
        }
        defer { try? saveReport() }
        let store = BookStore()
        let book = try await store.importTxt(url: documents.appendingPathComponent(configuration.bookFilename))
        report["bookID"] = book.id.uuidString
        let url = try XCTUnwrap(store.shareableFileURL(for: book))
        let preparation = try TXTReaderPreparationService.prepare(url: url, bookId: book.id, bookTitle: book.title)
        let indexes = TXTReaderPreparationService.buildChapterIndexes(for: preparation)
        try TXTChapterParser.writeCachedIndexes(indexes, bookId: book.id, fileSize: preparation.fileSize,
            fingerprint: preparation.fingerprint, encoding: preparation.encoding)
        let builder = TXTLazyAttributedStringBuilder(mappedTextFile: preparation.mappedTextFile, chapterIndexes: indexes)
        var texts: [String] = []
        for i in indexes.indices {
            let chapter = await builder.localChapterText(at: i)
            texts.append(try XCTUnwrap(chapter.text))
        }
        let total = texts.reduce(0) { $0 + $1.utf16.count }
        var offset = 0, selected = 0, nearest = Double.infinity
        for i in texts.indices {
            let distance = abs(Double(offset) / Double(total) - 0.5)
            if distance < nearest { nearest = distance; selected = i }
            offset += texts[i].utf16.count
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let rulesDigest = AISourceManifest.digest(try encoder.encode(ReplaceRuleStore.shared.rules))
        let source = AIBookContentAdapter(bookID: book.id, chapters: indexes.map { .init(index: $0.index, title: $0.title, content: "") },
            transformationVersion: "chapterPlainText.v1@rules:" + rulesDigest) { texts[$0] }
            .atReadingPosition(spine: selected, renderedOffset: 0, renderedText: texts[selected])
        let progress = source.progress(forSpine: selected, charOffset: 0)
        XCTAssertLessThan(abs(progress - 0.5), 0.005)
        await JSONFileReadingPositionStore().save(.init(spineIndex: selected, charOffset: 0), for: book.id.uuidString)
        store.updatePosition(bookId: book.id, position: progress, forceSave: true)
        report["progress"] = progress
        report["chapter"] = selected
        report["chapterTitle"] = indexes[selected].title
        report["chapters"] = indexes.count
        report["sourceFingerprint"] = source.contentFingerprint
        try saveReport()
        print("AI_LIVE imported chapters=\(indexes.count) progress=\(progress) spine=\(selected)")

        var conversation = AIChatSession()
        var turns: [[String: Any]] = []
        let question = "陳慶最初為什麼沒能跟陳恒一起去武館學武？"
        for text in [question, question, "剛剛發生了什麼？請交代這段中的人物、事件和原因。"] {
            let context = AIQuestionContext(bookID: book.id, conversationID: conversation.id, question: text,
                source: source, boundary: source.boundary(), history: conversation.messages)
            let started = Date()
            let result = try await AIAssistantService.shared.answer(context: context)
            XCTAssertFalse(result.content.isEmpty)
            XCTAssertTrue(result.hasEvidence)
            XCTAssertEqual(result.provenance?.requestID, context.requestID)
            XCTAssertTrue(result.provenance?.sentEvidence.allSatisfy { source.boundary().contains($0.chunk) } == true)
            let trace = try XCTUnwrap(AIDiagnosticStore.shared.latest)
            let metadata = try JSONSerialization.jsonObject(with: trace.export())
            turns.append(["question": text, "answer": result.content, "citations": result.citations.count,
                          "requestID": context.requestID.uuidString, "seconds": Date().timeIntervalSince(started), "trace": metadata])
            var user = AIChatMessage(role: .user, text: text); user.provenance = result.provenance
            var assistant = AIChatMessage(role: .assistant, text: result.content, citations: result.citations)
            assistant.provenance = result.provenance; assistant.notices = result.notices
            conversation.messages += [user, assistant]
            AIChatStore.shared.save(conversation, forBook: book.id)
            report["turns"] = turns; try saveReport()
            print("AI_LIVE answer \(turns.count) chars=\(result.content.count) citations=\(result.citations.count)")
        }
        // A bounded live regression, with the full read boundary planned and honest partial
        // coverage persisted for the app's normal Resume action. It is not a full-book scan.
        var budget = AIMemoryBudget(); budget.maximumCalls = min(max(configuration.memoryCalls, 1), 8)
        let memory = AICharacterMemoryService.shared
        let plan = try await memory.prepare(source: source, wholeBook: false, budget: budget)
        try await memory.start(confirmed: plan, source: source)
        await memory.wait(book: book.id)
        let coverage = try await memory.coverage(job: plan, source: source)
        let view = try await memory.view(source: source, boundary: source.boundary())
        report["memory"] = ["plannedBatches": coverage.plannedUnits, "savedBatches": coverage.committedUnits,
            "plannedUTF16": coverage.plannedUTF16, "savedUTF16": coverage.committedUTF16,
            "characterNames": view.cards.flatMap(\.names), "state": memory.jobs[book.id]?.state.rawValue ?? "unknown",
            "failure": memory.failures[book.id] ?? ""]
        XCTAssertGreaterThan(coverage.committedUnits, 0)
        XCTAssertGreaterThan(view.count, 0)
        XCTAssertEqual(coverage.committedUnits, min(plan.units.count, budget.maximumCalls))
        try saveReport()
        print("AI_LIVE characters=\(view.count) saved=\(coverage.committedUnits)/\(coverage.plannedUnits)")
    }
}

extension AILiveBookVerificationTests {
    /// Re-checks a corrected position-specific path without rebilling unrelated live cases.
    @MainActor func testCurrentPassageAtChapterBoundary() async throws {
        try await verifyExistingBook(includeQuestion: true)
    }

    @MainActor func testCharacterMemoryAtHalfProgress() async throws {
        try await verifyExistingBook(includeQuestion: false)
    }

    @MainActor private func verifyExistingBook(includeQuestion: Bool) async throws {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let marker = documents.appendingPathComponent(includeQuestion ? "ai-live-current-passage.enabled" : "ai-live-memory.enabled")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: marker.path), "Explicit current-passage verification was not provisioned")
        try FileManager.default.removeItem(at: marker)
        let reportURL = documents.appendingPathComponent("ai-live-verification-result.json")
        let prior = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: reportURL)) as? [String: Any])
        let bookID = try XCTUnwrap(UUID(uuidString: XCTUnwrap(prior["bookID"] as? String)))
        let store = BookStore()
        let book = try XCTUnwrap(store.readingBook(id: bookID))
        let url = try XCTUnwrap(store.shareableFileURL(for: book))
        let preparation = try TXTReaderPreparationService.prepare(url: url, bookId: bookID, bookTitle: book.title)
        let indexes = TXTReaderPreparationService.buildChapterIndexes(for: preparation)
        let builder = TXTLazyAttributedStringBuilder(mappedTextFile: preparation.mappedTextFile, chapterIndexes: indexes)
        var texts: [String] = []
        for i in indexes.indices {
            let value = await builder.localChapterText(at: i)
            texts.append(try XCTUnwrap(value.text))
        }
        let position = try XCTUnwrap(JSONFileReadingPositionStore().loadSync(for: bookID.uuidString))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let rulesDigest = AISourceManifest.digest(try encoder.encode(ReplaceRuleStore.shared.rules))
        let source = AIBookContentAdapter(bookID: bookID, chapters: indexes.map { .init(index: $0.index, title: $0.title, content: "") },
            transformationVersion: "chapterPlainText.v1@rules:" + rulesDigest) { texts[$0] }
            .atReadingPosition(spine: position.spineIndex, renderedOffset: position.charOffset, renderedText: texts[position.spineIndex])
        var report: [String: Any] = [:]
        if includeQuestion {
        let question = "剛剛發生了什麼？請交代這段中的人物、事件和原因。"
        let context = AIQuestionContext(bookID: bookID, question: question, source: source, boundary: source.boundary())
        let result = try await AIAssistantService.shared.answer(context: context)
        XCTAssertTrue(result.hasEvidence)
        XCTAssertFalse(result.content.isEmpty)
        XCTAssertTrue(result.provenance?.sentEvidence.contains { $0.kind == .currentPosition && $0.chunk.start.spineIndex >= position.spineIndex - 1 } == true)
        XCTAssertTrue(result.citations.contains { $0.spineIndex >= position.spineIndex - 1 })
        XCTAssertTrue(result.provenance?.sentEvidence.allSatisfy { source.boundary().contains($0.chunk) } == true)
        report = ["question": question, "answer": result.content,
            "progress": source.progress(forSpine: position.spineIndex, charOffset: position.charOffset),
            "citedSpines": result.citations.map(\.spineIndex),
            "trace": try JSONSerialization.jsonObject(with: XCTUnwrap(AIDiagnosticStore.shared.latest).export())]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: documents.appendingPathComponent("ai-live-current-passage-result.json"), options: [.atomic, .completeFileProtection])
        print("AI_LIVE_CURRENT chars=\(result.content.count) citedSpines=\(result.citations.map(\.spineIndex))")
        }
        let memory = AICharacterMemoryService.shared
        try await memory.load(source: source)
        var budget = AIMemoryBudget(); budget.maximumCalls = 3
        let job = try await memory.prepare(source: source, wholeBook: false, budget: budget)
        let before = try await memory.coverage(job: job, source: source)
        AIDiagnosticStore.shared.captureNextRequestContent = true
        try await memory.start(confirmed: job, source: source)
        await memory.wait(book: bookID)
        if let trace = AIDiagnosticStore.shared.latest {
            try trace.export(including: ["messages", "response", "evidence"])
                .write(to: documents.appendingPathComponent("ai-live-memory-diagnostic.json"), options: [.atomic, .completeFileProtection])
        }
        let coverage = try await memory.coverage(job: job, source: source)
        let view = try await memory.view(source: source, boundary: source.boundary())
        report["memory"] = ["beforeSavedBatches": before.committedUnits, "savedBatches": coverage.committedUnits,
            "plannedBatches": coverage.plannedUnits, "savedUTF16": coverage.committedUTF16,
            "characterNames": view.cards.flatMap(\.names), "state": memory.jobs[bookID]?.state.rawValue ?? "unknown",
            "failure": memory.failures[bookID] ?? ""]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: documents.appendingPathComponent("ai-live-current-passage-result.json"), options: [.atomic, .completeFileProtection])
        XCTAssertEqual(coverage.committedUnits, min(job.units.count, before.committedUnits + budget.maximumCalls))
        XCTAssertGreaterThan(view.count, 0)
        print("AI_LIVE_MEMORY saved=\(coverage.committedUnits)/\(coverage.plannedUnits) characters=\(view.count)")
    }
}
