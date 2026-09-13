import Foundation

/// File-backed unit ledger: a result and its committed marker are one atomic envelope.
/// Checkpoints are small headers; the plan and each unit's facts are separate files.
actor AICharacterMemoryStore {
    static let shared = AICharacterMemoryStore()
    let directory: URL
    private var matchCache: [String: Bool] = [:]
    private var records: [UUID: [String: AIMemoryRecord]] = [:]
    private struct Plan: Codable { let units: [AIMemoryUnit]; let splitParents: Set<String> }
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AICharacterMemory", isDirectory: true)
    }
    private func bookURL(_ book: UUID) -> URL { directory.appendingPathComponent(book.uuidString, isDirectory: true) }
    private func jobURL(_ job: AIMemoryJob) -> URL { bookURL(job.bookID).appendingPathComponent("jobs/\(job.id.uuidString)", isDirectory: true) }
    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: url, options: [.atomic, .completeFileProtection])
    }
    private func read<T: Decodable>(_ type: T.Type, at url: URL) throws -> T { try JSONDecoder().decode(type, from: Data(contentsOf: url)) }
    private func activeID(book: UUID) throws -> UUID? {
        let path = bookURL(book).appendingPathComponent("active.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        return try read(UUID.self, at: path)
    }
    func isActive(_ job: AIMemoryJob) throws -> Bool { try activeID(book: job.bookID) == job.id }
    func create(_ job: AIMemoryJob) throws {
        try save(job, requireActive: false, writePlan: true)
        try write(job.id, to: bookURL(job.bookID).appendingPathComponent("active.json"))
    }
    func save(_ job: AIMemoryJob, requireActive: Bool = true, writePlan: Bool = false) throws {
        if requireActive, try !isActive(job) { throw AIMemoryFailure.sourceChanged }
        if writePlan { try write(Plan(units: job.units, splitParents: job.splitParents), to: jobURL(job).appendingPathComponent("plan.json")) }
        var header = job; header.units = []; header.splitParents = []
        try write(header, to: jobURL(job).appendingPathComponent("job.json"))
    }
    func load(book: UUID) throws -> AIMemoryJob? {
        guard let id = try activeID(book: book) else { return nil }
        let base = bookURL(book).appendingPathComponent("jobs/\(id.uuidString)")
        var job = try read(AIMemoryJob.self, at: base.appendingPathComponent("job.json"))
        let plan = try read(Plan.self, at: base.appendingPathComponent("plan.json"))
        job.units = plan.units; job.splitParents = plan.splitParents
        if let inFlight = job.inFlightUnitID {
            if try allRecords(book: book)[inFlight]?.committed == true { job.inFlightUnitID = nil; job.state = .paused }
            else { job.state = .resultUnknown; job.failure = AIMemoryFailure.resultUnknown.rawValue }
        } else if job.state == .running { job.state = .paused }
        return job
    }
    private func allRecords(book: UUID) throws -> [String: AIMemoryRecord] {
        if let cached = records[book] { return cached }
        let path = bookURL(book).appendingPathComponent("records", isDirectory: true)
        guard FileManager.default.fileExists(atPath: path.path) else { records[book] = [:]; return [:] }
        var loaded: [String: AIMemoryRecord] = [:]
        for file in try FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
            let record = try read(AIMemoryRecord.self, at: file)
            if record.committed && record.schema == 1 { loaded[record.unit.id] = record }
        }
        records[book] = loaded
        return loaded
    }
    func validatedRecords(job: AIMemoryJob, source: AIBookContentAdapter) throws -> [AIMemoryRecord] {
        let all = try allRecords(book: job.bookID)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let config = AISourceManifest.digest(try encoder.encode(job.budget)) + job.analysisVersion + job.provider + job.model + job.configurationDigest
        var valid: [String: AIMemoryRecord] = [:]
        for (id, record) in all {
            let key = source.contentFingerprint + config + id
            let matches: Bool
            if let cached = matchCache[key] { matches = cached }
            else { matches = AIMemoryPlanner.matches(record, source: source, job: job); matchCache[key] = matches }
            if matches { valid[id] = record }
        }
        // Dependencies are immutable unit identities. Never re-label an old source hash.
        var removed = true
        while removed {
            let before = valid.count
            valid = valid.filter { $0.value.backgroundUnitIDs.allSatisfy { valid[$0] != nil } }
            removed = valid.count != before
        }
        return valid.values.sorted { $0.unit.primary.endPosition < $1.unit.primary.endPosition }
    }
    func commit(_ record: AIMemoryRecord, job: AIMemoryJob) throws {
        guard try isActive(job), record.unit.analysisVersion == job.analysisVersion,
              job.units.contains(where: { $0.id == record.unit.id }) else { throw AIMemoryFailure.sourceChanged }
        if try allRecords(book: job.bookID)[record.unit.id]?.committed == true { return }
        try write(record, to: bookURL(job.bookID).appendingPathComponent("records/\(record.unit.id).json"))
        records[job.bookID, default: [:]][record.unit.id] = record
        AIDiagnostics.current?.event("memoryCommitted", ["jobID": job.id.uuidString, "unitID": record.unit.id,
            "primaryUTF16": "\(record.unit.primary.end - record.unit.primary.start)"])
    }
    func decisions(book: UUID) throws -> [AIMemoryAliasDecision] {
        let path = bookURL(book).appendingPathComponent("decisions", isDirectory: true)
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { try read(AIMemoryAliasDecision.self, at: $0) }
    }
    func decide(alias: AIMemoryAlias, approved: Bool, job: AIMemoryJob, source: AIBookContentAdapter, boundary: AIReadingBoundary) throws {
        let visible = try view(book: job.bookID, source: source, boundary: boundary)
        guard visible.aliases.contains(where: { $0.id == alias.id }), boundary.sourceVersion == source.contentFingerprint else { throw AIMemoryFailure.invalidEvidence }
        let safeAfter = boundary.wholeBook ? (try validatedRecords(job: job, source: source).map(\.safeAfter).max() ?? alias.safeAfter) : .init(spine: boundary.spineIndex, utf16: boundary.utf16Offset)
        let decision = AIMemoryAliasDecision(aliasID: alias.id, approved: approved, safeAfter: max(alias.safeAfter, safeAfter), sourceVersion: source.contentFingerprint)
        // Revocation replaces only the decision, never names, mentions, facts or evidence.
        try write(decision, to: bookURL(job.bookID).appendingPathComponent("decisions/\(alias.id).json"))
    }
    func clear(book: UUID) throws {
        records[book] = nil
        matchCache.removeAll()
        let path = bookURL(book)
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }

    /// Callers only receive a source-validated, scope-projected collection.
    func view(book: UUID, source: AIBookContentAdapter, boundary: AIReadingBoundary) throws -> AIMemoryView {
        guard book == source.chunkBookID, boundary.sourceVersion == source.contentFingerprint,
              let job = try load(book: book) else { return .init(cards: [], aliases: [], approvedAliasIDs: []) }
        let valid = try validatedRecords(job: job, source: source).filter { $0.safeAfter.allowed(by: boundary) }
        return AIMemoryProjection.make(records: valid, decisions: try decisions(book: book), source: source, boundary: boundary)
    }
}

