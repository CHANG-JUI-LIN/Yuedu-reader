import Foundation

/// Books read that are no longer on the shelf, kept the way legado keeps its 閱讀記錄,
/// which outlives the book: an online book read or listened to without being added — a
/// book read stays off the shelf, an audiobook goes once its player closes — and a book
/// removed from the shelf after it was read. Only the name, author and cover stay behind.
/// 搜索's 最近閱讀 lists them beside the shelf's books and searches for one by name again,
/// as legado opens a record whose book is gone.
///
/// Kept on this device in user defaults, where `@AppStorage(OffShelfReadRecords.storageKey)`
/// reads it.
struct OffShelfReadRecords: Equatable {
    struct Record: Codable, Equatable {
        let title: String
        let author: String
        let coverUrl: String
        let lastRead: Date
    }

    static let storageKey = "yd_off_shelf_read_records"
    /// How many it keeps, newest first.
    static let limit = 10

    private(set) var records: [Record]

    init(records: [Record] = []) {
        self.records = Array(records.prefix(Self.limit))
    }

    /// The records with `record` at the front, in place of an older one for the same book.
    func recording(_ record: Record) -> OffShelfReadRecords {
        let key = Self.bookKey(title: record.title, author: record.author)
        let others = records.filter { Self.bookKey(title: $0.title, author: $0.author) != key }
        return OffShelfReadRecords(records: [record] + others)
    }

    /// One book, whatever its title's width and spacing — the key search results merge by.
    static func bookKey(title: String, author: String) -> String {
        SearchBook.makeKey(name: title, author: author)
    }

    /// Notes a book read, or being read, that is not on the shelf.
    static func record(
        title: String,
        author: String,
        coverUrl: String,
        at date: Date = Date(),
        defaults: UserDefaults = .standard
    ) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let stored = defaults.string(forKey: storageKey).flatMap(OffShelfReadRecords.init(rawValue:))
            ?? OffShelfReadRecords()
        let updated = stored.recording(
            Record(title: trimmed, author: author, coverUrl: coverUrl, lastRead: date)
        )
        defaults.set(updated.rawValue, forKey: storageKey)
    }
}

extension OffShelfReadRecords: RawRepresentable {
    /// A stored list that does not read back as one is logged and starts the list over.
    init?(rawValue: String) {
        do {
            let records = try JSONDecoder().decode([Record].self, from: Data(rawValue.utf8))
            self.init(records: records)
        } catch {
            AppLogger.error("Off-shelf read records: stored list is unreadable, starting over", error: error)
            return nil
        }
    }

    var rawValue: String {
        do {
            return String(decoding: try JSONEncoder().encode(records), as: UTF8.self)
        } catch {
            AppLogger.error("Off-shelf read records: list could not be stored", error: error)
            return "[]"
        }
    }
}
