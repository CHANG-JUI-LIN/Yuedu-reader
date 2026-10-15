import Combine
import Foundation

/// Builds and keeps a book's chapter digests, volume summaries and whole-book summary.
///
/// A run is planned without calling a model, shown to the reader with its call count, and only
/// started once confirmed. It pauses rather than spend past the confirmed count, and when the
/// page goes away; every digest is saved as it lands, so the next run — including after the
/// reader reads further — only pays for what is new.
@MainActor
final class AIBookSummaryService: ObservableObject {
    static let shared = AIBookSummaryService()

    struct Progress: Equatable {
        var completed: Int
        var total: Int
    }

    enum RunState: Equatable {
        case idle
        case running(Progress)
        /// Reached the call count the reader confirmed; the rest needs a new confirmation.
        case budgetReached
        /// Left the page or the app went to the background.
        case paused
        case failed(String)
    }

    /// The service a run would use, for the confirmation sheet.
    struct Service: Equatable {
        let name: String
        let model: String
    }

    @Published private(set) var records: [UUID: AIBookSummaryRecord] = [:]
    @Published private(set) var runs: [UUID: RunState] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var owners: [UUID: UUID] = [:]
    private let store: AIBookSummaryStore
    private let injectedProvider: (any LLMProviding)?
    private let origin: AIDiagnostics.Origin

    init(store: AIBookSummaryStore = .shared, provider: (any LLMProviding)? = nil, origin: AIDiagnostics.Origin = .observed) {
        self.store = store
        injectedProvider = provider
        self.origin = origin
    }

    private enum Stop: Error { case budget }
    /// Chapter-digest requests in flight at once (maintainer, 2026-10-15).
    static let concurrentDigests = 3

    private func provider() throws -> (any LLMProviding, Service) {
        if let injectedProvider {
            return (injectedProvider, Service(name: injectedProvider.identifier, model: injectedProvider.defaultModel))
        }
        switch AIProviderAssembly.activeService() {
        case let .success(active):
            return (active.provider, Service(name: active.name, model: active.model))
        case let .failure(reason):
            throw AIAssistantService.Failure.unavailable(reason)
        }
    }

    func service() throws -> Service { try provider().1 }

    func load(book: UUID) async {
        guard records[book] == nil else { return }
        do { records[book] = try await store.load(book: book) }
        catch {
            AppLogger.error("AI book summary could not be read", error: error, context: ["book": book.uuidString])
            runs[book] = .failed(error.localizedDescription)
        }
    }

    /// What a run would do right now. Reads the stored record; never calls a model.
    func plan(source: AIBookContentAdapter) async throws -> AIBookSummaryPlan {
        let record = try await store.load(book: source.chunkBookID)
        records[source.chunkBookID] = record
        let language = AIAnswerLanguage.current
        // Walks every read chapter's text; kept off the main actor for long books.
        return await Task.detached(priority: .userInitiated) {
            AIBookSummaryPlanner.plan(source: source, record: record, language: language)
        }.value
    }

    /// Starts a confirmed plan. The plan's call estimate is the budget for this run.
    func start(plan: AIBookSummaryPlan, source: AIBookContentAdapter) throws {
        guard plan.bookID == source.chunkBookID, plan.sourceVersion == source.contentFingerprint else {
            throw AIBookSummaryPrompt.Failure.sourceChanged
        }
        pause(book: plan.bookID)
        let (base, service) = try provider()
        let token = UUID()
        owners[plan.bookID] = token
        runs[plan.bookID] = .running(Progress(completed: 0, total: plan.estimatedCalls))
        tasks[plan.bookID] = Task {
            await run(plan: plan, source: source, provider: AITracedProvider(base: base), model: service.model, token: token)
        }
    }

    func pause(book: UUID) {
        owners[book] = nil
        tasks[book]?.cancel()
        tasks[book] = nil
        if case .running = runs[book] { runs[book] = .paused }
    }

    func wait(book: UUID) async { await tasks[book]?.value }

