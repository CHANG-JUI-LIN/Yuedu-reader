import Testing
import UIKit
@testable import yuedu_app

/// `ChapterTitleAttributedBuilder` reads `design` and nothing else, so a style carrying only the
/// HTML templates renders an empty title block — in the reader, not just in the settings preview.
/// `sanitized()` is the single place that bridges the two; these tests pin every entry point that
/// used to bypass it.
@Suite("Chapter title template bridge")
struct ChapterTitleTemplateBridgeTests {
    @Test("every built-in CSS preset carries a renderable design")
    func builtinPresetsCarryDesign() throws {
        #expect(!ChapterTitleStylePreset.builtins.isEmpty)

        for preset in ChapterTitleStylePreset.builtins {
            #expect(preset.style.advancedCSSEnabled)
            let design = try #require(
                preset.style.design,
                "\(preset.name) has no design and would render nothing"
            )
            let source = try #require(design.legacySource)
            #expect(source.light == preset.style.lightTemplate)
            #expect(source.dark == preset.style.darkTemplate)
        }
    }

    @Test("switching advanced CSS on bridges the current templates")
    func enablingAdvancedCSSBridges() throws {
        var style = ChapterTitleStyle.default
        #expect(style.design == nil)

        style.advancedCSSEnabled = true
        let sanitized = style.sanitized()

        let design = try #require(sanitized.design)
        #expect(design.layers.isEmpty)
        #expect(design.legacySource?.light == ChapterTitleStyle.defaultLightTemplate)
    }

    @Test("an existing structured design is never overwritten")
    func structuredDesignWins() throws {
        var style = ChapterTitleStyle.default
        style.advancedCSSEnabled = true
        style.design = ChapterTitleDesign.default

        let sanitized = style.sanitized()

        #expect(sanitized.design?.layers.isEmpty == false)
        #expect(sanitized.design?.legacySource == nil)
    }

    @Test("plain styles stay template-free")
    func plainStyleKeepsNoDesign() {
        let sanitized = ChapterTitleStyle.default.sanitized()

        #expect(!sanitized.advancedCSSEnabled)
        #expect(sanitized.design == nil)
    }

    @Test("a built-in preset actually appends a title block")
    func builtinPresetRendersSomething() async throws {
        let preset = try #require(
            ChapterTitleStylePreset.builtins.first(where: { $0.id == "builtin.css.centered" })
        )
        let settings = ReaderRenderSettings(
            theme: "test",
            textColor: .black,
            backgroundColor: .white,
            fontSize: 17,
            lineHeightMultiple: 1.2,
            lineSpacing: 0,
            paragraphSpacing: 8,
            letterSpacing: 0,
            marginH: 0,
            marginV: 0,
            footerHeight: 0,
            contentInsets: .zero,
            chapterTitleStyle: preset.style
        )
        let attributed = NSMutableAttributedString()

        await ChapterTitleAttributedBuilder.append(
            title: "第一章 初入江湖",
            style: preset.style,
            settings: settings,
            renderWidth: 320,
            themeTextColor: .black,
            themeBackgroundColor: .white,
            letterSpacing: 0,
            to: attributed
        )

        #expect(attributed.length > 0)
    }
}
