import Foundation

/// The categories the reader picked for 同題材作品 (maintainer, 2026-10-15): a genre picked from
/// the book's own genres is the source's preference, read first by every book of the source
/// whose genres include it, the latest pick first; a category picked from 其他分類 is none of
/// the book's genres and holds for that book only. On this device only, as the reading genre
/// profile is (UserDefaults `yd_related_category_choice`).
@MainActor
final class RelatedCategoryChoiceStore {
    static let shared = RelatedCategoryChoiceStore()
    nonisolated static let defaultsKey = "yd_related_category_choice"
    /// Preferences kept per source, latest first.
    static let preferencesPerSource = 20
    /// Book picks kept in all, the oldest dropped first.
    static let bookPickLimit = 300

    private struct BookPick: Codable, Equatable {
        var source: String
        var book: String
        var title: String
    }

    private struct Stored: Codable {
        var sources: [String: [String]] = [:]
        /// Oldest first.
        var books: [BookPick] = []
    }

    private let defaults: UserDefaults
    private var stored: Stored

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        stored = Self.read(defaults)
    }

    /// The genres picked for `source`, latest first.
    func preferred(source: String) -> [String] {
        stored.sources[source] ?? []
    }

    /// The category picked from 其他分類 for `book`.
    func bookPick(source: String, book: String) -> String? {
        stored.books.last { $0.source == source && $0.book == book }?.title
    }

    /// - Parameter fromGenres: whether `title` is one of the book's genres.
    func record(_ title: String, fromGenres: Bool, source: String, book: String) {
        let key = SourceGenreMatching.normalized(title)
        guard !key.isEmpty else { return }
        stored.books.removeAll { $0.source == source && $0.book == book }
        if fromGenres {
            var list = stored.sources[source] ?? []
            list.removeAll { SourceGenreMatching.normalized($0) == key }
            list.insert(title, at: 0)
            stored.sources[source] = Array(list.prefix(Self.preferencesPerSource))
        } else {
            stored.books.append(BookPick(source: source, book: book, title: title))
            if stored.books.count > Self.bookPickLimit {
                stored.books.removeFirst(stored.books.count - Self.bookPickLimit)
            }
        }
        write()
    }

    private func write() {
        do {
            defaults.set(try JSONEncoder().encode(stored), forKey: Self.defaultsKey)
        } catch {
            AppLogger.error("Related category choices could not be saved", error: error, level: .warning)
        }
    }

    private static func read(_ defaults: UserDefaults) -> Stored {
        guard let data = defaults.data(forKey: defaultsKey) else { return Stored() }
        do {
            return try JSONDecoder().decode(Stored.self, from: data)
        } catch {
            AppLogger.error("Related category choices were unreadable and start empty", error: error, level: .warning)
            return Stored()
        }
    }
}
