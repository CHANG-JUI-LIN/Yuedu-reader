import Foundation
import Combine

// MARK: - ReadingSession

struct ReadingSession: Codable, Identifiable {
    let id: UUID
    let bookId: String
    let bookTitle: String
    let startDate: Date
    let duration: TimeInterval
    let charactersRead: Int
}

// MARK: - ReadingStatsSessionTracker

struct ReadingStatsSessionTracker {
    let bookId: String
    let bookTitle: String
    let startDate: Date
    private var startCharacterOffset: Int?
    private var latestCharacterOffset: Int?

    init(
        bookId: String,
        bookTitle: String,
        startDate: Date = Date(),
        startCharacterOffset: Int? = nil
    ) {
        self.bookId = bookId
        self.bookTitle = bookTitle
        self.startDate = startDate
        self.startCharacterOffset = startCharacterOffset
        self.latestCharacterOffset = startCharacterOffset
    }

    mutating func updateVisibleCharacterOffset(_ offset: Int?) {
        guard let offset else { return }
        if startCharacterOffset == nil {
            startCharacterOffset = offset
        }
        latestCharacterOffset = offset
    }

    func finish(at endDate: Date = Date()) -> ReadingSession? {
        let duration = endDate.timeIntervalSince(startDate)
        guard duration > 0 else { return nil }

        let charactersRead: Int
        if let startCharacterOffset, let latestCharacterOffset {
            charactersRead = max(0, latestCharacterOffset - startCharacterOffset)
        } else {
            charactersRead = 0
        }

        return ReadingSession(
            id: UUID(),
            bookId: bookId,
            bookTitle: bookTitle,
            startDate: startDate,
            duration: duration,
            charactersRead: charactersRead
        )
    }
}

// MARK: - ReadingStatsStore

class ReadingStatsStore: ObservableObject {
    static let shared = ReadingStatsStore()

    @Published var sessions: [ReadingSession] = []

    private static let defaultFileURL: URL = {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        return lib.appendingPathComponent("reading_stats.json")
    }()

    private let fileURL: URL

    init(fileURL: URL = ReadingStatsStore.defaultFileURL) {
        self.fileURL = fileURL
        load()
    }

    // MARK: - Public API

    func recordSession(_ session: ReadingSession) {
        sessions.append(session)
        save()
    }

    func startSession(bookId: String, bookTitle: String) -> Date {
        return Date()
    }

    func endSession(startTime: Date, bookId: String, bookTitle: String, charactersRead: Int) {
        let duration = Date().timeIntervalSince(startTime)
        let session = ReadingSession(
            id: UUID(),
            bookId: bookId,
            bookTitle: bookTitle,
            startDate: startTime,
            duration: duration,
            charactersRead: charactersRead
        )
        recordSession(session)
    }

    func sessionsInRange(from: Date, to: Date) -> [ReadingSession] {
        sessions.filter { $0.startDate >= from && $0.startDate <= to }
    }

    func totalDuration(in sessions: [ReadingSession]) -> TimeInterval {
        sessions.reduce(0) { $0 + $1.duration }
    }

    func totalCharacters(in sessions: [ReadingSession]) -> Int {
        sessions.reduce(0) { $0 + $1.charactersRead }
    }

    func topBooks(limit: Int, sessions: [ReadingSession]) -> [(bookTitle: String, duration: TimeInterval)] {
        var durationByTitle: [String: TimeInterval] = [:]
        for session in sessions {
            durationByTitle[session.bookTitle, default: 0] += session.duration
        }
        return durationByTitle
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { (bookTitle: $0.key, duration: $0.value) }
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([ReadingSession].self, from: data)
        else { return }
        sessions = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
