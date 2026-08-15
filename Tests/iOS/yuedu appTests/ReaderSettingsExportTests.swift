import Foundation
import Testing
@testable import yuedu_app

@Suite("Reader settings export")
struct ReaderSettingsExportTests {
    private func makeSnapshot() -> ReaderLayoutSnapshot {
        ReaderLayoutSnapshot(
            name: "測試",
            fontSize: 20,
            isBold: true,
            lineHeightMultiple: 1.8,
            letterSpacing: 1.5,
            paragraphSpacingMultiplier: 0.6,
            pageMarginH: 22,
            pageMarginV: 14,
            footerBottomPadding: 9,
            footerTextGap: 5,
            titleVisible: true,
            titleSize: 22,
            titleTopSpacing: 12,
            titleBottomSpacing: 18,
            pageTurnStyle: .curl,
            scrollMode: false,
            readerOverlayLayout: ReaderOverlayLayoutMigration.defaultLayout
        )
    }

    @Test("round-trips through the one layout importer")
    func roundTripsThroughImporter() throws {
        let snapshot = makeSnapshot()

        let data = try ReaderLayoutPresetExporter.encode(snapshot)
        let preset = try ReaderLayoutPresetImporter.decode(data: data)

        #expect(preset.name == "測試")
        #expect(preset.fontSize == 20)
        #expect(preset.isBold == true)
        #expect(abs((preset.lineHeightMultiple ?? 0) - 1.8) < 0.0001)
        #expect(preset.letterSpacing == 1.5)
        #expect(abs((preset.paragraphSpacingMultiplier ?? 0) - 0.6) < 0.0001)
        #expect(preset.pageMarginH == 22)
        #expect(preset.pageMarginV == 14)
        #expect(preset.titleVisible == true)
        #expect(preset.titleSize == 22)
        #expect(preset.titleTopSpacing == 12)
        #expect(preset.titleBottomSpacing == 18)
        #expect(preset.pageTurnStyle == .curl)
        #expect(preset.scrollMode == false)
        #expect(
            preset.readerOverlayLayout
                == ReaderOverlayLayoutMigration.upgrade(ReaderOverlayLayoutMigration.defaultLayout)
        )
    }

    @Test("scroll mode outranks the page-turn animation, as legado stores it")
    func scrollModeOutranksPageAnimation() throws {
        var snapshot = makeSnapshot()
        snapshot.scrollMode = true

        let preset = try ReaderLayoutPresetImporter.decode(
            data: try ReaderLayoutPresetExporter.encode(snapshot)
        )

        #expect(preset.scrollMode == true)
    }

    @Test("bundle carries the layout through its own decoder")
    func bundleDecodesItsLayout() throws {
        let inputs = ReaderSettingsExportInputs(
            layout: makeSnapshot(),
            chapterTitleStyle: .default,
            regexHighlights: .disabled
        )

        let bundle = try inputs.makeBundle()
        let encoded = try JSONEncoder().encode(bundle)
        let decoded = try JSONDecoder().decode(ReaderSettingsBundle.self, from: encoded)

        #expect(decoded.format == ReaderSettingsBundle.formatIdentifier)
        #expect(decoded.chapterTitleStyle == ChapterTitleStyle.default)
        #expect(decoded.regexHighlights == RegexHighlightConfiguration.disabled)
        #expect(try decoded.decodedLayoutPreset()?.fontSize == 20)
    }

    /// Both schemas decode every field with `decodeIfPresent`, so either decoder
    /// accepts any JSON object. Without the key check, importing a chapter-title
    /// file resets the reader's type size to the layout default.
    @Test("tells a chapter-title JSON apart from a readConfig JSON")
    func discriminatesBareJSONSchemas() throws {
        let titleJSON = Data(
            """
            {"visible": true, "size": 21, "topSpacing": 8, "advancedCSSEnabled": false}
            """.utf8
        )
        let readConfigJSON = Data(
            """
            {"textSize": 17, "paddingLeft": 21, "pageAnim": 0, "headerMode": 1}
            """.utf8
        )

        #expect(ReaderSettingsImportService.looksLikeChapterTitleJSON(titleJSON))
        #expect(!ReaderSettingsImportService.looksLikeChapterTitleJSON(readConfigJSON))
        #expect(!ReaderSettingsImportService.looksLikeChapterTitleJSON(Data("[]".utf8)))
    }

    @Test("an exported layout is never mistaken for a chapter-title file")
    func exportedLayoutIsNotChapterTitle() throws {
        let data = try ReaderLayoutPresetExporter.encode(makeSnapshot())
        #expect(!ReaderSettingsImportService.looksLikeChapterTitleJSON(data))
    }
}
