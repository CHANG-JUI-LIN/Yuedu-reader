import Foundation

/// AI 多角色朗讀: who speaks each line of a chapter, how, and which voice reads them.
///
/// Chapter by chapter, never the whole book up front. A chapter is analysed just before it is
/// read (narration waits for it), the next one while this one plays, and — when the reader asks —
/// a batch further ahead. Cost and time stay proportional to what is actually listened to, an
/// online book's unfetched chapters are never needed, and the cast never lists a character the
/// reader has not reached.
///
/// The roster is the book's: every analysed chapter adds its speakers, and a voice chosen for
/// a character — by the reader or automatically — follows them through every chapter.
@MainActor
@Observable
final class AIDialogueCastService {
    static let shared = AIDialogueCastService()

    struct Request: Sendable, Equatable {
        let bookID: UUID
        let chapterIndex: Int
        /// The chapter's full narration text, exactly as the engine will receive it.
        let text: String
        /// Ask for a spoken direction per line — only when the voice can follow one.
        let includeInstruct: Bool
        let key: String

        init(bookID: UUID, chapterIndex: Int, text: String, includeInstruct: Bool) {
            self.bookID = bookID
            self.chapterIndex = chapterIndex
            self.text = text
            self.includeInstruct = includeInstruct
            self.key = AIDialogueAttribution.key(text: text, includeInstruct: includeInstruct)
        }

        var cacheKey: String { "\(bookID.uuidString)|\(key)" }
    }

    enum Readiness: Equatable {
        case ready(TTSChapterDialogue)
        /// Not analysed yet, and the AI can be asked.
        case needsAnalysis
        /// No AI to ask, or it already failed on this exact text this session — narration
        /// reads the speakers off the prose, the same as without AI.
        case unavailable
    }

    enum ChapterState: Equatable {
        case analyzing
        case failed(String)
    }

    struct BatchProgress: Equatable {
        var done: Int
        var total: Int
    }

    private(set) var rosters: [UUID: TTSDialogueRoster] = [:]
    private(set) var chapterStates: [String: ChapterState] = [:]
    /// Bumped when anything about a book's cast changes, for screens that show it.
    private(set) var revisions: [UUID: Int] = [:]
    private(set) var batchProgress: [UUID: BatchProgress] = [:]

    @ObservationIgnored private var chapters: [String: TTSChapterDialogue] = [:]
    @ObservationIgnored private var chapterOrder: [String] = []
    @ObservationIgnored private var inFlight: [String: Task<TTSChapterDialogue, Error>] = [:]
    @ObservationIgnored private var rosterLoads: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var batchTasks: [UUID: Task<Void, Never>] = [:]

    private let store: AIDialogueCastStore
    private let injectedProvider: (any LLMProviding)?
    private static let chapterCacheLimit = 32
    private static let windowConcurrency = 3

    init(store: AIDialogueCastStore = .shared, provider: (any LLMProviding)? = nil) {
        self.store = store
        self.injectedProvider = provider
    }

    // MARK: - Availability

    /// Pro, and an AI service with a key.
    var isAvailable: Bool {
        if injectedProvider != nil { return true }
        return ReaderPremiumVisibilityPolicy(isProActive: SubscriptionStore.shared.isProActive).allowsAI
            && AIProviderStore.shared.hasConfiguredProfile
    }

    // MARK: - Reading state

    func roster(forBook bookID: UUID) -> TTSDialogueRoster {
        rosters[bookID] ?? TTSDialogueRoster()
    }

    /// Characters that have spoken by `chapterIndex` — the only ones a cast screen may show.
    func characters(forBook bookID: UUID, through chapterIndex: Int) -> [TTSDialogueCharacter] {
        roster(forBook: bookID).characters.filter { $0.firstChapter <= chapterIndex }
    }

    func cachedChapter(_ request: Request) -> TTSChapterDialogue? {
        chapters[request.cacheKey]
    }

