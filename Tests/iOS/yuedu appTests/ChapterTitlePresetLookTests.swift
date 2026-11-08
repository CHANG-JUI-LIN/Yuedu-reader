import CoreGraphics
import Foundation
import Testing
@testable import yuedu_app

/// FB-162: picking a chapter-title preset must change only how the title looks,
/// never the size the reader chose. Reported on 3.0.1 (146): pick 「侠客标题」 (a
/// saved "my preset" holding size 22), raise 標題大小 to 26 — the ✓ disappears —
/// pick 「侠客标题」 again and the size snaps back to 22.
@Suite("Chapter title preset look")
struct ChapterTitlePresetLookTests {

    private static func savedPreset() -> ChapterTitleStylePreset {
        var style = ChapterTitleStyle.default
        style.size = 22
        style.topSpacing = 12
        style.bottomSpacing = 18
        style.weight = .medium
        style.alignment = .center
        style.splitEnabled = true
        style.numberRelativeSize = 0.6
        return ChapterTitleStylePreset(name: "侠客标题", style: style.sanitized())
    }

    @Test func applyingPresetKeepsReaderSizeAndSpacing() {
        let preset = Self.savedPreset()
        var current = preset.style
        current.size = 26
        current.topSpacing = 40
        current.bottomSpacing = 50
        current.visible = false

        let applied = current.applyingLook(of: preset.style)

        #expect(applied.size == 26)
        #expect(applied.topSpacing == 40)
        #expect(applied.bottomSpacing == 50)
        #expect(applied.visible == false)
        #expect(applied.weight == .medium)
        #expect(applied.alignment == .center)
        #expect(applied.splitEnabled)
        #expect(applied.numberRelativeSize == 0.6)
    }

    @Test func presetStaysSelectedAfterSizeChange() {
        let preset = Self.savedPreset()
        var current = preset.style
        current.size = 26
        current.topSpacing = 40

        #expect(current.matchesLook(preset.style))
        current.weight = .bold
        #expect(!current.matchesLook(preset.style))
    }

    @Test func builtinCSSPresetKeepsReaderSize() throws {
        let builtin = try #require(ChapterTitleStylePreset.builtins.first { $0.id == "builtin.css.ink" })
        var current = ChapterTitleStyle.default
        current.size = 19

        let applied = current.applyingLook(of: builtin.style).sanitized()

        #expect(applied.size == 19)
        #expect(applied.advancedCSSEnabled)
        #expect(applied.lightTemplate == builtin.style.lightTemplate)
        #expect(applied.design == builtin.style.design)
        #expect(applied.matchesLook(builtin.style))
    }

    @Test func savingUnderExistingNameReplacesIt() {
        let existing = Self.savedPreset()
        var style = existing.style
        style.weight = .light

        let saved = ChapterTitleStylePreset.userPreset(named: "侠客标题", style: style, replacingIn: [existing])
        let other = ChapterTitleStylePreset.userPreset(named: "新樣式", style: style, replacingIn: [existing])

        #expect(saved.id == existing.id)
        #expect(saved.style.weight == .light)
        #expect(other.id != existing.id)
    }
}