    func clear(book: UUID) async throws {
        pause(book: book)
        try await store.clear(book: book)
        records[book] = AIBookSummaryRecord()
        runs[book] = .idle
    }

    // MARK: - Run

    private func run(plan: AIBookSummaryPlan, source: AIBookContentAdapter, provider: any LLMProviding, model: String, token: UUID) async {
        let book = plan.bookID
        defer { if owners[book] == token { owners[book] = nil; tasks[book] = nil } }
        var spent = 0
        do {
            var record = try await store.load(book: book)

            func owned() throws {
                try Task.checkCancellation()
                guard owners[book] == token else { throw CancellationError() }
            }
            func commit() async throws {
                try owned()
                try await store.save(record, book: book)
                records[book] = record
            }
            /// Reserves one call against this run's budget and persists the reservation
            /// before the request goes out.
            func reserve() async throws {
                guard spent < plan.estimatedCalls else { throw Stop.budget }
                spent += 1
                record.callsSpent += 1
                try await commit()
                runs[book] = .running(Progress(completed: spent, total: plan.estimatedCalls))
            }
            func generate(_ request: LLMGenerationRequest, feature: String) async throws -> LLMRawResponse {
                try await reserve()
                let trace = AIDiagnosticStore.shared.begin(feature: feature, bookID: book, adapter: source, boundary: plan.boundary, origin: origin)
                defer { AIDiagnosticStore.shared.finish(trace) }
                let raw = try await AIDiagnostics.$current.withValue(trace) { try await provider.generate(request, model: model) }
                try owned()
                return raw
            }
            func reduce(scope: String, heading: String, items: [String]) async throws -> String {
                var level = items
                while true {
                    var windows = AIBookSummaryPrompt.windows(level)
                    // Items each larger than a window cannot be grouped by size; pair them so
                    // every round still halves the input.
                    if windows.count == level.count && level.count > 1 {
                        windows = stride(from: 0, to: level.count, by: 2).map { Array(level[$0..<min($0 + 2, level.count)]) }
                    }
                    if windows.count == 1 {
                        let raw = try await generate(AIBookSummaryPrompt.reduceRequest(scope: scope, heading: heading, items: windows[0], language: plan.language), feature: "bookSummaryReduce")
                        return try AIBookSummaryPrompt.parseReduce(raw)
                    }
                    var next: [String] = []
                    for (index, window) in windows.enumerated() {
                        let part = heading + "（第 \(index + 1)/\(windows.count) 段）"
                        let raw = try await generate(AIBookSummaryPrompt.reduceRequest(scope: scope, heading: part, items: window, language: plan.language), feature: "bookSummaryReduce")
                        next.append(try AIBookSummaryPrompt.parseReduce(raw))
                    }
                    level = next
                }
            }

            // 1. Chapter digests, `concurrentDigests` batches at a time (maintainer, 2026-10-15:
            // they do not depend on one another). Each call is reserved before it goes out, and
            // each batch is saved as it comes back; the first failure stops the run, as one
            // batch at a time did. A chapter split across batches is saved once all its parts are in.
            var pieces: [Int: [Int: String]] = [:]
            func apply(_ batch: AIBookSummaryPlan.Batch, _ raw: LLMRawResponse) async throws {
                try owned()
                let summaries = try AIBookSummaryPrompt.parseDigests(raw, batch: batch)
                for part in batch.parts {
                    pieces[part.order, default: [:]][part.index] = summaries[part.id]
                    guard pieces[part.order]?.count == part.count,
                          let digest = source.manifest.chapters[part.order].digest,
                          let end = plan.readEnds[part.order] else { continue }
                    let text = (0..<part.count).compactMap { pieces[part.order]?[$0] }.joined(separator: "\n")
                    record.digests[part.order] = AIChapterDigest(order: part.order, title: source.chunkSections[part.order].title,
                        sourceDigest: digest, endUTF16: end, promptVersion: AIBookSummaryPlanner.recipe(plan.language), text: text)
                    pieces[part.order] = nil
                }
                try await commit()
            }
            var waiting = plan.batches[...]
            var budgetReached = false
            try await withThrowingTaskGroup(of: (AIBookSummaryPlan.Batch, LLMRawResponse).self, returning: Void.self,
                                            isolation: MainActor.shared) { group in
                var inFlight = 0
                while true {
                    while inFlight < Self.concurrentDigests, !budgetReached, let batch = waiting.popFirst() {
                        try owned()
                        let request = try AIBookSummaryPrompt.digestRequest(batch: batch, source: source, language: plan.language)
                        do { try await reserve() } catch Stop.budget {
                            // Out of confirmed calls: the batches in flight still come back and are kept.
                            budgetReached = true
                            break
                        }
                        let trace = AIDiagnosticStore.shared.begin(feature: "bookSummaryDigest", bookID: book, adapter: source,
                                                                   boundary: plan.boundary, origin: origin)
                        group.addTask {
                            let raw: LLMRawResponse
                            do {
                                raw = try await AIDiagnostics.$current.withValue(trace) { try await provider.generate(request, model: model) }
                            } catch {
                                await AIDiagnosticStore.shared.finish(trace)
                                throw error
                            }
                            await AIDiagnosticStore.shared.finish(trace)
                            return (batch, raw)
                        }
                        inFlight += 1
                    }
                    guard inFlight > 0, let (batch, raw) = try await group.next() else { break }
                    inFlight -= 1
                    try await apply(batch, raw)
                }
            }
            if budgetReached { throw Stop.budget }

            // 2. Volumes whose digests changed.
            for volume in plan.readVolumes {
                let items = AIBookSummaryPlanner.digestItems(volume: volume, through: plan.throughChapter, readEnds: plan.readEnds,
                    record: record, manifest: source.manifest, language: plan.language)
                guard !items.isEmpty else { continue }
                let digest = AIBookSummaryPrompt.inputDigest(items, language: plan.language)
                guard record.volumes[volume.id]?.inputDigest != digest else { continue }
                let through = min(volume.chapters.upperBound, plan.throughChapter)
                let heading = "卷：\(AIBookSummaryPlanner.title(of: volume))\n範圍：第 \(volume.chapters.lowerBound + 1)–\(through + 1) 章"
                let text = try await reduce(scope: "這一卷（已讀部分）", heading: heading, items: items)
                record.volumes[volume.id] = AISummaryText(text: text, inputDigest: digest, promptVersion: AIBookSummaryPlanner.recipe(plan.language),
                    throughChapter: through, model: model, createdAt: Date())
                try await commit()
            }

            // 3. The whole book, from the volume summaries.
            let volumeItems = plan.readVolumes.compactMap { volume in
                record.volumes[volume.id].map { "【\(AIBookSummaryPlanner.title(of: volume))】\n\($0.text)" }
            }
            let bookDigest = AIBookSummaryPrompt.inputDigest(volumeItems, language: plan.language)
            if !volumeItems.isEmpty, record.book?.inputDigest != bookDigest {
                let heading = "範圍：第 1–\(plan.throughChapter + 1) 章"
                let text = try await reduce(scope: "全書（已讀部分）", heading: heading, items: volumeItems)
                record.book = AISummaryText(text: text, inputDigest: bookDigest, promptVersion: AIBookSummaryPlanner.recipe(plan.language),
                    throughChapter: plan.throughChapter, model: model, createdAt: Date())
                try await commit()
            }
            if owners[book] == token { runs[book] = .idle }
        } catch Stop.budget {
            if owners[book] == token { runs[book] = .budgetReached }
        } catch is CancellationError {
            if owners[book] == token { runs[book] = .paused }
        } catch {
            AppLogger.error("AI book summary run failed", error: error, context: ["book": book.uuidString, "calls": "\(spent)"])
            if owners[book] == token { runs[book] = .failed(error.localizedDescription) }
        }
    }
}