    func state(of request: Request) -> ChapterState? {
        chapterStates[request.cacheKey]
    }

    func readiness(_ request: Request) -> Readiness {
        if let cached = chapters[request.cacheKey] { return .ready(cached) }
        if case .failed = chapterStates[request.cacheKey] { return .unavailable }
        return isAvailable ? .needsAnalysis : .unavailable
    }

    /// Reads the roster from disk, once per book.
    func loadRoster(forBook bookID: UUID) async {
        if rosters[bookID] != nil { return }
        if let running = rosterLoads[bookID] { return await running.value }
        let store = store
        let task = Task { @MainActor in
            do {
                let loaded = try await store.roster(book: bookID)
                if rosters[bookID] == nil { rosters[bookID] = loaded }
            } catch {
                // Left unset rather than empty: an empty roster saved over an unreadable file
                // would discard every voice the book had.
                AppLogger.error("AI dialogue roster unreadable", error: error, context: ["book": bookID.uuidString])
            }
        }
        rosterLoads[bookID] = task
        await task.value
        rosterLoads[bookID] = nil
    }

    // MARK: - Analysis

    /// The chapter's attribution: from memory, from disk, or from the AI.
    ///
    /// Concurrent callers for the same chapter share one request — the start of playback and
    /// the prefetch that was already running for it must not both pay.
    /// - Parameter knownAliases: alias → name from the reader's character cards and character
    ///   memory, so the model maps 塵哥 onto 張若塵 rather than making a second person.
    @discardableResult
    func analyze(_ request: Request, knownAliases: [String: String] = [:], force: Bool = false) async throws -> TTSChapterDialogue {
        let key = request.cacheKey
        if !force, let cached = chapters[key] { return cached }
        if let running = inFlight[key] { return try await running.value }
        let task = Task { @MainActor in
            try await self.perform(request, knownAliases: knownAliases, force: force)
        }
        inFlight[key] = task
        chapterStates[key] = .analyzing
        defer { inFlight[key] = nil }
        do {
            let result = try await task.value
            chapterStates[key] = nil
            return result
        } catch {
            chapterStates[key] = error is CancellationError ? nil : .failed(error.localizedDescription)
            throw error
        }
    }

    /// Analyses a chapter ahead of time; the result waits in the cache for playback.
    func prefetch(_ request: Request, knownAliases: [String: String] = [:]) {
        guard isAvailable, chapters[request.cacheKey] == nil, inFlight[request.cacheKey] == nil,
              chapterStates[request.cacheKey] == nil else { return }
        Task { @MainActor in
            do {
                try await analyze(request, knownAliases: knownAliases)
            } catch {
                AppLogger.error("AI dialogue prefetch failed", error: error, context: ["chapter": request.chapterIndex], level: .warning)
            }
        }
    }

