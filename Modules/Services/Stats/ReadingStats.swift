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

struct ReadingStatsTrackingPosition: Equatable, Sendable {
    enum CharacterScope: Equatable, Sendable {
        case global
        case spine(Int)
    }

    let characterScope: CharacterScope
    let characterOffset: Int
    let globalContentUnitOffset: Int?

    static func spine(
        _ spineIndex: Int,
        characterOffset: Int,
        globalContentUnitOffset: Int? = nil
    ) -> Self {
        Self(
            characterScope: .spine(spineIndex),
            characterOffset: characterOffset,
            globalContentUnitOffset: globalContentUnitOffset
        )
    }

    static func global(
        characterOffset: Int,
        globalContentUnitOffset: Int? = nil
    ) -> Self {
        Self(
            characterScope: .global,
            characterOffset: characterOffset,
            globalContentUnitOffset: globalContentUnitOffset
        )
    }
}

struct ReadingStatsSessionTracker {
    static let maximumContinuousAdvance = 50_000

    let bookId: String
    let bookTitle: String
    let startDate: Date
    private var baselinePosition: ReadingStatsTrackingPosition?
    private var baselineContentUnitOffset: Int?
    private var accumulatedCharactersRead = 0
    private var accumulatedContentUnitsRead = 0

    init(
        bookId: String,
        bookTitle: String,
        startDate: Date = Date(),
        startPosition: ReadingStatsTrackingPosition? = nil
    ) {
        self.bookId = bookId
        self.bookTitle = bookTitle
        self.startDate = startDate
        self.baselinePosition = startPosition
        self.baselineContentUnitOffset = startPosition?.globalContentUnitOffset
    }

    mutating func updateVisiblePosition(_ position: ReadingStatsTrackingPosition?) {
        guard let position else { return }
        guard position.characterOffset >= 0 else {
            baselinePosition = nil
            baselineContentUnitOffset = nil
            return
        }

        let priorPosition = baselinePosition
        baselinePosition = position
        if let priorPosition,
           priorPosition.characterScope == position.characterScope {
            accumulatedCharactersRead = Self.accumulating(
                from: priorPosition.characterOffset,
                to: position.characterOffset,
                onto: accumulatedCharactersRead
            )
        }

        let priorContentUnitOffset = baselineContentUnitOffset
        baselineContentUnitOffset = position.globalContentUnitOffset
        if let priorContentUnitOffset,
           let contentUnitOffset = position.globalContentUnitOffset {
            accumulatedContentUnitsRead = Self.accumulating(
                from: priorContentUnitOffset,
                to: contentUnitOffset,
                onto: accumulatedContentUnitsRead
            )
        }
    }

    mutating func relocate(to position: ReadingStatsTrackingPosition?) {
        guard let position, position.characterOffset >= 0 else {
            baselinePosition = nil
            baselineContentUnitOffset = nil
            return
        }
        baselinePosition = position
        baselineContentUnitOffset = position.globalContentUnitOffset
    }

    func currentMetrics(at date: Date = Date()) -> (elapsed: TimeInterval, charactersRead: Int) {
        let rawElapsed = date.timeIntervalSince(startDate)
        let elapsed = rawElapsed.isFinite ? max(0, rawElapsed) : 0
        return (elapsed, accumulatedCharactersRead)
    }

    func currentPaceMetrics(
        at date: Date = Date()
    ) -> (elapsed: TimeInterval, contentUnitsRead: Int) {
        let rawElapsed = date.timeIntervalSince(startDate)
        let elapsed = rawElapsed.isFinite ? max(0, rawElapsed) : 0
        return (elapsed, accumulatedContentUnitsRead)
    }

    func finish(at endDate: Date = Date()) -> ReadingSession? {
        let duration = endDate.timeIntervalSince(startDate)
        guard duration > 0 else { return nil }

        return ReadingSession(
            id: UUID(),
            bookId: bookId,
            bookTitle: bookTitle,
            startDate: startDate,
            duration: duration,
            charactersRead: accumulatedCharactersRead
        )
    }

    private static func accumulating(
        from baseline: Int,
        to offset: Int,
        onto total: Int
    ) -> Int {
        let (delta, overflow) = offset.subtractingReportingOverflow(baseline)
        guard !overflow,
              delta > 0,
              delta <= Self.maximumContinuousAdvance
        else {
            return total
        }

        let (next, totalOverflow) = total.addingReportingOverflow(delta)
        return totalOverflow ? .max : next
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
