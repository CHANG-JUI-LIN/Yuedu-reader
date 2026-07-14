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

    @Test("system font keeps requested size and weight")
    func systemFontStyle() {
        let style = ReaderOverlayComponentStyle(
            font: ReaderOverlayFontReference(kind: .system),
            fontSize: 19,
            fontWeight: .bold
        )

        let resolved = ReaderOverlayPresentationResolver.resolveStyle(
            style,
            readerFont: UIFont.systemFont(ofSize: 17),
            readerTextColor: .label,
            availablePostScriptNames: []
        )

        #expect(resolved.font.pointSize == 19)
        #expect(resolved.font.fontDescriptor.symbolicTraits.contains(.traitBold))
    }

    @Test("missing imported font falls back without mutating the requested style")
    func missingImportedFontFallback() {
        let reference = ReaderOverlayFontReference(
            kind: .imported,
            postScriptName: "Missing-Yuedu-Font"
        )
        let style = ReaderOverlayComponentStyle(
            font: reference,
            fontSize: 15,
            fontWeight: .medium
        )

        let resolved = ReaderOverlayPresentationResolver.resolveStyle(
            style,
            readerFont: UIFont.systemFont(ofSize: 20),
            readerTextColor: .label,
            availablePostScriptNames: ["Missing-Yuedu-Font"]
        )

        #expect(resolved.font.pointSize == 15)
        #expect(resolved.font.familyName == UIFont.systemFont(ofSize: 15).familyName)
        #expect(style.font == reference)
    }

    @Test("custom RGBA color resolves and invalid custom storage falls back to reader text")
    func colorResolutionAndFallback() throws {
        let readerColor = UIColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.9)
        let custom = ReaderOverlayPresentationResolver.resolveStyle(
            ReaderOverlayComponentStyle(
                color: ReaderOverlayColorReference(source: .custom, hexRGBA: 0x3366CC80)
            ),
            readerFont: UIFont.systemFont(ofSize: 17),
            readerTextColor: readerColor,
            availablePostScriptNames: []
        )
        let fallback = ReaderOverlayPresentationResolver.resolveStyle(
            ReaderOverlayComponentStyle(
                color: ReaderOverlayColorReference(source: .custom, hexRGBA: nil)
            ),
            readerFont: UIFont.systemFont(ofSize: 17),
            readerTextColor: readerColor,
            availablePostScriptNames: []
        )

        #expect(try rgba(custom.color) == [0x33, 0x66, 0xCC, 0x80])
        #expect(try rgba(fallback.color) == rgba(readerColor))
    }

    @Test("opacity uses persisted normalization bounds and nonfinite fallback")
    func opacityNormalization() {
        let low = resolvedStyle(opacity: 0)
        let high = resolvedStyle(opacity: 4)
        let nonfinite = resolvedStyle(opacity: .nan)

        #expect(low.opacity == 0.1)
        #expect(high.opacity == 1)
        #expect(nonfinite.opacity == ReaderOverlayComponentStyle.defaultOpacity)
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

    private func resolvedStyle(opacity: Double) -> ReaderOverlayResolvedStyle {
        ReaderOverlayPresentationResolver.resolveStyle(
            ReaderOverlayComponentStyle(opacity: opacity),
            readerFont: UIFont.systemFont(ofSize: 17),
            readerTextColor: .label,
            availablePostScriptNames: []
        )
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
