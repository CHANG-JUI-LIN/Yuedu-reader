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
                format: format
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
        format: ReaderOverlayDisplayFormat
    ) -> String {
        guard current > 0, total > 0, current <= total else { return unavailable }
        if format == .compact {
            return String(current)
        }
        return "\(current)/\(total)"
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
