import Foundation

struct ReaderOverlayContentSnapshot: Equatable, Sendable {
    let bookTitle: String
    let chapterTitle: String
    let chapterPage: Int
    let chapterPageCount: Int
    let totalProgress: Double
    let now: Date
    let batteryLevel: Double?
    let isCharging: Bool
    let readingDuration: TimeInterval
    let estimatedRemainingTime: TimeInterval?

    func text(
        for kind: ReaderOverlayComponentKind,
        format: ReaderOverlayDisplayFormat,
        locale: Locale = .autoupdatingCurrent,
        calendar: Calendar = .autoupdatingCurrent
    ) -> String {
        ReaderOverlayValueFormatter.text(
            for: kind,
            format: format,
            snapshot: self,
            locale: locale,
            calendar: calendar
        )
    }
}

enum ReaderRemainingTimeEstimator {
    static func estimate(
        elapsed: TimeInterval,
        charactersRead: Int,
        remainingCharacters: Int?
    ) -> TimeInterval? {
        guard elapsed.isFinite,
              elapsed >= 120,
              charactersRead >= 200,
              let remainingCharacters,
              remainingCharacters >= 0
        else {
            return nil
        }

        let speed = Double(charactersRead) / elapsed
        guard speed.isFinite, speed > 0 else { return nil }

        let estimate = Double(remainingCharacters) / speed
        guard estimate.isFinite, estimate >= 0 else { return nil }
        return estimate
    }
}

struct ReaderLegacyContentIndex: Equatable, Sendable {
    struct Page: Equatable, Sendable {
        let chapterIndex: Int
        let contentLength: Int
    }

    static let empty = ReaderLegacyContentIndex(pages: [])

    private let pageOffsets: [Int]
    private let chapterPageCounts: [Int: Int]

    init(pages: [Page]) {
        var offsets = [0]
        offsets.reserveCapacity(pages.count + 1)
        var counts: [Int: Int] = [:]

        for page in pages {
            guard page.contentLength >= 0 else {
                pageOffsets = []
                chapterPageCounts = [:]
                return
            }
            let (next, overflow) = offsets[offsets.count - 1]
                .addingReportingOverflow(page.contentLength)
            guard !overflow else {
                pageOffsets = []
                chapterPageCounts = [:]
                return
            }
            offsets.append(next)
            counts[page.chapterIndex, default: 0] += 1
        }

        pageOffsets = offsets
        chapterPageCounts = counts
    }

    func chapterPageCount(for chapterIndex: Int) -> Int {
        chapterPageCounts[chapterIndex] ?? 0
    }

    func currentUnitOffset(forPageAt pageIndex: Int) -> Int? {
        guard pageIndex >= 0, pageIndex + 1 < pageOffsets.count else { return nil }
        return pageOffsets[pageIndex]
    }

    func remainingUnitCount(forPageAt pageIndex: Int) -> Int? {
        guard let currentUnitOffset = currentUnitOffset(forPageAt: pageIndex),
              let totalUnitCount = pageOffsets.last
        else {
            return nil
        }
        return max(0, totalUnitCount - currentUnitOffset)
    }
}

enum ReaderClockSchedule {
    static func delayUntilNextMinute(
        from date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> TimeInterval {
        guard let nextMinute = calendar.dateInterval(of: .minute, for: date)?.end else {
            return 60
        }
        let delay = nextMinute.timeIntervalSince(date)
        guard delay.isFinite, delay > 0 else { return 60 }
        return delay
    }
}

struct ReaderResolvedBatteryValue: Equatable, Sendable {
    let level: Double?
    let isCharging: Bool
    let iconName: String
}

enum ReaderBatteryValueResolver {
    static func resolve(
        rawLevel: Double,
        isCharging: Bool
    ) -> ReaderResolvedBatteryValue {
        let level = rawLevel.isFinite && rawLevel >= 0
            ? min(max(rawLevel, 0), 1)
            : nil

        let iconName: String
        if isCharging {
            iconName = "battery.100.bolt"
        } else if let level {
            if level > 0.75 { iconName = "battery.100" }
            else if level > 0.5 { iconName = "battery.75" }
            else if level > 0.25 { iconName = "battery.50" }
            else { iconName = "battery.25" }
        } else {
            iconName = "battery.0"
        }

        return ReaderResolvedBatteryValue(
            level: level,
            isCharging: isCharging,
            iconName: iconName
        )
    }
}

enum ReaderOverlayValueFormatter {
    private static let unavailable = "--"

