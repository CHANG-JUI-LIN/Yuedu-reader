import Foundation
import Testing
@testable import yuedu_app

struct ReaderOverlayContentTests {
    private let locale = Locale(identifier: "en_US_POSIX")

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private var fixedDate: Date {
        utcCalendar.date(from: DateComponents(
            year: 2024,
            month: 1,
            day: 2,
            hour: 13,
            minute: 5
        ))!
    }

    private func snapshot(
        chapterPage: Int = 3,
        chapterPageCount: Int = 12,
        totalProgress: Double = 0.257,
        batteryLevel: Double? = 0.42,
        readingDuration: TimeInterval = 3_661,
        estimatedRemainingTime: TimeInterval? = 732
    ) -> ReaderOverlayContentSnapshot {
        ReaderOverlayContentSnapshot(
            bookTitle: "Book",
            chapterTitle: "Chapter",
            chapterPage: chapterPage,
            chapterPageCount: chapterPageCount,
            totalProgress: totalProgress,
            now: fixedDate,
            batteryLevel: batteryLevel,
            isCharging: false,
            readingDuration: readingDuration,
            estimatedRemainingTime: estimatedRemainingTime
        )
    }

    @Test("chapter page supports fraction and compact formats")
    func chapterPageFormats() {
        let value = snapshot()

        #expect(value.text(for: .chapterPage, format: .fraction, locale: locale, calendar: utcCalendar) == "3/12")
        #expect(value.text(for: .chapterPage, format: .compact, locale: locale, calendar: utcCalendar) == "3")
    }

    @Test("progress uses a localized percent and clamps invalid bounds")
    func progressFormatting() {
        #expect(snapshot().text(for: .totalProgressText, format: .percentage, locale: locale, calendar: utcCalendar) == "25.7%")
        #expect(snapshot(totalProgress: -0.5).text(for: .progressBar, format: .automatic, locale: locale, calendar: utcCalendar) == "0%")
        #expect(snapshot(totalProgress: 1.5).text(for: .progressBar, format: .automatic, locale: locale, calendar: utcCalendar) == "100%")
    }

    @Test("remaining time estimator requires a stable reading sample")
    func remainingTimeEstimatorThresholds() {
        #expect(ReaderRemainingTimeEstimator.estimate(elapsed: 30, charactersRead: 80, remainingCharacters: 3_000) == nil)
        #expect(ReaderRemainingTimeEstimator.estimate(elapsed: 600, charactersRead: 6_000, remainingCharacters: 3_000) == 300)
        #expect(ReaderRemainingTimeEstimator.estimate(elapsed: 600, charactersRead: 6_000, remainingCharacters: 0) == 0)
    }

