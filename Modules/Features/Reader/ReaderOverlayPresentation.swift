import SwiftUI
import UIKit

/// What a header/footer field *says* — its value, its formatting, and how
/// VoiceOver phrases it — with nothing about where it sits.
///
/// All that remains of the free-position component renderer. Placement now comes
/// from `ReaderBarLayout`; this layer was always independent of it, which is why
/// the bars could adopt it unchanged.
struct ReaderOverlayResolvedStyle: Equatable {
    var font: UIFont
    var color: UIColor
    var opacity: Double
}


enum ReaderOverlayResolvedContent: Equatable, Sendable {
    case text(String)
    case progress(value: Double)
    case systemBattery(iconName: String, percentage: String?)
    case importedBattery(assetID: UUID, percentage: String?)
}

struct ReaderOverlayResolvedPresentation: Equatable, Sendable {
    var content: ReaderOverlayResolvedContent
    var accessibilityLabel: String
    var accessibilityValue: String
}

enum ReaderOverlayPresentationResolver {
    static func resolve(
        component: ReaderOverlayComponent,
        snapshot: ReaderOverlayContentSnapshot,
        availableSVGAssetIDs: Set<UUID> = [],
        locale: Locale = .autoupdatingCurrent,
        calendar: Calendar = .autoupdatingCurrent
    ) -> ReaderOverlayResolvedPresentation {
        resolve(
            kind: component.kind,
            configuration: component.configuration,
            snapshot: snapshot,
            availableSVGAssetIDs: availableSVGAssetIDs,
            locale: locale,
            calendar: calendar
        )
    }

    /// Position-free entry point: what a field *says*, independent of where it sits.
    ///
    /// The header/footer bars call this directly. Nothing about the value, its
    /// formatting, or its VoiceOver phrasing depends on placement, so keeping one
    /// implementation is what stops a field from reading differently in a bar than
    /// it did as a free-positioned component.
    static func resolve(
        kind: ReaderOverlayComponentKind,
        configuration rawConfiguration: ReaderOverlayComponentConfiguration,
        snapshot: ReaderOverlayContentSnapshot,
        availableSVGAssetIDs: Set<UUID> = [],
        locale: Locale = .autoupdatingCurrent,
        calendar: Calendar = .autoupdatingCurrent
    ) -> ReaderOverlayResolvedPresentation {
        let configuration = rawConfiguration.normalized
        let label = accessibilityLabel(for: kind)
        let formattedValue = snapshot.text(
            for: kind,
            format: configuration.displayFormat,
            locale: locale,
            calendar: calendar
        )

        let content: ReaderOverlayResolvedContent
        let accessibilityValue: String
        switch kind {
        case .progressBar:
            let progress = normalizedProgress(snapshot.totalProgress)
            content = .progress(value: progress)
            accessibilityValue = formattedValue
        case .battery:
            let battery = ReaderBatteryValueResolver.resolve(
                rawLevel: snapshot.batteryLevel ?? -1,
                isCharging: snapshot.isCharging
            )
            let percentage = configuration.showsBatteryPercentage ? formattedValue : nil
            if configuration.batteryVisual == .importedSVG,
               let assetID = configuration.svgAssetID,
               availableSVGAssetIDs.contains(assetID) {
                content = .importedBattery(assetID: assetID, percentage: percentage)
            } else {
                content = .systemBattery(iconName: battery.iconName, percentage: percentage)
            }
            accessibilityValue = formattedValue
        case .customText:
            content = .text(configuration.customText)
            accessibilityValue = configuration.customText
        case .bookTitle, .chapterTitle, .chapterPage, .totalProgressText,
             .currentTime, .currentDate, .weekday, .readingDuration, .remainingTime:
            content = .text(formattedValue)
            accessibilityValue = formattedValue
        }

        return ReaderOverlayResolvedPresentation(
            content: content,
            accessibilityLabel: label,
            accessibilityValue: accessibilityValue
        )
    }

    static func rgbaHex(
        _ color: UIColor,
        userInterfaceStyle: UIUserInterfaceStyle
    ) -> String? {
        let resolved = color.resolvedColor(
            with: UITraitCollection(userInterfaceStyle: userInterfaceStyle)
        )
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return nil
        }
        return String(
            format: "#%02X%02X%02X%02X",
            byte(red),
            byte(green),
            byte(blue),
            byte(alpha)
        )
    }

    private static func accessibilityLabel(for kind: ReaderOverlayComponentKind) -> String {
        switch kind {
        case .bookTitle: localized("書名")
        case .chapterTitle: localized("章節名")
        case .chapterPage: localized("本章頁碼")
        case .totalProgressText, .progressBar: localized("總進度")
        case .currentTime: localized("目前時間")
        case .currentDate: localized("目前日期")
        case .weekday: localized("星期")
        case .battery: localized("電量")
        case .readingDuration: localized("本次閱讀時長")
        case .remainingTime: localized("預估剩餘時間")
        case .customText: localized("自訂文字")
        }
    }

    private static func normalizedProgress(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    private static func byte(_ value: CGFloat) -> Int {
        Int((min(max(value, 0), 1) * 255).rounded())
    }
}
