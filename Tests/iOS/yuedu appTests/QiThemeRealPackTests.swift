import Foundation
import Testing
@testable import yuedu_app

/// Parses the three real QiReader packs this compatibility layer was built against.
///
/// Synthesized fixtures cover the mapping rules; these cover the file *as authored* — the
/// 24MB bundled font, the real designer project JSON, the base64-inlined chapter-title
/// artwork, and the nested `.qipreset` archive. They are the only check that the format
/// notes in `QiThemeManifest` still describe reality.
///
/// The packs are not in the repository (41MB, and not ours to redistribute), so each test
/// skips when its file is absent. That means a green run on a machine without them proves
/// nothing about the real files — which is why the synthesized suite carries the assertions
/// that must never regress.
@Suite("QiReader real packs", .serialized)
struct QiThemeRealPackTests {
    /// Simulator tests run with the host filesystem visible, so the packs are read from
    /// where they were downloaded rather than copied into the test bundle.
    private static func packData(_ name: String) -> Data? {
        let url = URL(fileURLWithPath: "/Users/zhangruilin/Downloads/\(name).qitheme")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? Data(contentsOf: url)
    }

    @Test("parses 古风 — icons, backgrounds, covers and a bundled font")
    func parsesGufeng() async throws {
        guard let data = Self.packData("古风") else { return }
        let result = try await QiThemeImporter.parse(data)

        #expect(result.name == "古风")
        #expect(result.hidesTabLabels == true)
        #expect(result.bookshelf.forceDefaultCover == true)
        #expect(result.defaultCovers.count == 5)
        // Four of its five tabs exist here; `stats` does not.
        #expect(result.tabIcons.count == 4)
        // The bundled font's zip entry has a CJK name stored without the UTF-8 flag; if
        // the name repair regresses, this is the assertion that catches it.
        let font = try #require(result.font)
        #expect(font.declaredPostScriptName == "Huiwen-mincho")
        #expect(font.originalFileName == "汇文明朝体.ttf")
        #expect(font.data.count == 24_426_256)

        // It ships light and dark artwork for the global background plus two tab scopes.
        let global = try #require(result.pageBackgrounds[AppearancePageBackgroundScope.global.rawValue])
        #expect(global.lightImage != nil)
        #expect(global.darkImage != nil)
        #expect(result.pageBackgrounds[AppearancePageBackgroundScope.search.rawValue] != nil)
        #expect(result.pageBackgrounds[AppearancePageBackgroundScope.settings.rawValue] != nil)

        // Its glass opacity of 0.75 must arrive as a transparency of 0.25, not 0.75.
        #expect(abs(try #require(result.effects.glassTransparency) - 0.25) < 0.0001)

        // No reader preset in this pack.
        #expect(result.chapterTitleStyle == nil)
        #expect(result.layoutConfig == nil)
    }

    @Test("parses 山风-与花同月 — frosted glass and a single cover")
    func parsesShanfeng() async throws {
        guard let data = Self.packData("山风-与花同月") else { return }
        let result = try await QiThemeImporter.parse(data)

        #expect(result.name == "山风-与花同月")
        #expect(result.effects.frostedGlass == true)
        // frostedGlassOpacity 0.1 → transparency 0.9.
        #expect(abs(try #require(result.effects.glassTransparency) - 0.9) < 0.0001)
        #expect(result.defaultCovers.count == 1)
        let font = try #require(result.font)
        #expect(font.declaredPostScriptName == "YWCLLDYW")
        #expect(font.originalFileName == "眼尾残留淚的余温.ttf")
        #expect(result.themeFile?.accentHex == 0xA1B4AA)

        let global = try #require(result.pageBackgrounds[AppearancePageBackgroundScope.global.rawValue])
        #expect(global.lightPrimaryHex == 0xFFEBD3)
        #expect(global.darkPrimaryHex == 0x231942)
    }

    @Test("parses 自制- 江湖侠客 — the reader preset, chapter title and raster bubble")
    func parsesJianghu() async throws {
        guard let data = Self.packData("自制- 江湖侠客") else { return }
        let result = try await QiThemeImporter.parse(data)

        #expect(result.name == "自制- 江湖侠客")
        #expect(result.readerInterface == .classic)
        #expect(result.defaultCovers.count == 8)
        #expect(result.launchImage != nil)

        // Layout: 22pt type, 16pt margins, slide page turns.
        let config = try #require(result.layoutConfig)
        let preset = try ReaderLayoutPresetImporter.decode(data: config)
        #expect(preset.fontSize == 22)
        #expect(preset.pageMarginH == 16)
        #expect(preset.pageTurnStyle == .slide)

        // Chapter title: five light elements become five layers, ordered by z-index, and
        // the three-element dark variant is reported rather than silently reshaping it.
        let style = try #require(result.chapterTitleStyle)
        #expect(style.advancedCSSEnabled)
        let design = try #require(style.design)
        #expect(design.layers.count == 5)
        #expect(design.canvasHeight == 229)
        #expect(design.layers.filter { $0.kind == .image }.count == 3)
        #expect(design.layers.contains { $0.kind == .chapterName })
        #expect(design.layers.contains { $0.kind == .chapterNumber })
        // Every image layer must have resolved to a real asset in our store.
        for layer in design.layers where layer.kind == .image {
            guard case .image = layer.content else {
                Issue.record("image layer \(layer.name) lost its asset")
                continue
            }
        }
        // Five light layers against three dark ones — named with the real counts.
        #expect(result.notes.contains(String(
            format: localized("章節標題的淺色版有 %d 個圖層、深色版有 %d 個，已以淺色版為準，配不到的圖層沿用淺色樣式。"),
            5,
            3
        )))

        // The 侠客 bubble: 88KB of base64 PNG, no <text>, and it must be renderable.
        let bubble = try #require(result.bubble)
        #expect(bubble.style.svg.utf8.count > CommentBubbleSVGRecognizer.maximumRecognizableSVGByteCount)
        #expect(CommentBubbleSVGRecognizer.recognizeUserTemplate(bubble.style.svg) != nil)
        // The pack stores 1.7000000000000002, so this is a tolerance comparison.
        #expect(abs(try #require(bubble.scale) - 1.7) < 0.0001)
        #expect(abs(try #require(bubble.textScale) - 0.3) < 0.0001)

        // Overlay widgets: one on the opening page, two in the body.
        let overlay = try #require(result.overlayLayout)
        #expect(overlay.chapterOpeningComponents.count == 1)
        #expect(overlay.components.count == 2)
    }
}
