import Foundation
import Testing
@testable import yuedu_app

@Suite("Reader layout preset importer")
struct ReaderLayoutPresetImporterTests {
    @Test("maps Legado readConfig layout fields")
    func mapsReadConfigLayoutFields() throws {
        let data = Data(
            """
            {
              "footerPaddingBottom": 0,
              "footerPaddingTop": 0,
              "headerMode": 1,
              "letterSpacing": 0.0,
              "lineSpacingExtra": 14,
              "name": "番茄小说",
              "paddingBottom": 11,
              "paddingLeft": 21,
              "paddingRight": 20,
              "paddingTop": 12,
              "pageAnim": 0,
              "paragraphSpacing": 8,
              "textBold": 0,
              "textSize": 17,
              "titleBottomSpacing": 0,
              "titleMode": 0,
              "titleSize": 0,
              "titleTopSpacing": 0
            }
            """.utf8
        )

        let preset = try ReaderLayoutPresetImporter.decode(data: data)

        #expect(preset.name == "番茄小说")
        #expect(preset.fontSize == 17)
        #expect(preset.isBold == false)
        #expect(abs((preset.lineHeightMultiple ?? 0) - 1.8235) < 0.0001)
        #expect(preset.letterSpacing == 0)
        #expect(abs((preset.paragraphSpacingMultiplier ?? 0) - 0.4706) < 0.0001)
        #expect(preset.pageMarginH == 20.5)
        #expect(preset.pageMarginV == 11.5)
        #expect(preset.footerBottomPadding == 0)
        #expect(preset.footerTextGap == 0)
        #expect(preset.titleVisible == true)
        #expect(preset.titleSize == nil)
        #expect(preset.titleTopSpacing == 0)
        #expect(preset.titleBottomSpacing == 0)
        #expect(preset.pageTurnStyle == .slide)
        #expect(preset.scrollMode == false)
        #expect(preset.readerOverlayLayout?.contentReservations.bottom == 16)
    }

    @Test("maps title controls and scroll mode with bounds")
    func mapsTitleControlsAndScrollMode() throws {
        let data = Data(
            """
            {
              "headerMode": 0,
              "pageAnim": 3,
              "textSize": 18,
              "titleSize": 30,
              "titleTopSpacing": 99,
              "titleBottomSpacing": -4
            }
            """.utf8
        )

        let preset = try ReaderLayoutPresetImporter.decode(data: data)

        #expect(preset.titleVisible == false)
        #expect(preset.titleSize == 24)
        #expect(preset.titleTopSpacing == 28)
        #expect(preset.titleBottomSpacing == 0)
        #expect(preset.scrollMode == true)
        #expect(preset.pageTurnStyle == nil)
        #expect(preset.readerOverlayLayout == nil)
    }