enum AIMemoryProjection {
    static func make(records: [AIMemoryRecord], decisions: [AIMemoryAliasDecision], source: AIBookContentAdapter, boundary: AIReadingBoundary) -> AIMemoryView {
        let safe = records.filter { $0.safeAfter.allowed(by: boundary) }
        var mentions: [String: AIMemoryMention] = [:]
        for mention in safe.flatMap(\.mentions) where mention.safeAfter.allowed(by: boundary) {
            if mentions[mention.id] == nil { mentions[mention.id] = mention }
        }
        let aliases = Array(Dictionary(safe.flatMap(\.aliases).filter { $0.safeAfter.allowed(by: boundary) && mentions[$0.first] != nil && mentions[$0.second] != nil }
            .map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values).sorted { $0.safeAfter < $1.safeAfter }
        let approved = Set(decisions.filter { $0.approved && $0.sourceVersion == source.contentFingerprint && $0.safeAfter.allowed(by: boundary) }.map(\.aliasID))
        // A fresh component view for this boundary; no global union-find survives a retreat.
        var groups = Dictionary(uniqueKeysWithValues: mentions.keys.map { ($0, Set([$0])) })
        for alias in aliases where approved.contains(alias.id) {
            let merged = (groups[alias.first] ?? []).union(groups[alias.second] ?? [])
            for id in merged { groups[id] = merged }
        }
        let components = Set(groups.values)
        let facts = Array(Dictionary(safe.flatMap(\.facts).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values)
        let cards = components.map { ids -> AIMemoryCard in
            let visibleMentions = ids.compactMap { mentions[$0] }.sorted { $0.evidence.span.endPosition < $1.evidence.span.endPosition }
            return .init(id: ids.sorted()[0], entityIDs: ids, names: Array(Set(visibleMentions.map(\.surface))).sorted(), mentions: visibleMentions,
                facts: facts.filter { !$0.entities.filter(ids.contains).isEmpty && $0.safeAfter.allowed(by: boundary) }.sorted {
                    let a = $0.evidence.map { $0.span.endPosition }.min()!, b = $1.evidence.map { $0.span.endPosition }.min()!
                    return a == b ? $0.id < $1.id : a < b
                }, aliases: aliases.filter { ids.contains($0.first) || ids.contains($0.second) })
        }.sorted { $0.id < $1.id }
        AIDiagnostics.current?.event("memoryView", ["sourceVersion": source.contentFingerprint, "spine": "\(boundary.spineIndex)",
            "utf16": "\(boundary.utf16Offset)", "wholeBook": "\(boundary.wholeBook)", "visibleCards": "\(cards.count)", "visibleAliases": "\(aliases.count)"])
        return .init(cards: cards, aliases: aliases, approvedAliasIDs: approved.intersection(aliases.map(\.id)))
    }
}