    @Test("remaining time estimator rejects unknown and pathological inputs")
    func remainingTimeEstimatorInvalidInputs() {
        #expect(ReaderRemainingTimeEstimator.estimate(elapsed: 600, charactersRead: 6_000, remainingCharacters: nil) == nil)
        #expect(ReaderRemainingTimeEstimator.estimate(elapsed: -1, charactersRead: 6_000, remainingCharacters: 3_000) == nil)
        #expect(ReaderRemainingTimeEstimator.estimate(elapsed: .nan, charactersRead: 6_000, remainingCharacters: 3_000) == nil)
        #expect(ReaderRemainingTimeEstimator.estimate(elapsed: .infinity, charactersRead: 6_000, remainingCharacters: 3_000) == nil)
        #expect(ReaderRemainingTimeEstimator.estimate(elapsed: 600, charactersRead: -1, remainingCharacters: 3_000) == nil)
        #expect(ReaderRemainingTimeEstimator.estimate(elapsed: 600, charactersRead: 6_000, remainingCharacters: -1) == nil)
        #expect(ReaderRemainingTimeEstimator.estimate(
            elapsed: .greatestFiniteMagnitude,
            charactersRead: 200,
            remainingCharacters: .max
        ) == nil)
    }

    @Test("invalid page battery and duration values use the unavailable marker")
    func invalidValues() {
        #expect(snapshot(chapterPage: 0).text(for: .chapterPage, format: .fraction, locale: locale, calendar: utcCalendar) == "--")
        #expect(snapshot(chapterPage: 13).text(for: .chapterPage, format: .fraction, locale: locale, calendar: utcCalendar) == "--")
        #expect(snapshot(batteryLevel: nil).text(for: .battery, format: .percentage, locale: locale, calendar: utcCalendar) == "--")
        #expect(snapshot(batteryLevel: -1).text(for: .battery, format: .percentage, locale: locale, calendar: utcCalendar) == "--")
        #expect(snapshot(readingDuration: -.infinity).text(for: .readingDuration, format: .compact, locale: locale, calendar: utcCalendar) == "--")
        #expect(snapshot(estimatedRemainingTime: nil).text(for: .remainingTime, format: .detailed, locale: locale, calendar: utcCalendar) == "--")
    }

    @Test("battery is formatted as a numeric percentage")
    func batteryPercentage() {
        #expect(snapshot(batteryLevel: 0.42).text(for: .battery, format: .percentage, locale: locale, calendar: utcCalendar) == "42%")
    }

    @Test("explicit clock formats honor the supplied calendar time zone")
    func clockFormats() {
        #expect(snapshot().text(for: .currentTime, format: .hourMinute24, locale: locale, calendar: utcCalendar) == "13:05")
        #expect(snapshot().text(for: .currentTime, format: .hourMinute12, locale: locale, calendar: utcCalendar) == "1:05 PM")
    }

    @Test("date and weekday formats are deterministic")
    func dateAndWeekdayFormats() {
        #expect(snapshot().text(for: .currentDate, format: .compact, locale: locale, calendar: utcCalendar) == "1/2/24")
        #expect(snapshot().text(for: .weekday, format: .compact, locale: locale, calendar: utcCalendar) == "Tue")
        #expect(snapshot().text(for: .weekday, format: .detailed, locale: locale, calendar: utcCalendar) == "Tuesday")
    }

    @Test("duration formats are locale aware and nonempty")
    func durationFormats() {
        let compact = snapshot().text(for: .readingDuration, format: .compact, locale: locale, calendar: utcCalendar)
        let detailed = snapshot().text(for: .readingDuration, format: .detailed, locale: locale, calendar: utcCalendar)

        #expect(!compact.isEmpty)
        #expect(compact != "--")
        #expect(!detailed.isEmpty)
        #expect(detailed != "--")
    }

    @Test("every overlay component kind returns deterministic text")
    func everyComponentKindFormats() {
        let value = snapshot()

        for kind in ReaderOverlayComponentKind.allCases {
            let first = value.text(for: kind, format: .automatic, locale: locale, calendar: utcCalendar)
            let second = value.text(for: kind, format: .automatic, locale: locale, calendar: utcCalendar)
            #expect(first == second)
        }

        #expect(value.text(for: .bookTitle, format: .automatic, locale: locale, calendar: utcCalendar) == "Book")
        #expect(value.text(for: .chapterTitle, format: .automatic, locale: locale, calendar: utcCalendar) == "Chapter")
        #expect(value.text(for: .customText, format: .automatic, locale: locale, calendar: utcCalendar) == "")
    }

    @Test("reading statistics expose clamped current metrics without finishing")
    func readingStatsCurrentMetrics() {
        var tracker = ReadingStatsSessionTracker(
            bookId: "book-1",
            bookTitle: "Book",
            startDate: Date(timeIntervalSince1970: 100),
            startCharacterOffset: 500
        )
        tracker.updateVisibleCharacterOffset(450)

        let beforeStart = tracker.currentMetrics(at: Date(timeIntervalSince1970: 90))
        #expect(beforeStart.elapsed == 0)
        #expect(beforeStart.charactersRead == 0)

        tracker.updateVisibleCharacterOffset(725)
        let current = tracker.currentMetrics(at: Date(timeIntervalSince1970: 160))
        #expect(current.elapsed == 60)
        #expect(current.charactersRead == 225)
    }
}
