import Combine
import Foundation

/// Runs 整章翻譯 and holds the translations the reader lays out.
///
/// The reader asks for the chapter on screen; the service translates what that chapter is
/// still missing — from the paragraph being read onwards, so the page in front of the reader
/// comes first — and announces every batch, so the chapter is laid out again with it.
/// Translations are kept per book and target language and never requested twice.
@MainActor
final class AIChapterTranslationService: ObservableObject {
    /// Batches in flight at once (maintainer, 2026-10-15). A translation is as long as its
    /// source, so its time is spent writing: three 2,000-character batches side by side finish
    /// a chapter in about a third of the time one after another took, where one larger batch
    /// would take as long and show nothing until it was done.
    static let concurrentBatches = 3

    static let shared = AIChapterTranslationService()

    struct Chapter: Hashable, Sendable {
        let book: UUID
        let spine: Int
        let language: AIAnswerLanguage
    }

    enum RunState: Equatable {
        case running(completed: Int, total: Int)
        case finished
        case failed(String)
    }

    @Published private(set) var runs: [Chapter: RunState] = [:]
    /// A chapter gained translations; the reader lays it out again.
    let updates = PassthroughSubject<Chapter, Never>()

    private struct Table: Hashable {
        let book: UUID
        let language: AIAnswerLanguage
    }

    private var tables: [Table: [String: String]] = [:]
    private struct Run {
        let chapter: Chapter
        let id: UUID
        let task: Task<Void, Never>
    }
    /// One run per book: the chapter on screen is the one worth paying for.
    private var tasks: [UUID: Run] = [:]
    private let store: AIChapterTranslationStore
    private let injectedProvider: (any LLMProviding)?
    private let origin: AIDiagnostics.Origin

    init(store: AIChapterTranslationStore = .shared, provider: (any LLMProviding)? = nil, origin: AIDiagnostics.Origin = .observed) {
        self.store = store
        injectedProvider = provider
        self.origin = origin
    }

    /// The service a run would use, for the reader to show before turning translation on.
    func service() -> Result<AIProviderAssembly.ActiveService, AIProviderAssembly.Unavailable> {
        if let injectedProvider { return .success(.init(provider: injectedProvider, name: injectedProvider.identifier)) }
        #if DEBUG
        if let fixture = ReaderTranslationFixture.provider { return .success(.init(provider: fixture, name: fixture.identifier)) }
        #endif
        return AIProviderAssembly.activeService()
    }

    // MARK: - Lookup

    /// Read while a chapter document is built. The book's stored translations are loaded
    /// on first use, synchronously, so the first page of a translated chapter is never laid
    /// out ahead of them.
    func translation(book: UUID, language: AIAnswerLanguage, paragraph key: String) -> String? {
        entries(Table(book: book, language: language))[ReaderTranslationText.storageKey(key)]
    }

    private func entries(_ table: Table) -> [String: String] {
        if let loaded = tables[table] { return loaded }
        let loaded: [String: String]
        do {
            loaded = try store.loadSync(book: table.book, language: table.language)
        } catch {
            // Unreadable, not absent: new translations overwrite it, and the log says why the
            // book's earlier ones are gone.
            AppLogger.error("Stored translations could not be read", error: error,
                            context: ["book": table.book.uuidString, "language": table.language.rawValue])
            loaded = [:]
        }
        tables[table] = loaded
        return loaded
    }

    /// How many requests translating the rest of `text` would take.
    func pendingBatchCount(book: UUID, language: AIAnswerLanguage, text: String) -> Int {
        let table = entries(Table(book: book, language: language))
        let pending = AIChapterTranslation.pending(in: text, readingOffset: 0) {
            table[ReaderTranslationText.storageKey($0)] != nil
        }
        return AIChapterTranslation.batches(pending).count
    }

    /// The per-book view of this service the chapter documents read from.
    func source(for book: UUID) -> any ReaderTranslationSource { Source(book: book, service: self) }

    private final class Source: ReaderTranslationSource {
        let book: UUID
        weak var service: AIChapterTranslationService?
        init(book: UUID, service: AIChapterTranslationService) {
            self.book = book
            self.service = service
        }
        func translation(forParagraph key: String, language: AIAnswerLanguage) -> String? {
            service?.translation(book: book, language: language, paragraph: key)
        }
    }

