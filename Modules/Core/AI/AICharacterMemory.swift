import Foundation

struct AIMemoryPosition: Codable, Hashable, Sendable, Comparable {
    let spine: Int
    let utf16: Int
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.spine == rhs.spine ? lhs.utf16 < rhs.utf16 : lhs.spine < rhs.spine }
    func allowed(by boundary: AIReadingBoundary) -> Bool {
        boundary.wholeBook || self <= .init(spine: boundary.spineIndex, utf16: boundary.utf16Offset)
    }
}

struct AIMemorySpan: Codable, Hashable, Sendable {
    let sectionID: String
    let chapterDigest: String
    let transformation: String
    let spine: Int
    let start: Int
    let end: Int
    var endPosition: AIMemoryPosition { .init(spine: spine, utf16: end) }
    func text(in source: AIBookContentAdapter) -> String? {
        guard source.chunkSections.indices.contains(spine), source.manifest.transformationVersion == transformation,
              source.manifest.chapters[spine].id == sectionID, source.manifest.chapters[spine].digest == chapterDigest,
              start >= 0, end > start else { return nil }
        let text = source.chunkSections[spine].text
        guard let range = Range(NSRange(location: start, length: end - start), in: text),
              text.indices.contains(range.lowerBound), range.upperBound == text.endIndex || text.indices.contains(range.upperBound) else { return nil }
        return String(text[range])
    }
}

struct AIMemoryBudget: Codable, Hashable, Sendable {
    var unitCharacters = 1_200
    var auxiliaryCharacters = 200
    var maximumInputCharacters = 10_000
    var maximumInputBytes = 32_000
    var outputTokens = 4_096
    var maximumCalls = 100
    /// Explicitly opt in to at most this many automatic bisections per original unit.
    var automaticSplitDepth = 0
    var maximumBackgroundRecords = 8
}

struct AIMemoryUnit: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let primary: AIMemorySpan
    let auxiliary: AIMemorySpan?
    let dependencyDigest: String
    let analysisVersion: String
    let parentID: String?
    let depth: Int
}

struct AIMemoryJob: Codable, Identifiable, Sendable {
    enum State: String, Codable, Sendable {
        case paused, running, budgetPaused, failed, resultUnknown, completedAvailable, cancelled, superseded
    }
    let id: UUID
    let bookID: UUID
    let sourceVersion: String
    let manifest: AISourceManifest
    let boundary: AIReadingBoundary
    let provider: String
    let model: String
    let analysisVersion: String
    var configurationDigest = ""
    var providerDisplayName = ""
    var budget: AIMemoryBudget
    var units: [AIMemoryUnit]
    var splitParents: Set<String> = []
    var calls = 0
    var inFlightUnitID: String?
    var state: State = .paused
    var failure: String?
    let createdAt: Date
    var targetChapters: Int {
        boundary.wholeBook ? manifest.chapters.count : min(manifest.chapters.count, boundary.spineIndex + 1)
    }
}

struct AIMemoryEvidence: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let segmentID: String
    let unitID: String
    let span: AIMemorySpan
    let quote: String
    func citation(source: AIBookContentAdapter) -> LLMCitation? {
        guard span.text(in: source) == quote else { return nil }
        var result = LLMCitation(chunkID: id, quote: quote, spineIndex: span.spine, charOffset: span.start)
        result.sourceVersion = source.contentFingerprint
        result.coordinateUnit = "sourceUTF16"
        return result
    }
}

struct AIMemoryMention: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let entityID: String
    let surface: String
    let unresolved: Bool
    let evidence: AIMemoryEvidence
    let safeAfter: AIMemoryPosition
}

struct AIMemoryFact: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case narration, statement, rumor, interpretation, correction, relationship }
    let id: String
    let entities: [String]
    let kind: Kind
    let text: String
    let evidence: [AIMemoryEvidence]
    let safeAfter: AIMemoryPosition
}

/// A proposal never changes original entity IDs. Approval/retraction is an independent,
/// scoped record; the safe projection constructs equivalence only from visible approvals.
struct AIMemoryAlias: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let first: String
    let second: String
    let evidence: [AIMemoryEvidence]
    let safeAfter: AIMemoryPosition
}
struct AIMemoryAliasDecision: Codable, Sendable {
    let aliasID: String
    let approved: Bool
    let safeAfter: AIMemoryPosition
    let sourceVersion: String
}

struct AIMemoryRecord: Codable, Sendable {
    let schema: Int
    let unit: AIMemoryUnit
    let sourceVersion: String
    let backgroundUnitIDs: [String]
    let safeAfter: AIMemoryPosition
    let mentions: [AIMemoryMention]
    let facts: [AIMemoryFact]
    let aliases: [AIMemoryAlias]
    let committed: Bool
}

struct AIMemoryCard: Identifiable, Sendable {
    let id: String
    let entityIDs: Set<String>
    let names: [String]
    let mentions: [AIMemoryMention]
    let facts: [AIMemoryFact]
    let aliases: [AIMemoryAlias]
    var earliest: AIMemoryMention? { mentions.min { $0.evidence.span.endPosition < $1.evidence.span.endPosition } }
}

struct AIMemoryView: Sendable {
    let cards: [AIMemoryCard]
    let aliases: [AIMemoryAlias]
    let approvedAliasIDs: Set<String>
    /// Computed after source and dependency filtering. Never a whole-book count in safe UI.
    var count: Int { cards.count }
    func page(query: String = "", offset: Int = 0, limit: Int = 40) -> [AIMemoryCard] {
        Array(cards.filter { query.isEmpty || $0.names.contains { $0.localizedCaseInsensitiveContains(query) } }
            .dropFirst(max(0, offset)).prefix(max(0, limit)))
    }
    func lookup(_ surface: String) -> [String] { cards.filter { $0.names.contains(surface) }.map(\.id) }
}

enum AIMemoryFailure: String, Error, LocalizedError, Sendable {
    case invalidPlan, invalidEvidence, invalidSchema, sourceChanged, providerChanged, budget, resultUnknown, persistence, cancelled
    var errorDescription: String? {
        switch self {
        case .invalidPlan: return localized("無法在目前正文與預算內規劃人物分析批次。")
        case .invalidEvidence: return localized("抽取引用無法唯一核對，該批未保存。")
        case .invalidSchema: return localized("人物抽取格式不完整，該批未保存。")
        case .sourceChanged: return localized("正文來源已變更，請重新規劃；可核對的舊批次會重用。")
        case .providerChanged: return localized("生成服務或模型已變更，請重新確認建檔工作。")
        case .budget: return localized("人物建檔呼叫預算已用盡，請確認增加額度後續跑。")
        case .resultUnknown: return localized("上一批可能已呼叫並計費，但尚無已保存結果；續跑可能再次計費。")
        case .persistence: return localized("人物資料保存失敗，尚未保存的範圍不計入完成。")
        case .cancelled: return localized("人物建檔已暫停。")
        }
    }
}
