import Foundation
import Testing
@testable import yuedu_app

/// Parses the real Reeden packs this compatibility layer was built against (2026-10-11).
///
/// The packs are not in the repository (not ours to redistribute), so each test skips when
/// its file is absent — a green run without them proves nothing about the real files, which
/// is why `ReedenThemeImporterTests` carries the rules that must never regress.
@Suite("Reeden real packs", .serialized)
struct ReedenThemeRealPackTests {
    private static func packURL(_ name: String) -> URL {
        URL(fileURLWithPath: "/Users/zhangruilin/Desktop/Test document/主题/\(name).red")
    }

    private static func hasPack(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: packURL(name).path)
    }

    private static func packData(_ name: String) throws -> Data {
        try Data(contentsOf: packURL(name))
    }

    @Test("薄绿 - 维尼 — reader page, nine covers, dark disabled", .enabled(if: hasPack("应用主题 - 薄绿 - 维尼 未加密"), "Needs Test document/主题/应用主题 - 薄绿 - 维尼 未加密.red"))
    func parsesWeini() async throws {
        let data = try Self.packData("应用主题 - 薄绿 - 维尼 未加密")
        let result = try await ReedenThemeImporter.parse(data)

        #expect(result.name == "薄绿 - 维尼 未加密")
        #expect(result.defaultCovers.count == 9)
        #expect(result.themeFile?.darkColors == nil)
        #expect(result.readerBackground != nil)
        #expect(result.readerTextColorHex == 0x000000)
        let preset = try ReaderLayoutPresetImporter.decode(data: try #require(result.layoutConfig))
        #expect(preset.fontSize == 15)
        #expect(preset.pageTurnStyle == .curl)
        // Its dialogue rule comes across; the numberTitle style becomes a CSS template.
        #expect(result.highlightRules.count == 1)
        #expect(result.chapterTitleStyle?.advancedCSSEnabled == true)
    }

    @Test("铭 - 粉色小窝 — SVG tab icons, translucent cards, authored dark palette", .enabled(if: hasPack("应用主题 - 铭 - 粉色小窝-未加密"), "Needs Test document/主题/应用主题 - 铭 - 粉色小窝-未加密.red"))
    func parsesPinkNest() async throws {
        let data = try Self.packData("应用主题 - 铭 - 粉色小窝-未加密")
        let result = try await ReedenThemeImporter.parse(data)

        // home / bookshelf / feature / settings; notes and statistics have no tab here.
        #expect(Set(result.tabIcons.map(\.tabID)) == ["explore", "bookshelf", "rss", "settings"])
        // The SVGs were rasterized to PNG.
        for icon in result.tabIcons {
            #expect(ReedenThemeImporter.imageExtension(of: icon.image.data) == "png")
        }
        let card = try #require(result.cardBackground)
        #expect(card.light.fillHex == 0xFFECEF)
        #expect(abs(card.light.fillOpacity - Double(0x9F) / 255) < 0.0001)
        #expect(result.themeFile?.darkColors != nil)
        #expect(result.launchImage != nil)
        #expect(result.launchEnabled == true)
        #expect(result.defaultCovers.count == 1)
    }

    @Test("周一 - 米蓝 — separate dark icons, splash, covers and reading page", .enabled(if: hasPack("应用主题 - 周一 - 米蓝（未加密）"), "Needs Test document/主题/应用主题 - 周一 - 米蓝（未加密）.red"))
    func parsesMilan() async throws {
        let data = try Self.packData("应用主题 - 周一 - 米蓝（未加密）")
        let result = try await ReedenThemeImporter.parse(data)

        #expect(!result.tabIcons.isEmpty)
        #expect(!result.darkTabIcons.isEmpty)
        #expect(result.darkLaunchImage != nil)
        #expect(result.darkDefaultCovers.count == 1)
        #expect(result.darkReaderBackground != nil)
        let global = try #require(result.pageBackgrounds[AppearancePageBackgroundScope.global.rawValue])
        #expect(global.darkImage != nil)
    }

    @Test("甜菜小月 - 汀花雨细 — nine-slice card artwork", .enabled(if: hasPack("应用主题 - 甜菜小月 - 汀花雨细未加密"), "Needs Test document/主题/应用主题 - 甜菜小月 - 汀花雨细未加密.red"))
    func parsesTinghua() async throws {
        let data = try Self.packData("应用主题 - 甜菜小月 - 汀花雨细未加密")
        let result = try await ReedenThemeImporter.parse(data)

        let card = try #require(result.cardBackground)
        #expect(card.light.mode == .nineSlice)
        #expect(result.cardBackgroundImage != nil)
    }

    @Test("山风 - 春水漾 — right-aligned title, uneven margins, no-animation reported", .enabled(if: hasPack("应用主题 - 山风 - 春水漾"), "Needs Test document/主题/应用主题 - 山风 - 春水漾.red"))
    func parsesChunshuiyang() async throws {
        let data = try Self.packData("应用主题 - 山风 - 春水漾")
        let result = try await ReedenThemeImporter.parse(data)

        #expect(result.chapterTitleStyle?.alignment == .right)
        let preset = try ReaderLayoutPresetImporter.decode(data: try #require(result.layoutConfig))
        #expect(preset.pageTurnStyle == nil)
        #expect(result.notes.contains(localized("主題設定的「無動畫」翻頁無法隨排版匯入，已保留原本的翻頁方式。")))
        // Both of its rules draw artwork (and both are off in the pack).
        #expect(result.highlightRules.isEmpty)
        #expect(result.notes.contains(localized("左右頁邊距不同，本 App 只有單一邊距，已取兩者平均。")))
    }

    @Test("仿b站 is encrypted and says so", .enabled(if: hasPack("应用主题 - aslan&✩jiushidu✩ - 仿b站 (1)"), "Needs Test document/主题/应用主题 - aslan&✩jiushidu✩ - 仿b站 (1).red"))
    func refusesEncrypted() async throws {
        let data = try Self.packData("应用主题 - aslan&✩jiushidu✩ - 仿b站 (1)")
        await #expect(throws: QiThemeImportError.encryptedReedenTheme) {
            try await ReedenThemeImporter.parse(data)
        }
    }
}
