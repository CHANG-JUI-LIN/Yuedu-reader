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
    }
}