    private func perform(_ request: Request, knownAliases: [String: String], force: Bool) async throws -> TTSChapterDialogue {
        let bookID = request.bookID
        await loadRoster(forBook: bookID)
        if !force, let stored = try await store.chapter(book: bookID, key: request.key) {
            remember(stored, key: request.cacheKey)
            return stored
        }
        guard let roster = rosters[bookID] else {
            // The roster file exists but could not be read (logged by `loadRoster`). Writing
            // a fresh one would overwrite it, so nothing is analysed until it is resolved.
            throw AIMemoryFailure.persistence
        }
        let provider = try resolveProvider()
        let aliasMap = roster.aliasMap.merging(knownAliases) { current, _ in current }
        let known = Self.knownCharacters(roster: roster, aliases: knownAliases)
        let text = request.text
        // Quote detection walks the whole chapter: off the main actor.
        let (quotes, windows) = await Task.detached(priority: .userInitiated) {
            let quotes = AIDialogueAttribution.quotes(in: text)
            return (quotes, AIDialogueAttribution.windows(text: text, quotes: quotes))
        }.value
        let carry = roster.tails[request.chapterIndex - 1] ?? []
        let includeInstruct = request.includeInstruct

        let started = SourcePerfTrace.now
        var parsed: [AIDialogueAttribution.Parsed] = []
        var providerName = provider.identifier
        var modelName = provider.defaultModel
        try await withThrowingTaskGroup(of: (AIDialogueAttribution.Parsed, String, String).self) { group in
            var next = 0
            func addNext() throws {
                guard next < windows.count else { return }
                let window = windows[next]
                next += 1
                let generation = try AIDialogueAttribution.request(
                    window: window, known: known, carry: carry, includeInstruct: includeInstruct
                )
                group.addTask {
                    let raw = try await provider.generate(generation)
                    let result = try AIDialogueAttribution.parse(
                        raw, window: window, text: text, aliasMap: aliasMap, includeInstruct: includeInstruct
                    )
                    return (result, raw.provider, raw.model)
                }
            }
            for _ in 0..<Self.windowConcurrency { try addNext() }
            while let (result, name, model) = try await group.next() {
                parsed.append(result)
                providerName = name
                modelName = model
                try addNext()
            }
        }
        SourcePerfTrace.record(
            "ai.dialogue.analyze",
            // Off main by construction: the windows run in a task group; only the merge below
            // is on the main actor.
            "chapter=\(request.chapterIndex) windows=\(windows.count) quotes=\(quotes.count) chars=\(text.count)",
            since: started,
            thresholdMs: 0
        )

        let chapter = AIDialogueAttribution.chapter(
            key: request.key,
            chapterIndex: request.chapterIndex,
            quotes: quotes,
            parsed: parsed,
            provider: providerName,
            model: modelName,
            includeInstruct: includeInstruct
        )
        var updated = rosters[bookID] ?? roster
        updated.merge(
            chapter: chapter,
            characters: parsed.flatMap(\.characters),
            tail: chapter.tail(in: text)
        )
        rosters[bookID] = updated
        remember(chapter, key: request.cacheKey)
        revisions[bookID, default: 0] += 1
        do {
            try await store.save(chapter: chapter, book: bookID)
            try await store.save(roster: updated, book: bookID)
        } catch {
            // Playback still has the result in memory; only the next launch loses it.
            AppLogger.error("AI dialogue cast not saved", error: error, context: ["book": bookID.uuidString])
        }
        return chapter
    }

    private func remember(_ chapter: TTSChapterDialogue, key: String) {
        if chapters[key] == nil { chapterOrder.append(key) }
        chapters[key] = chapter
        while chapterOrder.count > Self.chapterCacheLimit {
            chapters.removeValue(forKey: chapterOrder.removeFirst())
        }
    }

    private func resolveProvider() throws -> any LLMProviding {
        if let injectedProvider { return injectedProvider }
        switch AIProviderAssembly.makeProvider() {
        case let .success(provider): return provider
        case let .failure(reason): throw AIAssistantService.Failure.unavailable(reason)
        }
    }

    /// The roster's characters, main cast first, plus names only the reader's cards know.
    static func knownCharacters(roster: TTSDialogueRoster, aliases: [String: String]) -> [AIDialogueAttribution.KnownCharacter] {
        var known = roster.characters
            .sorted { $0.lineCount > $1.lineCount }
            .map { AIDialogueAttribution.KnownCharacter(name: $0.name, aliases: $0.aliases, gender: $0.gender, age: $0.age) }
        let listed = Set(known.map(\.name))
        var extra: [String: [String]] = [:]
        for (alias, name) in aliases where !listed.contains(name) {
            if alias != name { extra[name, default: []].append(alias) } else { extra[name, default: []] += [] }
        }
        for (name, names) in extra.sorted(by: { $0.key < $1.key }) {
            known.append(.init(name: name, aliases: names.sorted(), gender: .unknown, age: .unknown))
        }
        return known
    }

    // MARK: - Batch

