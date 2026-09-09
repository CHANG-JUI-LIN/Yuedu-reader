import Foundation
import Testing
import UIKit
@testable import yuedu_app

struct ReaderOverlayPresentationTests {
    private let locale = Locale(identifier: "en_US_POSIX")

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private var snapshot: ReaderOverlayContentSnapshot {
        ReaderOverlayContentSnapshot(
            bookTitle: "Book",
            chapterTitle: "Chapter",
            chapterPage: 3,
            chapterPageCount: 12,
            totalProgress: 0.425,
            now: Date(timeIntervalSince1970: 1_700_000_000),
            batteryLevel: 0.64,
            isCharging: false,
            readingDuration: 600,
            estimatedRemainingTime: 1_200
        )
    }


    @Test("missing imported battery SVG resolves to the system battery")
    func missingSVGFallback() {
        let missingID = UUID()
        let component = ReaderOverlayComponent(
            id: UUID(),
            kind: .battery,
            position: ReaderOverlayNormalizedPoint(x: 0.5, y: 0.5),
            configuration: ReaderOverlayComponentConfiguration(
                batteryVisual: .importedSVG,
                svgAssetID: missingID,
                showsBatteryPercentage: true
            )
        )

        let presentation = ReaderOverlayPresentationResolver.resolve(
            component: component,
            snapshot: snapshot,
            availableSVGAssetIDs: [],
            locale: locale,
            calendar: calendar
        )

        #expect(presentation.content == .systemBattery(
            iconName: "battery.75",
            percentage: "64%"
        ))
    }

    @Test("available imported battery SVG resolves to imported content")
    func availableSVGResolution() {
        let assetID = UUID()
        let component = ReaderOverlayComponent(
            id: UUID(),
            kind: .battery,
            position: ReaderOverlayNormalizedPoint(x: 0.5, y: 0.5),
            configuration: ReaderOverlayComponentConfiguration(
                batteryVisual: .importedSVG,
                svgAssetID: assetID,
                showsBatteryPercentage: true
            )
        )

        let presentation = ReaderOverlayPresentationResolver.resolve(
            component: component,
            snapshot: snapshot,
            availableSVGAssetIDs: [assetID],
            locale: locale,
            calendar: calendar
        )

        #expect(presentation.content == .importedBattery(
            assetID: assetID,
            percentage: "64%"
        ))
    }

    @Test("progress bar exposes a localized label and formatted value")
    func progressAccessibility() {
        let component = ReaderOverlayComponent(
            id: UUID(),
            kind: .progressBar,
            position: ReaderOverlayNormalizedPoint(x: 0.5, y: 0.5)
        )

        let presentation = ReaderOverlayPresentationResolver.resolve(
            component: component,
            snapshot: snapshot,
            locale: locale,
            calendar: calendar
        )

        #expect(presentation.content == .progress(value: 0.425))
        #expect(presentation.accessibilityLabel == localized("總進度"))
        #expect(presentation.accessibilityValue == "42.5%")
    }

    @Test("custom text is resolved from component configuration")
    func customTextResolution() {
        let component = ReaderOverlayComponent(
            id: UUID(),
            kind: .customText,
            position: ReaderOverlayNormalizedPoint(x: 0.5, y: 0.5),
            configuration: ReaderOverlayComponentConfiguration(customText: "Read gently")
        )

        let presentation = ReaderOverlayPresentationResolver.resolve(
            component: component,
            snapshot: snapshot,
            locale: locale,
            calendar: calendar
        )

        #expect(presentation.content == .text("Read gently"))
        #expect(presentation.accessibilityLabel == localized("自訂文字"))
        #expect(presentation.accessibilityValue == "Read gently")
    }
    private func rgba(_ color: UIColor) throws -> [Int] {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        try #require(color.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        return [red, green, blue, alpha].map { Int(($0 * 255).rounded()) }
    }
}
