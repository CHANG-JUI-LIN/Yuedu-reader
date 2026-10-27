import Foundation
import Testing
import UIKit
@testable import yuedu_app

struct ReaderBarCustomizationTests {
    @Test func multipleSelectionsAndRepeatedKindsSurvivePersistence() throws {
        var layout = ReaderBarLayout(fields: [])
        layout.setSelected(true, kind: .chapterPage, in: .footerCenter)
        layout.setSelected(true, kind: .currentTime, in: .footerCenter)
        layout.setSelected(true, kind: .chapterPage, in: .footerRight)
        let restored = try JSONDecoder().decode(ReaderBarLayout.self, from: JSONEncoder().encode(layout.normalized()))
        #expect(restored.fields(in: .footerCenter).map(\.kind) == [.chapterPage, .currentTime])
        #expect(restored.fields(in: .footerRight).map(\.kind) == [.chapterPage])
        layout.setSelected(false, kind: .chapterPage, in: .footerCenter)
        #expect(layout.fields(in: .footerRight).map(\.kind) == [.chapterPage])
    }

    @Test @MainActor func openingAndBodyRenderDifferentHeaderAndFooter() {
        var layout = ReaderBarLayout(fields: [
            .init(kind: .chapterTitle, slot: .headerLeft),
            .init(kind: .chapterPage, slot: .footerRight)
        ])
        layout.chapterOpeningFields = [
            .init(kind: .bookTitle, slot: .headerRight),
            .init(kind: .currentTime, slot: .footerLeft)
        ]
        let openingHeader = model(layout, bar: .header, page: 1)
        let bodyHeader = model(layout, bar: .header, page: 2)
        #expect(openingHeader.slots[0].isEmpty)
        #expect(!openingHeader.slots[2].isEmpty)
        #expect(!bodyHeader.slots[0].isEmpty)
        #expect(bodyHeader.slots[2].isEmpty)
        #expect(!model(layout, bar: .footer, page: 1).slots[0].isEmpty)
        #expect(!model(layout, bar: .footer, page: 2).slots[2].isEmpty)
        #expect(ReaderOverlayPresentationPolicy.visibility(layout: layout, headerEnabled: true,
            footerEnabled: true, isChapterOpeningPage: true).showsHeader)
        layout.fields = []
        #expect(layout.reservesSpace(in: .header))
        #expect(layout.reservesSpace(in: .footer))
    }

    @Test func oldLayoutRetainsOpeningVisibilityAndCustomization() throws {
        let data = Data(#"{"version":1,"fields":[{"kind":"currentTime","slot":"headerLeft"}],"hidesHeaderOnChapterOpening":true}"#.utf8)
        let layout = try JSONDecoder().decode(ReaderBarLayout.self, from: data)
        #expect(layout.resolved(isChapterOpening: true).fields(in: .headerLeft).isEmpty)
        #expect(layout.fields(in: .headerLeft).count == 1)
        #expect(layout.headerMargins.left == nil)
        #expect(layout.showsComponentSeparators)
    }

    @Test func customizationSwitchPreservesOptionsWhenDisabled() {
        var field = ReaderBarField(kind: .customText, slot: .footerLeft,
            configuration: .init(customText: "Saved text"), color: .init(source: .custom, hexRGBA: 0xFF0000FF),
            usesCustomOptions: true)
        #expect(field.effectiveConfiguration.customText == "Saved text")
        field.usesCustomOptions = false
        #expect(field.effectiveConfiguration == ReaderOverlayComponentConfiguration())
        #expect(field.effectiveColor == nil)
        field.usesCustomOptions = true
        #expect(field.effectiveConfiguration.customText == "Saved text")
        #expect(field.effectiveColor?.hexRGBA == 0xFF0000FF)
    }

    @Test func bodyAndBarMarginsAreIndependent() {
        func insets(top: CGFloat = 7, bottom: CGFloat = 23, headerGap: CGFloat = 3, footerGap: CGFloat = 5) -> (top: CGFloat, bottom: CGFloat) {
            ReaderLayoutMetrics.barContentInsets(safeTop: 59, safeBottom: 34,
                showsHeader: true, showsFooter: true, verticalMargin: 12,
                headerExtent: 18, footerExtent: 18, edgeDistances: .init(header: 11, footer: 13),
                topMargin: top, bottomMargin: bottom, headerInnerMargin: headerGap, footerInnerMargin: footerGap)
        }
        #expect(insets().top == 39)
        #expect(insets().bottom == 59)
        #expect(insets(top: 31).bottom == insets().bottom)
        #expect(insets(bottom: 42).top == insets().top)
        #expect(insets(headerGap: 20).bottom == insets().bottom)
        #expect(insets(footerGap: 20).top == insets().top)
    }

    @Test @MainActor func rendererHonorsAsymmetricMarginsAndHiddenDots() throws {
        var layout = ReaderBarLayout(fields: [
            .init(kind: .currentTime, slot: .footerLeft),
            .init(kind: .chapterPage, slot: .footerLeft)
        ])
        layout.footerMargins = .init(left: 31, right: 9, inner: 17)
        let withDot = model(layout, bar: .footer, page: 2)
        #expect(withDot.leftPadding == 31)
        #expect(withDot.rightPadding == 9)
        layout.showsComponentSeparators = false
        let noDot = model(layout, bar: .footer, page: 2)
        func rendered(_ model: ReaderBarRenderModel) throws -> Data {
            let bounds = CGRect(x: 0, y: 0, width: 320, height: 30)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return try #require(UIGraphicsImageRenderer(bounds: bounds, format: format).image { context in
                ReaderBarRenderer.draw(model, in: bounds, canvasHeight: bounds.height, context: context.cgContext)
            }.pngData())
        }
        #expect(try rendered(withDot) != rendered(noDot))
        #expect(withDot.accessibilityValue == noDot.accessibilityValue)
    }

    @Test func presetRoundTripRetainsBothScopesAndIndependentMargins() throws {
        var layout = ReaderBarLayout.default
        layout.chapterOpeningFields = [.init(kind: .bookTitle, slot: .footerCenter)]
        layout.headerMargins = .init(left: 9, right: 31, inner: 15)
        layout.footerMargins = .init(left: 21, right: 3, inner: 7)
        layout.showsComponentSeparators = false
        let snapshot = ReaderLayoutSnapshot(name: nil, fontSize: 18, isBold: false, lineHeightMultiple: 1.4,
            letterSpacing: 0, paragraphSpacingMultiplier: 0.5, pageMarginH: 16, pageMarginV: 12,
            footerBottomPadding: 4, footerTextGap: 12, titleVisible: true, titleSize: 20,
            titleTopSpacing: 0, titleBottomSpacing: 12, pageTurnStyle: .slide, scrollMode: false,
            readerOverlayLayout: ReaderBarLayoutMigration.freePositionLayout(from: layout),
            pageMarginTop: 9, pageMarginBottom: 37, readerBarLayout: layout)
        let restored = try ReaderLayoutPresetImporter.decode(data: ReaderLayoutPresetExporter.encode(snapshot))
        #expect(restored.pageMarginTop == 9)
        #expect(restored.pageMarginBottom == 37)
        #expect(restored.readerBarLayout == layout)
    }

    @Test @MainActor func independentBodyMarginsSyncAndOldPreferencesStillDecode() throws {
        let original = ReaderPreferences.current()
        defer { original.apply() }
        var preferences = original
        preferences.pageMarginTop = 8
        preferences.pageMarginBottom = 39
        let restored = try JSONDecoder().decode(ReaderPreferences.self, from: JSONEncoder().encode(preferences))
        restored.apply()
        #expect(ReaderConfig.shared.pageMarginTop == 8)
        #expect(ReaderConfig.shared.pageMarginBottom == 39)
        ReaderConfig.shared.pageMarginTop = 17
        #expect(GlobalSettings.shared.pageMarginTop == 17)
        #expect(GlobalSettings.shared.pageMarginBottom == 39)
        #expect(UserDefaults.standard.double(forKey: "yd_page_margin_top") == 17)
        #expect(UserDefaults.standard.double(forKey: "yd_page_margin_bottom") == 39)

        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as? [String: Any])
        object.removeValue(forKey: "pageMarginTop")
        object.removeValue(forKey: "pageMarginBottom")
        let legacy = try JSONDecoder().decode(ReaderPreferences.self, from: JSONSerialization.data(withJSONObject: object))
        legacy.apply()
        // Preferences from before the two margins keep this device's (feedback #25): filling
        // them from `pageMarginV` turned a reader's 下邊距 back into 上下邊距 on every sign-in.
        #expect(ReaderConfig.shared.pageMarginTop == 17)
        #expect(ReaderConfig.shared.pageMarginBottom == 39)
    }

    @MainActor private func model(_ layout: ReaderBarLayout, bar: ReaderBar, page: Int) -> ReaderBarRenderModel {
        ReaderBarRenderModelBuilder().model(for: bar, layout: layout,
            content: .init(bookTitle: "Book", chapterTitle: "Chapter", chapterPage: page, chapterPageCount: 12,
                totalProgress: 0.4, now: Date(timeIntervalSince1970: 0), batteryLevel: 0.7, isCharging: false,
                readingDuration: 1500, estimatedRemainingTime: 4200),
            readerTextColor: .black, horizontalPadding: 16, svgAssetStore: nil, userInterfaceStyle: .light, displayScale: 1)
    }
}
