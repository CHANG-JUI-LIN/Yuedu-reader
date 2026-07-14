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

    @Test("chapter page localizes integer digits")
    func chapterPageLocalizesDigits() {
        let arabic = Locale(identifier: "ar_EG")

        #expect(snapshot().text(
            for: .chapterPage,
            format: .fraction,
            locale: arabic,
            calendar: utcCalendar
        ) == "٣/١٢")
    }

    @Test("progress uses a localized percent and clamps invalid bounds")
    func progressFormatting() {
        #expect(snapshot().text(for: .totalProgressText, format: .percentage, locale: locale, calendar: utcCalendar) == "25.7%")
        #expect(snapshot(totalProgress: -0.5).text(for: .progressBar, format: .automatic, locale: locale, calendar: utcCalendar) == "0%")
        #expect(snapshot(totalProgress: 1.5).text(for: .progressBar, format: .automatic, locale: locale, calendar: utcCalendar) == "100%")
    }

    @Test("remaining time estimator requires a stable reading sample")
    func remainingTimeEstimatorThresholds() {
        #expect(ReaderRemainingTimeEstimator.estimate(elapsed: 30, contentUnitsRead: 80, remainingContentUnits: 3_000) == nil)
        #expect(ReaderRemainingTimeEstimator.estimate(elapsed: 600, contentUnitsRead: 6_000, remainingContentUnits: 3_000) == 300)
        #expect(ReaderRemainingTimeEstimator.estimate(elapsed: 600, contentUnitsRead: 6_000, remainingContentUnits: 0) == 0)
    }

    @Test("remaining time estimator rejects unknown and pathological inputs")
    func remainingTimeEstimatorInvalidInputs() {
        #expect(ReaderRemainingTimeEstimator.estimate(elapsed: 600, contentUnitsRead: 6_000, remainingContentUnits: nil) == nil)
        #expect(ReaderRemainingTimeEstimator.estimate(elapsed: -1, contentUnitsRead: 6_000, remainingContentUnits: 3_000) == nil)
        #expect(ReaderRemainingTimeEstimator.estimate(elapsed: .nan, contentUnitsRead: 6_000, remainingContentUnits: 3_000) == nil)
        #expect(ReaderRemainingTimeEstimator.estimate(elapsed: .infinity, contentUnitsRead: 6_000, remainingContentUnits: 3_000) == nil)
        #expect(ReaderRemainingTimeEstimator.estimate(elapsed: 600, contentUnitsRead: -1, remainingContentUnits: 3_000) == nil)
        #expect(ReaderRemainingTimeEstimator.estimate(elapsed: 600, contentUnitsRead: 6_000, remainingContentUnits: -1) == nil)
        #expect(ReaderRemainingTimeEstimator.estimate(
            elapsed: .greatestFiniteMagnitude,
            contentUnitsRead: 200,
            remainingContentUnits: .max
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

    @Test("duration formats apply compact and detailed unit rules")
    func durationFormats() {
        let compact = snapshot().text(for: .readingDuration, format: .compact, locale: locale, calendar: utcCalendar)
        let detailed = snapshot().text(for: .readingDuration, format: .detailed, locale: locale, calendar: utcCalendar)

        #expect(compact == "1h 1m")
        #expect(detailed == "1 hour, 1 minute, 1 second")
    }

    @Test("content metrics stay available for books larger than the layout cache")
    func contentMetricsDoNotDependOnLayouts() throws {
        let map = try #require(ReaderContentUnitMap(
            chapterUnitCounts: Array(repeating: 100, count: 12)
        ))

        let metrics = try #require(map.metrics(
            spineIndex: 10,
            localCharacterOffset: 25,
            currentChapterCharacterCount: 50
        ))

        #expect(metrics.currentUnitOffset == 1_050)
        #expect(metrics.totalUnitCount == 1_200)
        #expect(metrics.remainingUnitCount == 150)
    }

    @Test("content metrics reject unknown conversion and invalid metadata")
    func contentMetricsRejectUnknownValues() throws {
        #expect(ReaderContentUnitMap(chapterUnitCounts: [100, -1]) == nil)

        let map = try #require(ReaderContentUnitMap(chapterUnitCounts: [100, 200]))
        #expect(map.metrics(
            spineIndex: 1,
            localCharacterOffset: 10,
            currentChapterCharacterCount: nil
        ) == nil)
    }

    @Test("legacy page index computes offsets once and reads them in constant time")
    func legacyPageIndex() {
        let index = ReaderLegacyContentIndex(pages: [
            .init(chapterIndex: 0, contentLength: 10),
            .init(chapterIndex: 0, contentLength: 20),
            .init(chapterIndex: 1, contentLength: 30),
        ])

        #expect(index.chapterPageCount(for: 0) == 2)
        #expect(index.currentUnitOffset(forPageAt: 2) == 30)
        #expect(index.remainingUnitCount(forPageAt: 2) == 30)
    }

    @Test("clock schedule aligns first refresh to the next whole minute")
    func clockScheduleAlignment() {
        let halfMinute = fixedDate.addingTimeInterval(30.25)

        #expect(abs(ReaderClockSchedule.delayUntilNextMinute(
            from: halfMinute,
            calendar: utcCalendar
        ) - 29.75) < 0.000_001)
        #expect(ReaderClockSchedule.delayUntilNextMinute(
            from: fixedDate,
            calendar: utcCalendar
        ) == 60)
    }

    @Test("battery resolver handles unavailable and full charging states")
    func batteryResolver() {
        let unavailable = ReaderBatteryValueResolver.resolve(
            rawLevel: -1,
            isCharging: false
        )
        #expect(unavailable.level == nil)
        #expect(unavailable.isCharging == false)
        #expect(unavailable.iconName == "battery.0")

        let full = ReaderBatteryValueResolver.resolve(
            rawLevel: 1,
            isCharging: true
        )
        #expect(full.level == 1)
        #expect(full.isCharging)
        #expect(full.iconName == "battery.100.bolt")
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

    @Test("reading statistics accumulate adjacent forward movement")
    func readingStatsAccumulateAdjacentMovement() {
        var tracker = ReadingStatsSessionTracker(
            bookId: "book-1",
            bookTitle: "Book",
            startDate: Date(timeIntervalSince1970: 100),
            startPosition: .global(characterOffset: 500)
        )
        tracker.updateVisiblePosition(.global(characterOffset: 450))

        let beforeStart = tracker.currentMetrics(at: Date(timeIntervalSince1970: 90))
        #expect(beforeStart.elapsed == 0)
        #expect(beforeStart.charactersRead == 0)

        tracker.updateVisiblePosition(.global(characterOffset: 475))
        let current = tracker.currentMetrics(at: Date(timeIntervalSince1970: 160))
        #expect(current.elapsed == 60)
        #expect(current.charactersRead == 25)
    }

    @Test("relocation backward movement and abnormal jumps reset the baseline")
    func readingStatsRelocationAndInvalidDeltas() {
        var tracker = ReadingStatsSessionTracker(
            bookId: "book-1",
            bookTitle: "Book",
            startPosition: .global(characterOffset: 100)
        )

        tracker.updateVisiblePosition(.global(characterOffset: 150))
        tracker.relocate(to: .global(characterOffset: 10_000))
        tracker.updateVisiblePosition(.global(characterOffset: 10_020))
        tracker.updateVisiblePosition(.global(characterOffset: 9_000))
        tracker.updateVisiblePosition(.global(characterOffset: 9_030))
        tracker.updateVisiblePosition(.global(
            characterOffset: 9_030 + ReadingStatsSessionTracker.maximumContinuousAdvance + 1
        ))
        tracker.updateVisiblePosition(.global(
            characterOffset: 9_030 + ReadingStatsSessionTracker.maximumContinuousAdvance + 11
        ))

        #expect(tracker.currentMetrics().charactersRead == 110)
    }

    @Test("scroll style repeated commits count each positive interval once")
    func readingStatsRepeatedScrollUpdates() {
        var tracker = ReadingStatsSessionTracker(
            bookId: "book-1",
            bookTitle: "Book",
            startPosition: .global(characterOffset: 1_000)
        )

        for offset in [1_010, 1_010, 1_025, 1_040] {
            tracker.updateVisiblePosition(.global(characterOffset: offset))
        }

        #expect(tracker.currentMetrics().charactersRead == 40)
    }

    @Test("persisted characters stay separate from global content-unit pace")
    func readingStatsSeparateCharactersFromContentUnits() throws {
        var tracker = ReadingStatsSessionTracker(
            bookId: "book-1",
            bookTitle: "Book",
            startPosition: .spine(
                2,
                characterOffset: 100,
                globalContentUnitOffset: 1_000
            )
        )

        tracker.updateVisiblePosition(.spine(
            2,
            characterOffset: 150,
            globalContentUnitOffset: 1_400
        ))

        #expect(tracker.currentMetrics().charactersRead == 50)
        #expect(tracker.currentPaceMetrics().contentUnitsRead == 400)
        let session = try #require(
            tracker.finish(at: Date().addingTimeInterval(1))
        )
        #expect(session.charactersRead == 50)
    }

    @Test("online positions accumulate rendered characters within one spine")
    func onlineReadingStatsAccumulateWithinSpine() {
        var tracker = ReadingStatsSessionTracker(
            bookId: "book-1",
            bookTitle: "Book",
            startPosition: .spine(4, characterOffset: 200)
        )

        tracker.updateVisiblePosition(.spine(4, characterOffset: 275))

        #expect(tracker.currentMetrics().charactersRead == 75)
        #expect(tracker.currentPaceMetrics().contentUnitsRead == 0)
    }

    @Test("online positions reset rendered-character baseline across spines")
    func onlineReadingStatsResetAcrossSpines() {
        var tracker = ReadingStatsSessionTracker(
            bookId: "book-1",
            bookTitle: "Book",
            startPosition: .spine(1, characterOffset: 100)
        )

        tracker.updateVisiblePosition(.spine(1, characterOffset: 150))
        tracker.updateVisiblePosition(.spine(2, characterOffset: 1_000))
        tracker.updateVisiblePosition(.spine(2, characterOffset: 1_030))

        #expect(tracker.currentMetrics().charactersRead == 80)
    }

    @Test("unresolved jump and generic relocation do not accumulate bookmark distance")
    func unresolvedJumpRelocationDoesNotAccumulate() {
        let bookmark = ReadingStatsTrackingPosition.spine(
            3,
            characterOffset: 1_200
        )
        var tracker = ReadingStatsSessionTracker(
            bookId: "book-1",
            bookTitle: "Book",
            startPosition: .spine(3, characterOffset: 0)
        )

        tracker.relocate(to: bookmark)
        tracker.relocate(to: bookmark)
        tracker.updateVisiblePosition(bookmark)

        #expect(tracker.currentMetrics().charactersRead == 0)
        #expect(tracker.currentPaceMetrics().contentUnitsRead == 0)
    }
}