    static func text(
        for kind: ReaderOverlayComponentKind,
        format: ReaderOverlayDisplayFormat,
        snapshot: ReaderOverlayContentSnapshot,
        locale: Locale,
        calendar: Calendar
    ) -> String {
        switch kind {
        case .bookTitle:
            return snapshot.bookTitle
        case .chapterTitle:
            return snapshot.chapterTitle
        case .chapterPage:
            return chapterPage(
                current: snapshot.chapterPage,
                total: snapshot.chapterPageCount,
                format: format,
                locale: locale
            )
        case .totalProgressText, .progressBar:
            return percentage(snapshot.totalProgress, locale: locale)
        case .currentTime:
            return time(snapshot.now, format: format, locale: locale, calendar: calendar)
        case .currentDate:
            return date(snapshot.now, format: format, locale: locale, calendar: calendar)
        case .weekday:
            return weekday(snapshot.now, format: format, locale: locale, calendar: calendar)
        case .battery:
            guard let batteryLevel = snapshot.batteryLevel,
                  batteryLevel.isFinite,
                  batteryLevel >= 0
            else {
                return unavailable
            }
            return percentage(min(batteryLevel, 1), locale: locale)
        case .readingDuration:
            return duration(
                snapshot.readingDuration,
                format: format,
                locale: locale,
                calendar: calendar
            )
        case .remainingTime:
            guard let remainingTime = snapshot.estimatedRemainingTime else {
                return unavailable
            }
            return duration(
                remainingTime,
                format: format,
                locale: locale,
                calendar: calendar
            )
        case .customText:
            return ""
        }
    }

    private static func chapterPage(
        current: Int,
        total: Int,
        format: ReaderOverlayDisplayFormat,
        locale: Locale
    ) -> String {
        guard current > 0, total > 0, current <= total else { return unavailable }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 0
        guard let currentText = formatter.string(from: NSNumber(value: current)),
              let totalText = formatter.string(from: NSNumber(value: total))
        else {
            return unavailable
        }
        if format == .compact {
            return currentText
        }
        return "\(currentText)/\(totalText)"
    }

    private static func percentage(_ value: Double, locale: Locale) -> String {
        let normalized: Double
        if value.isFinite {
            normalized = min(max(value, 0), 1)
        } else {
            normalized = 0
        }

        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .percent
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        return formatter.string(from: NSNumber(value: normalized)) ?? unavailable
    }

    private static func time(
        _ value: Date,
        format: ReaderOverlayDisplayFormat,
        locale: Locale,
        calendar: Calendar
    ) -> String {
        let formatter = dateFormatter(locale: locale, calendar: calendar)
        switch format {
        case .hourMinute24:
            formatter.dateFormat = "HH:mm"
        case .hourMinute12:
            formatter.dateFormat = "h:mm a"
        case .automatic, .compact, .detailed, .fraction, .percentage:
            formatter.timeStyle = .short
            formatter.dateStyle = .none
        }
        return formatter.string(from: value)
    }

    private static func date(
        _ value: Date,
        format: ReaderOverlayDisplayFormat,
        locale: Locale,
        calendar: Calendar
    ) -> String {
        let formatter = dateFormatter(locale: locale, calendar: calendar)
        formatter.timeStyle = .none
        formatter.dateStyle = format == .detailed ? .long : .short
        return formatter.string(from: value)
    }

    private static func weekday(
        _ value: Date,
        format: ReaderOverlayDisplayFormat,
        locale: Locale,
        calendar: Calendar
    ) -> String {
        let formatter = dateFormatter(locale: locale, calendar: calendar)
        formatter.setLocalizedDateFormatFromTemplate(format == .detailed ? "EEEE" : "EEE")
        return formatter.string(from: value)
    }

    private static func duration(
        _ value: TimeInterval,
        format: ReaderOverlayDisplayFormat,
        locale: Locale,
        calendar: Calendar
    ) -> String {
        guard value.isFinite, value >= 0 else { return unavailable }

        var localizedCalendar = calendar
        localizedCalendar.locale = locale

        let formatter = DateComponentsFormatter()
        formatter.calendar = localizedCalendar
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.unitsStyle = format == .detailed ? .full : .abbreviated
        formatter.maximumUnitCount = format == .detailed ? 0 : 2
        formatter.zeroFormattingBehavior = .dropLeading
        return formatter.string(from: value) ?? unavailable
    }

    private static func dateFormatter(
        locale: Locale,
        calendar: Calendar
    ) -> DateFormatter {
        var localizedCalendar = calendar
        localizedCalendar.locale = locale

        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = localizedCalendar
        formatter.timeZone = calendar.timeZone
        return formatter
    }
}
