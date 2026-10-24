import Foundation

// MARK: - 最近搜索

/// The searches the 搜索 page offers again under 最近搜索, newest first. Kept on this
/// device in user defaults, through `@AppStorage(RecentSearchQueries.storageKey)`.
struct RecentSearchQueries: Equatable {
    static let storageKey = "yd_search_recent_queries"
    /// How many it keeps, and lists.
    static let limit = 5

    private(set) var queries: [String]

    init(queries: [String] = []) {
        self.queries = Array(queries.prefix(Self.limit))
    }

    /// The list with `query` at the front. Searching for something again lifts it rather
    /// than listing it twice; the match ignores case and full- or half-width forms.
    func recording(_ query: String) -> RecentSearchQueries {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return self }
        let others = queries.filter {
            $0.compare(trimmed, options: [.caseInsensitive, .widthInsensitive]) != .orderedSame
        }
        return RecentSearchQueries(queries: [trimmed] + others)
    }

    /// The list without the entries at `offsets` — a swipe to delete.
    func removing(atOffsets offsets: IndexSet) -> RecentSearchQueries {
        RecentSearchQueries(queries: queries.enumerated().filter { !offsets.contains($0.offset) }.map(\.element))
    }
}

extension RecentSearchQueries: RawRepresentable {
    /// A stored list that does not read back as one is logged and starts the list over.
    init?(rawValue: String) {
        do {
            let queries = try JSONDecoder().decode([String].self, from: Data(rawValue.utf8))
            self.init(queries: queries)
        } catch {
            AppLogger.error("最近搜索: stored list is unreadable, starting over", error: error)
            return nil
        }
    }

    var rawValue: String {
        do {
            return String(decoding: try JSONEncoder().encode(queries), as: UTF8.self)
        } catch {
            AppLogger.error("最近搜索: list could not be stored", error: error)
            return "[]"
        }
    }
}

// MARK: - 最近閱讀

/// What the 搜索 page lists under 最近閱讀, most recently read first: shelf books, and
/// books read that are not on the shelf — read without being added, or removed after
/// reading (`OffShelfReadRecords`). A book that is back on the shelf is listed once, as
/// the shelf book.
///
/// Clearing only moves where the list starts (`clearedAtStorageKey`). The books and
/// their reading history are untouched, so the shelf's 最近閱讀 order does not change,
/// and a book opened afterwards comes back.
enum RecentReadingSelection {
    static let clearedAtStorageKey = "yd_search_recent_reading_cleared_at"
    /// Apple Books lists three under Recently Viewed.
    static let limit = 3

    enum Entry: Identifiable {
        /// On the shelf: a tap opens it where it was left.
        case shelf(ReadingBook)
        /// Read and not on the shelf: only its name is left, so a tap searches for it.
        case record(OffShelfReadRecords.Record)

        var id: String {
            switch self {
            case .shelf(let book): "shelf:\(book.id.uuidString)"
            case .record(let record):
                "record:" + OffShelfReadRecords.bookKey(title: record.title, author: record.author)
            }
        }
    }

    static func entries(
        shelf: [ReadingBook],
        records: [OffShelfReadRecords.Record],
        clearedAt: Date?,
        limit: Int = limit
    ) -> [Entry] {
        let shelfKeys = Set(shelf.map { OffShelfReadRecords.bookKey(title: $0.title, author: $0.author) })
        let opened = shelf.compactMap { book -> (entry: Entry, date: Date)? in
            book.lastOpenedDate.map { (.shelf(book), $0) }
        }
        let offShelf = records
            .filter { !shelfKeys.contains(OffShelfReadRecords.bookKey(title: $0.title, author: $0.author)) }
            .map { (entry: Entry.record($0), date: $0.lastRead) }
        return (opened + offShelf)
            .filter { candidate in clearedAt.map { candidate.date > $0 } ?? true }
            .sorted { $0.date > $1.date }
            .prefix(limit)
            .map(\.entry)
    }

    /// The stored clearing time; 0 means the list was never cleared.
    static func clearedAt(storedValue: Double) -> Date? {
        storedValue > 0 ? Date(timeIntervalSinceReferenceDate: storedValue) : nil
    }
}
