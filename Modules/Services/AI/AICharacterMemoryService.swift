import Combine
import Foundation

struct AIMemoryCoverage: Sendable {
    let plannedUnits: Int
    let committedUnits: Int
    let availableChapters: Int
    let analyzedChapters: Int
    let plannedUTF16: Int
    let committedUTF16: Int
    let characters: Int
    let bytes: Int
    let missing: [AISourceManifest.Chapter]
}

@MainActor
final class AICharacterMemoryService: ObservableObject {
    static let shared = AICharacterMemoryService()
    @Published private(set) var jobs: [UUID: AIMemoryJob] = [:]
    @Published private(set) var coverages: [UUID: AIMemoryCoverage] = [:]
    @Published private(set) var failures: [UUID: String] = [:]
    @Published private(set) var revisions: [UUID: Int] = [:]
    private let store: AICharacterMemoryStore
    private let injectedProvider: (any LLMProviding)?
    private let origin: AIDiagnostics.Origin
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var owners: [UUID: UUID] = [:]
    private var activating = Set<UUID>()
    private var controlRevisions: [UUID: Int] = [:]
    init(store: AICharacterMemoryStore = .shared, provider: (any LLMProviding)? = nil, origin: AIDiagnostics.Origin = .observed) {
        self.store = store; injectedProvider = provider; self.origin = origin
    }
    private func provider() throws -> (any LLMProviding, String, String) {
        if let injectedProvider { return (injectedProvider, "", injectedProvider.identifier) }
        let result = AIProviderAssembly.makeProvider()
        switch result {
        case let .success(provider):
            guard let configuration = try AIProviderStore.shared.load() else { throw AIMemoryFailure.providerChanged }
            return (provider, AISourceManifest.digest(configuration.baseURL), configuration.preset.displayName)
        case let .failure(reason): throw AIAssistantService.Failure.unavailable(reason)
        }
    }
    /// Read-only proposal. No job, model call or credential is written before UI consent.
    func prepare(source: AIBookContentAdapter, wholeBook: Bool, budget: AIMemoryBudget) throws -> AIMemoryJob {
        let (provider, digest, displayName) = try provider()
        var job = try AIMemoryPlanner.plan(source: source, boundary: source.boundary(wholeBook: wholeBook), provider: provider.identifier,
            model: provider.defaultModel, budget: budget, configurationDigest: digest)
        job.providerDisplayName = displayName
        return job
    }
    func coverage(job: AIMemoryJob, source: AIBookContentAdapter) async throws -> AIMemoryCoverage {
        let valid = try await store.validatedRecords(job: job, source: source)
        let IDs = Set(valid.map { $0.unit.id })
        let leaf = job.units.filter { !job.splitParents.contains($0.id) }
        let grouped = Dictionary(grouping: leaf, by: { $0.primary.spine })
        let texts = leaf.compactMap { $0.primary.text(in: source) }
        return .init(plannedUnits: leaf.count, committedUnits: leaf.filter { IDs.contains($0.id) }.count,
            availableChapters: grouped.count, analyzedChapters: grouped.values.filter { $0.allSatisfy { IDs.contains($0.id) } }.count,
            plannedUTF16: leaf.reduce(0) { $0 + $1.primary.end - $1.primary.start },
            committedUTF16: leaf.filter { IDs.contains($0.id) }.reduce(0) { $0 + $1.primary.end - $1.primary.start },
            characters: texts.reduce(0) { $0 + $1.count }, bytes: texts.reduce(0) { $0 + $1.utf8.count },
            missing: Array(job.manifest.chapters.prefix(job.targetChapters)).filter { $0.status != .available })
    }
    func load(source: AIBookContentAdapter) async throws {
        if tasks[source.chunkBookID] != nil { return }
        if let job = try await store.load(book: source.chunkBookID) { try await publish(job, source: source) }
    }
    private func publish(_ job: AIMemoryJob, source: AIBookContentAdapter, owner: UUID? = nil) async throws {
        let coverage = try await coverage(job: job, source: source)
        guard try await store.isActive(job) else { return }
        if let owner, owners[job.bookID] != owner { return }
        jobs[job.bookID] = job; coverages[job.bookID] = coverage
        revisions[job.bookID, default: 0] += 1
    }
    /// Called only after the user has reviewed the exact proposal and transmission budget.
    func start(confirmed job: AIMemoryJob, source: AIBookContentAdapter) async throws {
        try Task.checkCancellation()
        guard job.sourceVersion == source.contentFingerprint, job.bookID == source.chunkBookID else { throw AIMemoryFailure.sourceChanged }
        pause(book: job.bookID)
        let revision = controlRevisions[job.bookID, default: 0]
        try await store.create(job)
        try await publish(job, source: source)
        try Task.checkCancellation()
        guard controlRevisions[job.bookID, default: 0] == revision else { return }
        try await resume(source: source, acknowledgeUnknown: false)
    }
    func resume(source: AIBookContentAdapter, acknowledgeUnknown: Bool, additionalCalls: Int = 0) async throws {
        try Task.checkCancellation()
        guard activating.insert(source.chunkBookID).inserted else { return }
        let revision = controlRevisions[source.chunkBookID, default: 0]
        defer { activating.remove(source.chunkBookID) }
        guard tasks[source.chunkBookID] == nil, var job = try await store.load(book: source.chunkBookID) else { return }
        guard job.sourceVersion == source.contentFingerprint else { throw AIMemoryFailure.sourceChanged }
        let (base, digest, _) = try provider()
        guard base.identifier == job.provider, base.defaultModel == job.model, digest == job.configurationDigest else { throw AIMemoryFailure.providerChanged }
        if job.inFlightUnitID != nil && !acknowledgeUnknown { throw AIMemoryFailure.resultUnknown }
        if additionalCalls > 0 { job.budget.maximumCalls += additionalCalls }
        let done = Set(try await store.validatedRecords(job: job, source: source).map { $0.unit.id })
        if job.units.filter({ !job.splitParents.contains($0.id) }).allSatisfy({ done.contains($0.id) }) {
            job.state = .completedAvailable; job.inFlightUnitID = nil
            try await store.save(job); try await publish(job, source: source); return
        }
        guard job.calls < job.budget.maximumCalls else { throw AIMemoryFailure.budget }
        job.inFlightUnitID = nil; job.failure = nil; job.state = .running
        try await store.save(job)
        try Task.checkCancellation()
        guard controlRevisions[job.bookID, default: 0] == revision else { return }
        failures[job.bookID] = nil
        let token = UUID(); owners[job.bookID] = token
        let fixed = job
        tasks[job.bookID] = Task { await execute(job: fixed, source: source, provider: AITracedProvider(base: base), token: token) }
    }
    func wait(book: UUID) async { await tasks[book]?.value }
    @discardableResult
    func pause(book: UUID) -> Task<Void, Never>? {
        controlRevisions[book, default: 0] += 1
        owners[book] = nil
        let draining = tasks[book]
        draining?.cancel(); tasks[book] = nil
        if var job = jobs[book], job.state == .running {
            job.state = job.inFlightUnitID == nil ? .paused : .resultUnknown
            jobs[book] = job; revisions[book, default: 0] += 1
        }
        return draining
    }
    private func execute(job original: AIMemoryJob, source: AIBookContentAdapter, provider: any LLMProviding, token: UUID) async {
        var job = original
        defer { if owners[job.bookID] == token { owners[job.bookID] = nil; tasks[job.bookID] = nil } }
        do {
            var completed = try await store.validatedRecords(job: job, source: source)
            while true {
                try Task.checkCancellation()
                let active = try await store.isActive(job)
                try Task.checkCancellation()
                guard owners[job.bookID] == token, active else { throw CancellationError() }
                let done = Set(completed.map { $0.unit.id })
                let ordered = job.units.filter { !job.splitParents.contains($0.id) }.sorted { $0.primary.endPosition < $1.primary.endPosition }
                guard let unit = ordered.first(where: { !done.contains($0.id) }) else {
                    job.state = .completedAvailable; job.inFlightUnitID = nil
                    try await store.save(job); try await publish(job, source: source, owner: token)
                    return
                }
                guard job.calls < job.budget.maximumCalls else {
                    job.state = .budgetPaused; job.failure = AIMemoryFailure.budget.rawValue
                    try await store.save(job); try await publish(job, source: source, owner: token); return
                }
                let boundary = AIReadingBoundary(sourceVersion: source.contentFingerprint, sectionID: unit.primary.sectionID,
                    spineIndex: unit.primary.spine, utf16Offset: unit.primary.end)
                let trace = AIDiagnosticStore.shared.begin(feature: "characterMemory", bookID: job.bookID, adapter: source, boundary: boundary, origin: origin)
                defer { AIDiagnosticStore.shared.finish(trace) }
                do {
                    let input = try AIDiagnostics.$current.withValue(trace) {
                        try AIMemoryExtraction.input(unit: unit, source: source, job: job, previous: completed)
                    }
                    // Persist the attempt reservation BEFORE the external request. A crash
                    // here can overcount a call, but can never silently spend it twice.
                    job.calls += 1; job.inFlightUnitID = unit.id; job.state = .running
                    try await store.save(job); try await publish(job, source: source, owner: token)
                    trace.event("memoryAttempt", ["jobID": job.id.uuidString, "unitID": unit.id, "calls": "\(job.calls)",
                        "maximumCalls": "\(job.budget.maximumCalls)", "reusedUnits": "\(done.count)",
                        "reuseReason": "verifiedSourceTransformationAnalysisAndDependencies"])
                    try Task.checkCancellation()
                    guard owners[job.bookID] == token else { throw CancellationError() }
                    let record = try await AIDiagnostics.$current.withValue(trace) {
                        let raw = try await provider.generate(input.request)
                        try Task.checkCancellation()
                        return try AIMemoryExtraction.validate(raw: raw, input: input, source: source)
                    }
                    try Task.checkCancellation()
                    guard owners[job.bookID] == token else { throw CancellationError() }
                    try await AIDiagnostics.$current.withValue(trace) { try await store.commit(record, job: job) }
                    try Task.checkCancellation()
                    guard owners[job.bookID] == token else { throw CancellationError() }
                    completed.append(record)
                    job.inFlightUnitID = nil
                    try await store.save(job); try await publish(job, source: source, owner: token)
                } catch let error as LLMError where error == .incompleteOutput && unit.depth < job.budget.automaticSplitDepth {
                    // Only an explicitly pre-authorized length response permits one bounded
                    // bisection. No schema/network recovery and no fresh per-child budget.
                    try Task.checkCancellation()
                    guard owners[job.bookID] == token else { throw CancellationError() }
                    let children = try AIMemoryPlanner.split(unit, source: source, job: job)
                    job.splitParents.insert(unit.id); job.units += children; job.inFlightUnitID = nil
                    trace.event("memorySplit", ["parentID": unit.id, "children": children.map(\.id).joined(separator: ","), "depth": "\(unit.depth + 1)"])
                    try await store.save(job, writePlan: true)
                } catch {
                    let networkUnknown: Bool
                    if case .networkError = error as? LLMError { networkUnknown = true } else { networkUnknown = false }
                    let unknown = networkUnknown || error is CancellationError || (!(error is LLMError) && !(error is AIMemoryFailure))
                    if unknown && job.inFlightUnitID != nil { job.state = .resultUnknown; job.failure = AIMemoryFailure.resultUnknown.rawValue }
                    else { job.state = error is CancellationError ? .paused : .failed; job.inFlightUnitID = nil
                        job.failure = (error as? AIMemoryFailure)?.rawValue ?? ((error as? LLMError) == .incompleteOutput ? "length" : "generation") }
                    trace.event("memoryFailure", ["jobID": job.id.uuidString, "unitID": unit.id, "kind": job.failure ?? "cancelled", "calls": "\(job.calls)"])
                    throw error
                }
            }
        } catch {
            // A cancelled owner must not overwrite a newer resume's reserved calls or
            // checkpoint. Its durable in-flight reservation already describes uncertainty.
            guard owners[job.bookID] == token else { return }
            if job.state == .running { job.state = .paused }
            do {
                if try await store.isActive(job) {
                    guard owners[job.bookID] == token else { return }
                    try await store.save(job); try await publish(job, source: source, owner: token)
                }
            } catch {
                guard owners[job.bookID] == token else { return }
                failures[job.bookID] = AIMemoryFailure.persistence.localizedDescription
            }
            guard owners[job.bookID] == token else { return }
            if !(error is CancellationError) { failures[job.bookID] = (error as? AIMemoryFailure)?.localizedDescription ?? error.localizedDescription }
        }
    }
    func splitFailed(source: AIBookContentAdapter) async throws {
        guard activating.insert(source.chunkBookID).inserted else { throw AIMemoryFailure.cancelled }
        let revision = controlRevisions[source.chunkBookID, default: 0]
        defer { activating.remove(source.chunkBookID) }
        guard tasks[source.chunkBookID] == nil, var job = try await store.load(book: source.chunkBookID), job.sourceVersion == source.contentFingerprint else { throw AIMemoryFailure.sourceChanged }
        guard job.inFlightUnitID == nil else { throw AIMemoryFailure.resultUnknown }
        let done = Set(try await store.validatedRecords(job: job, source: source).map { $0.unit.id })
        guard let unit = job.units.filter({ !job.splitParents.contains($0.id) && !done.contains($0.id) }).sorted(by: { $0.primary.endPosition < $1.primary.endPosition }).first,
              unit.depth < 2 else { throw AIMemoryFailure.invalidPlan }
        try Task.checkCancellation()
        guard controlRevisions[job.bookID, default: 0] == revision else { throw AIMemoryFailure.cancelled }
        job.units += try AIMemoryPlanner.split(unit, source: source, job: job)
        job.splitParents.insert(unit.id); job.inFlightUnitID = nil; job.state = .paused
        try await store.save(job, writePlan: true); try await publish(job, source: source)
    }
    func view(source: AIBookContentAdapter, boundary: AIReadingBoundary) async throws -> AIMemoryView {
        try await store.view(book: source.chunkBookID, source: source, boundary: boundary)
    }
    func decide(alias: AIMemoryAlias, approved: Bool, source: AIBookContentAdapter, boundary: AIReadingBoundary) async throws {
        guard let job = try await store.load(book: source.chunkBookID) else { return }
        try await store.decide(alias: alias, approved: approved, job: job, source: source, boundary: boundary)
        revisions[job.bookID, default: 0] += 1
    }
    func clear(book: UUID) async throws {
        pause(book: book)
        try await store.clear(book: book)
        jobs[book] = nil; coverages[book] = nil; failures[book] = nil; revisions[book, default: 0] += 1
    }
}