    @Test("migrates legacy fixed header and footer fields")
    func migratesLegacyHeaderAndFooter() throws {
        let data = Data(
            """
            {
              "readerHeaderVisible": true,
              "readerFooterVisible": true,
              "readerHeaderFieldPositions": {
                "chapterTitle": "left",
                "time": "right"
              },
              "readerHeaderTopPadding": 10,
              "readerHeaderHorizontalPadding": 20,
              "footerBottomPadding": 8,
              "readerFooterHorizontalPadding": 18,
              "topContentReservation": 42,
              "bottomContentReservation": 36
            }
            """.utf8
        )

        let preset = try ReaderLayoutPresetImporter.decode(data: data)
        let layout = try #require(preset.readerOverlayLayout)

        #expect(layout.components.map(\.kind) == [
            .chapterTitle,
            .currentTime,
            .chapterPage,
            .totalProgressText,
            .currentTime,
            .battery
        ])
        #expect(layout.contentReservations == ReaderOverlayContentReservations(top: 42, bottom: 36))
        #expect(layout.components[0].position.x == 20.0 / 390.0)
        #expect(layout.components[1].position.x == 370.0 / 390.0)
    }

    @Test("prefers and normalizes the new overlay payload")
    func importsNewOverlayPayload() throws {
        let assetID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let componentID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let data = Data(
            """
            {
              "readerHeaderVisible": true,
              "readerHeaderFieldPositions": { "chapterTitle": "left" },
              "readerOverlayLayout": {
                "version": 1,
                "components": [{
                  "id": "\(componentID.uuidString)",
                  "kind": "battery",
                  "position": { "x": 2.0, "y": -1.0 },
                  "style": { "fontSize": 100, "opacity": 0.01 },
                  "configuration": {
                    "batteryVisual": "importedSVG",
                    "svgAssetID": "\(assetID.uuidString)"
                  }
                }],
                "contentReservations": { "top": 500, "bottom": -20 }
              }
            }
            """.utf8
        )

        let preset = try ReaderLayoutPresetImporter.decode(data: data)
        let layout = try #require(preset.readerOverlayLayout)
        let component = try #require(layout.components.first)

        #expect(layout.components.count == 1)
        #expect(component.id == componentID)
        #expect(component.position == ReaderOverlayNormalizedPoint(x: 1, y: 0))
        #expect(component.style.fontSize == 72)
        #expect(component.style.opacity == 0.1)
        #expect(component.configuration.svgAssetID == assetID)
        #expect(layout.contentReservations == ReaderOverlayContentReservations(top: 120, bottom: 0))
    }

    @Test("falls back to legacy fields when the new overlay payload is malformed")
    func malformedOverlayFallsBackToLegacy() throws {
        let data = Data(
            """
            {
              "readerFooterVisible": true,
              "footerBottomPadding": 6,
              "readerOverlayLayout": {
                "version": 1,
                "components": "not-an-array"
              }
            }
            """.utf8
        )

        let preset = try ReaderLayoutPresetImporter.decode(data: data)
        let layout = try #require(preset.readerOverlayLayout)

        #expect(layout.components.map(\.kind) == [
            .chapterPage,
            .totalProgressText,
            .currentTime,
            .battery
        ])
    }

    @Test("treats an empty overlay object as malformed")
    func emptyOverlayFallsBackToLegacy() throws {
        let data = Data(
            """
            {
              "readerHeaderVisible": true,
              "readerHeaderFieldPositions": { "chapterTitle": "center" },
              "readerOverlayLayout": {}
            }
            """.utf8
        )

        let preset = try ReaderLayoutPresetImporter.decode(data: data)
        let layout = try #require(preset.readerOverlayLayout)

        #expect(layout.components.map(\.kind) == [.chapterTitle])
        #expect(layout.components[0].position.x == 0.5)
    }

    @Test("treats null overlay fields as malformed")
    func nullOverlayFieldsFallBackToLegacy() throws {
        let data = Data(
            """
            {
              "readerFooterVisible": true,
              "readerOverlayLayout": {
                "version": null,
                "components": null,
                "contentReservations": null
              }
            }
            """.utf8
        )

        let preset = try ReaderLayoutPresetImporter.decode(data: data)
        let layout = try #require(preset.readerOverlayLayout)

        #expect(layout.components.count == 4)
        #expect(layout.components.first?.kind == .chapterPage)
    }

    @Test("version two without opening components falls back to legacy fields")
    func incompleteVersionTwoOverlayFallsBackToLegacy() throws {
        let data = Data(
            """
            {
              "readerHeaderVisible": true,
              "readerHeaderFieldPositions": { "chapterTitle": "center" },
              "readerOverlayLayout": {
                "version": 2,
                "components": [],
                "contentReservations": { "top": 20, "bottom": 20 }
              }
            }
            """.utf8
        )

        let preset = try ReaderLayoutPresetImporter.decode(data: data)
        let layout = try #require(preset.readerOverlayLayout)

        #expect(layout.components(for: .chapterOpening).map(\.kind) == [.chapterTitle])
        #expect(layout.components(for: .chapterBody).map(\.kind) == [.chapterTitle])
    }

    @Test("leaves the current overlay untouched when a preset has no overlay fields")
    func noOverlayFieldsProducesNoOverlayReplacement() throws {
        let data = Data(#"{ "textSize": 18 }"#.utf8)

        let preset = try ReaderLayoutPresetImporter.decode(data: data)

        #expect(preset.readerOverlayLayout == nil)
    }
}
