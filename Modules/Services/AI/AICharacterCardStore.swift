import Combine
import Foundation

/// The character cards built for each book.
///
/// Kept on disk rather than recomputed because each card costs the user a real API call, and
/// because 多角色朗讀 reads the alias table on every chapter — a listener should not have to
/// wait on the network to find out that 塵哥 is 張若塵.
@MainActor
final class AICharacterCardStore: ObservableObject {
    static let shared = AICharacterCardStore()

    @Published private(set) var profilesByBook: [UUID: [AICharacterProfile]] = [:]

    private let directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.directory = base.appendingPathComponent("AICharacterCards", isDirectory: true)
        }
    }

    /// What is already in memory for this book. A pure read: populating the cache from here
    /// would write `@Published` state during a SwiftUI view update, which this project has
    /// already shipped once as "Publishing changes from within view updates".
    func profiles(forBook bookID: UUID) -> [AICharacterProfile] {
        profilesByBook[bookID] ?? []
    }

    /// Reads this book's cards off disk. Call it from `.task`/`.onAppear`, never from `body`.
    func loadIfNeeded(forBook bookID: UUID) {
        guard profilesByBook[bookID] == nil else { return }
        profilesByBook[bookID] = load(bookID: bookID)
    }

    /// Adds or replaces one character's card. Replacing by name rather than appending is what
    /// makes 「重新整理」 update a card instead of stacking a second one beside it.
    func upsert(_ profile: AICharacterProfile, forBook bookID: UUID) {
        loadIfNeeded(forBook: bookID)
        var current = profiles(forBook: bookID)
        if let index = current.firstIndex(where: { $0.name == profile.name }) {
            current[index] = profile
        } else {
            current.append(profile)
        }
        profilesByBook[bookID] = current
        save(current, bookID: bookID)
    }

    func remove(name: String, forBook bookID: UUID) {
        loadIfNeeded(forBook: bookID)
        let current = profiles(forBook: bookID).filter { $0.name != name }
        profilesByBook[bookID] = current
        save(current, bookID: bookID)
    }

    /// Alias → canonical name for 多角色朗讀.
    ///
    /// This is the single crossing point between the AI work and the read-aloud work: the
    /// dialogue heuristic can tell that someone spoke, but only the cards know that 張若塵,
    /// 若塵 and 塵哥 are one person who should get one voice.
    func aliasMap(forBook bookID: UUID) -> [String: String] {
        loadIfNeeded(forBook: bookID)
        return AICharacterAliasTable.aliasMap(for: profiles(forBook: bookID))
    }

    // MARK: - Persistence

    private func fileURL(for bookID: UUID) -> URL {
        directory.appendingPathComponent("\(bookID.uuidString).json")
    }

    private func load(bookID: UUID) -> [AICharacterProfile] {
        guard let data = try? Data(contentsOf: fileURL(for: bookID)) else { return [] }
        do {
            return try JSONDecoder().decode([AICharacterProfile].self, from: data)
        } catch {
            AppLogger.error("AI character cards unreadable", context: [
                "book": bookID.uuidString,
                "error": error.localizedDescription,
            ])
            return []
        }
    }

    private func save(_ profiles: [AICharacterProfile], bookID: UUID) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(profiles).write(to: fileURL(for: bookID), options: .atomic)
        } catch {
            AppLogger.error("AI character cards not saved", context: [
                "book": bookID.uuidString,
                "error": error.localizedDescription,
            ])
        }
    }
}
