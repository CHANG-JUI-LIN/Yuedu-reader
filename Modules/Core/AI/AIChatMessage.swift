import Foundation

/// One turn in the reader's conversation about a book.
struct AIChatMessage: Identifiable, Equatable, Codable {
    enum Role: String, Codable {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    var text: String
    var citations: [LLMCitation]
    /// True while the answer is still being produced. A pending assistant turn is what the
    /// typing indicator is attached to, so the reader sees the request was accepted rather
    /// than wondering whether the send button worked.
    var isPending: Bool
    /// Set when the turn failed. Kept on the message rather than in a banner so the failure
    /// stays attached to the question that caused it.
    var errorMessage: String?
    /// `false` when the answer cited nothing from the book.
    var hasEvidence: Bool
    let createdAt: Date

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        citations: [LLMCitation] = [],
        isPending: Bool = false,
        errorMessage: String? = nil,
        hasEvidence: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.citations = citations
        self.isPending = isPending
        self.errorMessage = errorMessage
        self.hasEvidence = hasEvidence
        self.createdAt = createdAt
    }
}

/// One conversation about a book.
///
/// Opening the assistant starts a new one, the way a chat app does — the previous thread is
/// not lost, it moves into the list. Carrying on yesterday's conversation about a chapter you
/// have since read past is rarely what anyone wants.
struct AIChatSession: Identifiable, Equatable, Codable {
    let id: UUID
    var messages: [AIChatMessage]
    let createdAt: Date

    init(id: UUID = UUID(), messages: [AIChatMessage] = [], createdAt: Date = Date()) {
        self.id = id
        self.messages = messages
        self.createdAt = createdAt
    }

    /// The first thing the reader asked, which is what a conversation is actually about.
    var title: String {
        let first = messages.first { $0.role == .user }?.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first, !first.isEmpty else { return localized("新對話") }
        return String(first.prefix(40))
    }

    var isEmpty: Bool { messages.isEmpty }
}

/// A suggested opening, offered as a chip above the input.
///
/// 前情提要 is one of these rather than a screen of its own: it is a question the reader asks
/// the assistant ("remind me where I was"), and giving it a tab made it look like a separate
/// feature with its own state.
struct AIChatSuggestion: Identifiable, Equatable {
    enum Kind: Equatable {
        /// Runs the recap pipeline, which is not a plain question — it seeds from the most
        /// recent already-read passages rather than retrieving against a query.
        case recap
        /// Fills the input with this text and sends it.
        case prompt(String)
    }

    let id: String
    let title: String
    let symbol: String
    let kind: Kind

    static let all: [AIChatSuggestion] = [
        AIChatSuggestion(
            id: "recap",
            title: "前情提要",
            symbol: "text.book.closed",
            kind: .recap
        ),
        AIChatSuggestion(
            id: "recent",
            title: "剛剛發生了什麼",
            symbol: "clock.arrow.circlepath",
            kind: .prompt("我剛剛讀到的這一段發生了什麼事？")
        ),
    ]
}
