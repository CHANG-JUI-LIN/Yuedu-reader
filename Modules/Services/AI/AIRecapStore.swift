import Foundation

/// Stores one recap per book.
///
/// Small enough for UserDefaults, and it has to survive a relaunch: a recap the reader paid
/// for should still be there when they come back tomorrow, which is exactly when they want it.
final class AIRecapStore {
    static let shared = AIRecapStore()

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "yd_ai_recaps") {
        self.defaults = defaults
        self.key = key
    }

    func recap(forBook bookID: UUID) -> AIRecap? {
        guard let data = defaults.data(forKey: storageKey(bookID)) else { return nil }
        return try? JSONDecoder().decode(AIRecap.self, from: data)
    }

    func save(_ recap: AIRecap, forBook bookID: UUID) {
        guard let data = try? JSONEncoder().encode(recap) else { return }
        defaults.set(data, forKey: storageKey(bookID))
    }

    func clear(forBook bookID: UUID) {
        defaults.removeObject(forKey: storageKey(bookID))
    }

    private func storageKey(_ bookID: UUID) -> String {
        "\(key).\(bookID.uuidString)"
    }
}