    /// Analyses `chapters` one after another in the background, for a reader who wants the cast
    /// ready ahead. `request` produces each chapter's narration (it may have to lay it out);
    /// `nil` skips a chapter that has no text yet.
    func startBatch(
        bookID: UUID,
        chapters indices: [Int],
        knownAliases: [String: String],
        request: @escaping @MainActor (Int) async -> Request?
    ) {
        batchTasks[bookID]?.cancel()
        guard !indices.isEmpty else { return }
        batchProgress[bookID] = BatchProgress(done: 0, total: indices.count)
        batchTasks[bookID] = Task { @MainActor in
            for (position, index) in indices.enumerated() {
                guard !Task.isCancelled else { break }
                if let chapterRequest = await request(index) {
                    do {
                        try await analyze(chapterRequest, knownAliases: knownAliases)
                    } catch is CancellationError {
                        break
                    } catch {
                        AppLogger.error("AI dialogue batch chapter failed", error: error, context: ["chapter": index], level: .warning)
                        // A key or service problem fails every chapter alike; stop paying for it.
                        if case AIAssistantService.Failure.unavailable = error { break }
                        if let llm = error as? LLMError, llm == .unauthorized || llm == .rateLimited { break }
                    }
                }
                batchProgress[bookID] = BatchProgress(done: position + 1, total: indices.count)
            }
            batchProgress[bookID] = nil
            batchTasks[bookID] = nil
        }
    }

    func cancelBatch(bookID: UUID) {
        batchTasks[bookID]?.cancel()
        batchTasks[bookID] = nil
        batchProgress[bookID] = nil
    }

    // MARK: - Voices

    /// Automatic picks for `family`, speaker → `TTSRoleVoice.storageValue`.
    func autoVoices(forBook bookID: UUID, family: TTSVoiceFamily) -> [String: String] {
        let prefix = TTSDialogueRoster.autoVoiceKey(family: family.rawValue, speaker: "")
        var result: [String: String] = [:]
        for (key, value) in roster(forBook: bookID).autoVoices where key.hasPrefix(prefix) {
            result[String(key.dropFirst(prefix.count))] = value
        }
        return result
    }

    /// Gives every character still without a voice one that matches them, and keeps it.
    func assignAutoVoices(
        forBook bookID: UUID,
        family: TTSVoiceFamily,
        explicit: [String: String],
        pool: TTSVoiceCandidates.Pool
    ) {
        guard var roster = rosters[bookID], !roster.characters.isEmpty else { return }
        let picks = TTSAutoCast.assign(
            characters: roster.characters,
            explicit: explicit,
            existing: autoVoices(forBook: bookID, family: family),
            candidates: pool.candidates,
            narrator: pool.narrator
        )
        guard !picks.isEmpty else { return }
        for (speaker, voice) in picks {
            roster.autoVoices[TTSDialogueRoster.autoVoiceKey(family: family.rawValue, speaker: speaker)] = voice
        }
        rosters[bookID] = roster
        revisions[bookID, default: 0] += 1
        let store = store
        Task {
            do { try await store.save(roster: roster, book: bookID) } catch {
                AppLogger.error("AI dialogue roster not saved", error: error, context: ["book": bookID.uuidString])
            }
        }
    }

    // MARK: - Reset

    func clear(book bookID: UUID) async {
        cancelBatch(bookID: bookID)
        rosters[bookID] = TTSDialogueRoster()
        let prefix = "\(bookID.uuidString)|"
        chapterOrder.removeAll { $0.hasPrefix(prefix) }
        chapters = chapters.filter { !$0.key.hasPrefix(prefix) }
        chapterStates = chapterStates.filter { !$0.key.hasPrefix(prefix) }
        revisions[bookID, default: 0] += 1
        do { try await store.clear(book: bookID) } catch {
            AppLogger.error("AI dialogue cast not cleared", error: error, context: ["book": bookID.uuidString])
        }
    }
}
