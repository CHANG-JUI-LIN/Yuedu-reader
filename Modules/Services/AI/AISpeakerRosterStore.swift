import Combine
import Foundation

/// Holds each book's AI-verified speaker roster.
///
/// This is the single alias table every speaker lookup goes through — 多角色朗讀 casting,
/// the cast screen's list, and the character-card screen all read it. Keeping one table means
/// a name the model ruled out cannot come back through a different screen.
@MainActor
final class AISpeakerRosterStore: ObservableObject {
    static let shared = AISpeakerRosterStore()

    /// candidate → canonical name, per book. A candidate the model rejected is absent.
    @Published private(set) var rostersByBook: [UUID: [String: String]] = [:]

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "yd_ai_speaker_rosters") {
        self.defaults = defaults
        self.key = key
    }

    func safeRoster(forBook bookID: UUID, boundary: AIReadingBoundary) -> [String: String] {
        guard let data = defaults.data(forKey: storageKey(bookID) + ".boundary"),
              let stored = try? JSONDecoder().decode(AIReadingBoundary.self, from: data),
              !stored.wholeBook, boundary.contains(stored) else { return [:] }
        return roster(forBook: bookID)
    }

    func roster(forBook bookID: UUID) -> [String: String] {
        if let cached = rostersByBook[bookID] { return cached }
        return load(bookID: bookID)
    }

    /// Reads from disk into the cache. Call from `.task`/`.onAppear`, never from `body`.
    func loadIfNeeded(forBook bookID: UUID) {
        guard rostersByBook[bookID] == nil else { return }
        rostersByBook[bookID] = load(bookID: bookID)
    }

    func save(_ roster: [String: String], forBook bookID: UUID, boundary: AIReadingBoundary? = nil) {
        defaults.set(boundary.flatMap { try? JSONEncoder().encode($0) }, forKey: storageKey(bookID) + ".boundary")
        rostersByBook[bookID] = roster
        defaults.set(roster, forKey: storageKey(bookID))
    }

    func clear(forBook bookID: UUID) {
        rostersByBook[bookID] = [:]
        defaults.removeObject(forKey: storageKey(bookID))
    }

    func hasRoster(forBook bookID: UUID) -> Bool {
        !roster(forBook: bookID).isEmpty
    }

    private func load(bookID: UUID) -> [String: String] {
        defaults.dictionary(forKey: storageKey(bookID)) as? [String: String] ?? [:]
    }

    private func storageKey(_ bookID: UUID) -> String {
        "\(key).\(bookID.uuidString)"
    }
}
