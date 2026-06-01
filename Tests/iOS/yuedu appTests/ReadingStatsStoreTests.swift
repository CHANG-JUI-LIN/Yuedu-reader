import Foundation
import Testing
@testable import yuedu_app

struct ReadingStatsStoreTests {
    @Test("session tracker produces elapsed duration and positive character delta")
    func sessionTrackerProducesReadingSession() throws {
        var tracker = ReadingStatsSessionTracker(
            bookId: "book-1",
            bookTitle: "Test Book",
            startDate: Date(timeIntervalSince1970: 100),
            startCharacterOffset: 20
        )

        tracker.updateVisibleCharacterOffset(95)

        let session = try #require(
            tracker.finish(at: Date(timeIntervalSince1970: 160))
        )
        #expect(session.bookId == "book-1")
        #expect(session.bookTitle == "Test Book")
        #expect(session.startDate == Date(timeIntervalSince1970: 100))
        #expect(session.duration == 60)
        #expect(session.charactersRead == 75)
    }

    @Test("store loads sessions recorded to an injected file URL")
    func storePersistsSessionsToInjectedFileURL() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("reading_stats.json")
        let session = ReadingSession(
            id: UUID(),
            bookId: "book-1",
            bookTitle: "Test Book",
            startDate: Date(timeIntervalSince1970: 100),
            duration: 60,
            charactersRead: 75
        )

        let writer = ReadingStatsStore(fileURL: fileURL)
        writer.recordSession(session)

        let reader = ReadingStatsStore(fileURL: fileURL)
        #expect(reader.sessions.map(\.id) == [session.id])
        #expect(reader.totalDuration(in: reader.sessions) == 60)
        #expect(reader.totalCharacters(in: reader.sessions) == 75)
    }
}
