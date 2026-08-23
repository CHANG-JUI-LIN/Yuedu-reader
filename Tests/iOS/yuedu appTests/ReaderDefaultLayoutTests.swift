import Foundation
import Testing
@testable import yuedu_app

@Suite("Reader default layout")
struct ReaderDefaultLayoutTests {
    @Test("body typography and page turning keep the app defaults")
    func bodyTypographyAndPageTurningKeepAppDefaults() {
        #expect(GlobalSettings.defaultReaderFontSize == 18)
        #expect(GlobalSettings.defaultReaderLineHeightMultiple == 1.65)
        #expect(GlobalSettings.defaultReaderParagraphSpacingMultiplier == 0.8)
        #expect(GlobalSettings.defaultReaderPageMarginH == 24)
        #expect(GlobalSettings.defaultReaderPageMarginV == 16)
        #expect(GlobalSettings.defaultReaderPageTurnStyle == .slide)
    }

    @Test("chapter title matches the bundled reading style")
    func chapterTitleMatchesBundledStyle() {
        let title = ChapterTitleStyle.default
        #expect(title.visible)
        #expect(title.size == 28)
        #expect(title.topSpacing == 16)
        #expect(title.bottomSpacing == 24)
        #expect(title.weight == .bold)
        #expect(title.alignment == .left)
        #expect(title.followsBodyFont)
        #expect(!title.splitEnabled)
    }

    @Test("header and footer match the bundled reading style")
    func headerAndFooterMatchBundledStyle() {
        let layout = ReaderOverlayLayout.default
        let body = layout.components(for: .chapterBody)
        let opening = layout.components(for: .chapterOpening)

        #expect(layout.contentReservations == ReaderOverlayContentReservations(top: 90, bottom: 32))
        #expect(body.map(\.kind) == [
            .chapterTitle,
            .chapterPage,
            .totalProgressText,
            .battery,
            .currentTime
        ])
        #expect(opening.map(\.kind) == [
            .bookTitle,
            .chapterPage,
            .totalProgressText,
            .battery,
            .currentTime
        ])

        #expect(body.map(\.position) == [
            ReaderOverlayNormalizedPoint(x: 0.05454545454545454, y: 0.07566248256624825),
            ReaderOverlayNormalizedPoint(x: 0.05454545454545454, y: 0.9644351464435146),
            ReaderOverlayNormalizedPoint(x: 0.15454545454545454, y: 0.9644351464435147),
            ReaderOverlayNormalizedPoint(x: 0.9454545454545454, y: 0.9644351464435147),
            ReaderOverlayNormalizedPoint(x: 0.8143939393939393, y: 0.9644351464435147)
        ])
        #expect(opening.map(\.position) == [
            ReaderOverlayNormalizedPoint(x: 0.05454545454545454, y: 0.07322175732217573),
            ReaderOverlayNormalizedPoint(x: 0.05454545454545454, y: 0.964783821478382),
            ReaderOverlayNormalizedPoint(x: 0.1553030303030303, y: 0.964783821478382),
            ReaderOverlayNormalizedPoint(x: 0.9454545454545454, y: 0.964783821478382),
            ReaderOverlayNormalizedPoint(x: 0.8151515151515152, y: 0.964783821478382)
        ])

        assertComponentAppearance(body)
        assertComponentAppearance(opening)
    }

    private func assertComponentAppearance(_ components: [ReaderOverlayComponent]) {
        #expect(components.map(\.style.font.kind) == Array(repeating: .system, count: 5))
        #expect(components.map(\.style.fontSize) == [12, 10, 10, 9, 10])
        #expect(components.map(\.style.fontWeight) == [
            .regular,
            .light,
            .light,
            .light,
            .light
        ])
        #expect(components.allSatisfy { $0.style.color.source == .readerText })
        #expect(components.allSatisfy { $0.style.color.hexRGBA == nil })
        #expect(components.allSatisfy { $0.style.opacity == 0.72 })
        #expect(components.allSatisfy { $0.configuration.displayFormat == .automatic })
        #expect(components.allSatisfy { $0.configuration.customText.isEmpty })
        #expect(components.allSatisfy { $0.configuration.svgAssetID == nil })
        #expect(components[3].configuration.batteryVisual == .system)
        #expect(components[3].configuration.showsBatteryPercentage)
        #expect(components.enumerated().allSatisfy { index, component in
            index == 3 || !component.configuration.showsBatteryPercentage
        })
    }
}
