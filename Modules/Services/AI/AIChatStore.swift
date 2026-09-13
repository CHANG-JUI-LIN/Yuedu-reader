import Foundation

/// Keeps each book's conversations.
///
/// A chat the reader paid for should still be there when they reopen the book, and opening
/// the assistant starts a fresh thread rather than resuming a stale one — so this stores a
/// list, newest first, not a single transcript.
final class AIChatStore {
    static let shared = AIChatStore()

    /// Bounds what one book can accumulate in UserDefaults.
    static let maximumSessions = 30
    static let maximumMessagesPerSession = 60

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "yd_ai_chats") {
        self.defaults = defaults
        self.key = key
    }

    /// Newest first.
    func sessions(forBook bookID: UUID) -> [AIChatSession] {
        guard let data = defaults.data(forKey: storageKey(bookID)),
              let decoded = try? JSONDecoder().decode([AIChatSession].self, from: data)
        else { return [] }
        return decoded
    }

    /// Inserts or replaces one conversation. An empty one is not stored — opening the panel
    /// and closing it again should not leave a row behind.
    func save(_ session: AIChatSession, forBook bookID: UUID) {
        var all = sessions(forBook: bookID).filter { $0.id != session.id }
        if !session.isEmpty {
            var trimmed = session
            // A turn still pending when the app died is not an answer; it must not come
            // back as a bubble that spins forever.
            trimmed.messages = Array(
                session.messages.filter { !$0.isPending }.suffix(Self.maximumMessagesPerSession)
            )
            if !trimmed.isEmpty { all.insert(trimmed, at: 0) }
        }
        write(Array(all.prefix(Self.maximumSessions)), forBook: bookID)
    }

    func delete(sessionID: UUID, forBook bookID: UUID) {
        write(sessions(forBook: bookID).filter { $0.id != sessionID }, forBook: bookID)
    }

    func clear(forBook bookID: UUID) {
        defaults.removeObject(forKey: storageKey(bookID))
    }

    private func write(_ sessions: [AIChatSession], forBook bookID: UUID) {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        defaults.set(data, forKey: storageKey(bookID))
    }

    private func storageKey(_ bookID: UUID) -> String {
        "\(key).\(bookID.uuidString)"
    }
}
