import Foundation

/// One turn in the reader's conversation about a book.
struct AIChatMessage: Identifiable, Equatable, Codable, Sendable {
    enum Role: String, Codable, Sendable {
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
    var provenance: AIChatProvenance? = nil
    var notices: [String]? = nil

    private enum CodingKeys: String, CodingKey {
        case id, role, text, citations, isPending, errorMessage, hasEvidence, createdAt, provenance, notices
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        role = try values.decode(Role.self, forKey: .role)
        text = try values.decode(String.self, forKey: .text)
        citations = try values.decodeIfPresent([LLMCitation].self, forKey: .citations) ?? []
        isPending = try values.decodeIfPresent(Bool.self, forKey: .isPending) ?? false
        errorMessage = try values.decodeIfPresent(String.self, forKey: .errorMessage)
        hasEvidence = try values.decodeIfPresent(Bool.self, forKey: .hasEvidence) ?? false
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        // Incomplete provenance means unknown scope, not a reason to delete old prose.
        // This compatibility path is removable once legacy chats are no longer supported.
        do { provenance = try values.decodeIfPresent(AIChatProvenance.self, forKey: .provenance) }
        catch { provenance = nil; AppLogger.error("AI chat provenance invalid; preserving history without context eligibility") }
        do { notices = try values.decodeIfPresent([String].self, forKey: .notices) }
        catch { notices = nil; AppLogger.error("AI chat notices invalid; preserving history") }
    }

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
struct AIChatSession: Identifiable, Equatable, Codable, Sendable {
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

extension AIChatSession {
    /// Retry replaces the failed assistant slot while retaining the original user identity.
    /// A completed or pending turn cannot be appended again by a double tap.
    mutating func prepareQuestion(_ question: String, metadata: AIChatProvenance, retrying userID: UUID? = nil) -> (user: UUID, assistant: UUID)? {
        guard metadata.conversationID == id, !messages.contains(where: \.isPending) else { return nil }
        let user: UUID
        if let userID {
            guard let i = messages.firstIndex(where: { $0.id == userID && $0.role == .user && $0.text == question }),
                  i + 1 == messages.count - 1,
                  messages[i + 1].role == .assistant, messages[i + 1].errorMessage != nil else { return nil }
            messages.remove(at: i + 1)
            messages[i].provenance = metadata
            user = userID
        } else {
            var message = AIChatMessage(role: .user, text: question)
            message.provenance = metadata
            messages.append(message)
            user = message.id
        }
        var assistant = AIChatMessage(role: .assistant, text: "", isPending: true)
        assistant.provenance = metadata
        messages.append(assistant)
        return (user, assistant.id)
    }
}