    // MARK: - Runs

    /// Translates what chapter `chapter.spine` — whose own text is `text` — is still missing.
    /// A run for another chapter of the same book stops; what it finished is kept.
    func translate(_ chapter: Chapter, text: String, readingOffset: Int, bookTitle: String?) {
        if let current = tasks[chapter.book], current.chapter == chapter { return }
        cancel(book: chapter.book)
        let provider: any LLMProviding
        switch service() {
        case let .success(active): provider = AITracedProvider(base: active.provider)
        case let .failure(reason):
            runs[chapter] = .failed(reason.message)
            return
        }
        let table = Table(book: chapter.book, language: chapter.language)
        let known = entries(table)
        let batches = AIChapterTranslation.batches(AIChapterTranslation.pending(in: text, readingOffset: readingOffset) {
            known[ReaderTranslationText.storageKey($0)] != nil
        })
        guard !batches.isEmpty else {
            runs[chapter] = .finished
            return
        }
        let id = UUID()
        runs[chapter] = .running(completed: 0, total: batches.count)
        let task = Task { [weak self] in
            guard let self else { return }
            await run(chapter, batches: batches, bookTitle: bookTitle, provider: provider, id: id)
        }
        tasks[chapter.book] = Run(chapter: chapter, id: id, task: task)
    }

    private func run(_ chapter: Chapter, batches: [[AIChapterTranslation.Paragraph]], bookTitle: String?,
                     provider: any LLMProviding, id: UUID) async {
        let table = Table(book: chapter.book, language: chapter.language)
        defer { if tasks[chapter.book]?.id == id { tasks[chapter.book] = nil } }
        do {
            // `concurrentBatches` at a time, in the order `pending` gave — what is on screen
            // first — each saved and shown as it comes back; the first failure stops the run.
            var waiting = Array(batches.enumerated())[...]
            var completed = 0
            try await withThrowingTaskGroup(of: ([AIChapterTranslation.Paragraph], LLMRawResponse).self, returning: Void.self,
                                            isolation: MainActor.shared) { group in
                var inFlight = 0
                while true {
                    while inFlight < Self.concurrentBatches, let (index, batch) = waiting.popFirst() {
                        try Task.checkCancellation()
                        let request = try AIChapterTranslation.request(batch, bookTitle: bookTitle, language: chapter.language)
                        let trace = AIDiagnosticStore.shared.begin(feature: "chapterTranslation", bookID: chapter.book, origin: origin)
                        trace.event("translationBatch", ["spine": "\(chapter.spine)", "index": "\(index)", "of": "\(batches.count)",
                                                         "paragraphs": "\(batch.count)", "language": chapter.language.rawValue,
                                                         "promptVersion": AIChapterTranslation.promptVersion])
                        group.addTask {
                            let raw: LLMRawResponse
                            do {
                                raw = try await AIDiagnostics.$current.withValue(trace) { try await provider.generate(request, model: nil) }
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
                    try Task.checkCancellation()
                    var stored = entries(table)
                    for (key, translation) in try AIChapterTranslation.parse(raw, batch: batch) {
                        stored[ReaderTranslationText.storageKey(key)] = translation
                    }
                    tables[table] = stored
                    try await store.save(stored, book: chapter.book, language: chapter.language)
                    completed += 1
                    runs[chapter] = completed == batches.count ? .finished : .running(completed: completed, total: batches.count)
                    updates.send(chapter)
                }
            }
        } catch is CancellationError {
            if case .running = runs[chapter] { runs[chapter] = nil }
        } catch {
            AppLogger.error("Chapter translation failed", error: error,
                            context: ["book": chapter.book.uuidString, "spine": chapter.spine, "language": chapter.language.rawValue])
            runs[chapter] = .failed(error.localizedDescription)
        }
    }

    func cancel(book: UUID) {
        guard let current = tasks.removeValue(forKey: book) else { return }
        current.task.cancel()
        if case .running = runs[current.chapter] { runs[current.chapter] = nil }
    }

    func wait(book: UUID) async { await tasks[book]?.task.value }

    /// Drops every language's translations of `book`, on disk and in memory.
    func clear(book: UUID) async throws {
        cancel(book: book)
        try await store.clear(book: book)
        tables = tables.filter { $0.key.book != book }
        runs = runs.filter { $0.key.book != book }
    }
}
