import Foundation

/// One budget for the entire question, including resolution and a single revision.
struct AIQuestionBudget: Codable, Equatable, Sendable {
    var maximumModelCalls = 4
    var maximumQueries = 5
    var maximumInputCharacters = 16_000
    var maximumInputBytes = 48_000
    var maximumHistoryBytes = 6_000
    var maximumHistoryMessages = 6
    var maximumOutputTokens = 1_024
}

struct AIQuestionEvidence: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case initial, supplemental, adjacent, prefix, currentPosition }
    let chunk: AIContentChunk
    let parentChunkID: String
    let kind: Kind
}

/// Records the whole dependency ceiling, not just the final citations. Optional on legacy turns.
struct AIChatProvenance: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable { case pending, completed, failed, cancelled }
    let requestID: UUID
    let bookID: UUID
    let conversationID: UUID
    let boundary: AIReadingBoundary
    var status: Status
    var sentEvidence: [AIQuestionEvidence] = []
    var finalEvidenceIDs: [String] = []
    var historyMessageIDs: [UUID] = []

    func isSafe(book: UUID, conversation: UUID, at boundary: AIReadingBoundary) -> Bool {
        bookID == book && conversationID == conversation && status == .completed && boundary.contains(self.boundary)
    }
}

struct AIQuestionContext: Sendable {
    let requestID: UUID
    let bookID: UUID
    let conversationID: UUID
    let question: String
    let source: AIBookContentAdapter
    let boundary: AIReadingBoundary
    let history: [AIChatMessage]
    var budget = AIQuestionBudget()

    init(requestID: UUID = UUID(), bookID: UUID, conversationID: UUID = UUID(), question: String,
         source: AIBookContentAdapter, boundary: AIReadingBoundary, history: [AIChatMessage] = [],
         budget: AIQuestionBudget = .init()) {
        self.requestID = requestID; self.bookID = bookID; self.conversationID = conversationID
        self.question = question; self.source = source; self.boundary = boundary
        self.history = history; self.budget = budget
    }

    func safeHistory() -> [AIChatMessage] {
        var accepted: [AIChatMessage] = []
        for message in history {
            let reason: String?
            if message.isPending || message.errorMessage != nil { reason = "unfinished" }
            else if let metadata = message.provenance {
                if metadata.bookID != bookID || metadata.conversationID != conversationID { reason = "differentConversation" }
                else if metadata.boundary.sourceVersion != boundary.sourceVersion { reason = "sourceChanged" }
                else if !metadata.isSafe(book: bookID, conversation: conversationID, at: boundary) { reason = "unsafeScopeOrStatus" }
                else { reason = nil }
            } else { reason = "legacyUnknownScope" }
            if let reason { AIDiagnostics.current?.event("historyExcluded", ["messageID": message.id.uuidString, "reason": reason]) }
            else { accepted.append(message) }
        }
        var bytes = 0
        var selected: [AIChatMessage] = []
        var exhausted = false
        for message in accepted.reversed() {
            let size = message.text.utf8.count
            if !exhausted, selected.count < max(0, budget.maximumHistoryMessages), bytes + size <= max(0, budget.maximumHistoryBytes) {
                selected.append(message); bytes += size
            } else {
                exhausted = true
                AIDiagnostics.current?.event("historyExcluded", ["messageID": message.id.uuidString, "reason": "historyBudget"])
            }
        }
        return selected.reversed()
    }
}

enum AIQuestionFailure: Error, LocalizedError {
    case contextBudget, modelBudget
    var errorDescription: String? {
        switch self {
        case .contextBudget: return localized("問題與必要背景超出本次上下文預算，請縮短問題或另開對話。")
        case .modelBudget: return localized("本次 AI 呼叫預算已用盡。")
        }
    }
}

enum AIQuestionStage: String, Sendable {
    case searching, supplementing, answering
    var label: String {
        switch self {
        case .searching: return localized("搜尋原文…")
        case .supplementing: return localized("補查原文…")
        case .answering: return localized("整理答案…")
        }
    }
}

/// A request owner shared by the UI's question and recap paths. Advancing remains safe.
struct AIChatRequestOwner: Equatable {
    let requestID: UUID
    let conversationID: UUID
    let bookID: UUID
    let boundary: AIReadingBoundary
    func canPublish(requestID: UUID?, conversationID: UUID, bookID: UUID, boundary: AIReadingBoundary) -> Bool {
        self.requestID == requestID && self.conversationID == conversationID && self.bookID == bookID && boundary.contains(self.boundary)
    }
}
