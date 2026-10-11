import Foundation
import Testing
import UIKit
@testable import yuedu_app

@Suite("Reeden .red importer", .serialized)
struct ReedenThemeImporterTests {

    // MARK: - Container

    @Test("a plain pack is RED 0x04 followed by a ZIP")
    func readsPlainContainer() throws {
        let zip = Data([0x50, 0x4B, 0x03, 0x04, 0x14, 0x00])
        let payload = try ReedenThemeImporter.zipPayload(of: Data("RED".utf8) + [0x04] + zip)
        #expect(payload == zip)
    }

    @Test("an encrypted pack is recognised from its plaintext header")
    func recognisesEncryptedContainer() {
        let header = Data(#"{"version":2,"containerMode":"reedenPrivate","algorithm":"aes-256-gcm-manifest"}"#.utf8)
        let length = UInt32(header.count)
        var data = Data("RED".utf8) + [0x10]
        data += [UInt8(length >> 24), UInt8((length >> 16) & 0xFF), UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)]
        data += header + Data(repeating: 0xAB, count: 64)
        #expect(throws: QiThemeImportError.encryptedReedenTheme) {
            try ReedenThemeImporter.zipPayload(of: data)
        }
    }

    @Test("anything else is not a Reeden pack — never assumed encrypted", arguments: [
        Data("PK\u{03}\u{04}".utf8),
        Data("RED".utf8) + [0x07, 0x00, 0x00],
        Data("RED".utf8) + [0x04] + Data("not a zip".utf8),
        // Version 0x10 whose header does not say it is encrypted.
        Data("RED".utf8) + [0x10, 0x00, 0x00, 0x00, 0x02] + Data("{}".utf8),
    ])
    func rejectsOtherBytes(data: Data) {
        #expect(throws: QiThemeImportError.notAReedenTheme) {
            try ReedenThemeImporter.zipPayload(of: data)
        }
    }

    // MARK: - Values

    @Test("colours are #AARRGGBB, not QiReader's #RRGGBBAA")
    func parsesARGB() throws {
        let card = try #require(ReedenValue.color("#9FFFECEF"))
        #expect(card.rgb == 0xFFECEF)
        #expect(abs(card.alpha - Double(0x9F) / 255) < 0.0001)
        #expect(ReedenValue.color("#000000")?.rgb == 0x000000)
        #expect(ReedenValue.color("#000000")?.alpha == 1)
        #expect(ReedenValue.color("#FFF") == nil)
        #expect(ReedenValue.color(nil) == nil)
    }

    @Test("tabs map by role, and Reeden-only tabs are dropped")
    func mapsTabs() {
        #expect(ReedenThemeImporter.tabIdentifier(for: "bookshelf") == "bookshelf")
        #expect(ReedenThemeImporter.tabIdentifier(for: "home") == "explore")
        #expect(ReedenThemeImporter.tabIdentifier(for: "feature") == "rss")
        #expect(ReedenThemeImporter.tabIdentifier(for: "settings") == "settings")
        #expect(ReedenThemeImporter.tabIdentifier(for: "notes") == nil)
        #expect(ReedenThemeImporter.tabIdentifier(for: "statistics") == nil)
        // Every mapped id is a real tab.
        for tab in ["bookshelf", "home", "feature", "settings"] {
            let id = ReedenThemeImporter.tabIdentifier(for: tab)
            #expect(id.flatMap(RootTabItem.init(rawValue:)) != nil)
        }
    }

    @Test("only the turn types seen in real packs are mapped")
    func mapsTurnTypes() {
        #expect(ReedenThemeImporter.pageAnim(forTurnPageType: "simulation") == 2)
        #expect(ReedenThemeImporter.pageAnim(forTurnPageType: "cover") == 1)
        // No legado value exists for it; the caller reports it instead.
        #expect(ReedenThemeImporter.pageAnim(forTurnPageType: "none") == nil)
        #expect(ReedenThemeImporter.pageAnim(forTurnPageType: "curl3d") == nil)
    }

    @Test("layout lengths arrive as points, negatives clamped, through the one layout parser")
    func translatesLayout() throws {
        var notes: [String] = []
        let config = ReedenLayoutConfig(
            fontSize: 17, lineSpacing: 14, paragraphSpacing: 26.25, letterSpacing: 0.35,
            paddingLeft: -4, paddingRight: 30, turnPageType: "simulation"
        )
        let data = try #require(ReedenThemeImporter.layoutConfig(config, name: "x", notes: &notes))
        let preset = try ReaderLayoutPresetImporter.decode(data: data)
        #expect(preset.fontSize == 17)
        #expect(preset.pageTurnStyle == .curl)
        // (0 + 30) / 2 — the negative left margin counts as 0.
        #expect(preset.pageMarginH == 15)
        #expect(notes.contains(localized("左右頁邊距不同，本 App 只有單一邊距，已取兩者平均。")))
    }

    // MARK: - Highlight rules & title CSS

    private let schema = ReedenReaderSchema(textColor: "#FF000000", primaryColor: "#FFE08C75")

    @Test("a highlight rule keeps the CSS the codec reads, with placeholders and em resolved")
    func convertsHighlightRule() throws {
        // 薄绿 - 维尼's dialogue rule, verbatim.
        let rule = ReedenHighlightRule(
            name: "对话高亮（普通）",
            keyword: "“[^”]+”|「[^」]+」",
            isRegex: true,
            target: "all",
            enabled: true,
            styleMode: "advanced",
            styleCssText: "font-family: \"reeden-font:F982E6CF1B4F84A68F5392A140E3A7BA\"; color: {primaryColor}; font-weight: 100; reeden-font-bold: 1; font-size: 0.9688em; -webkit-text-stroke-width: 0.5px; -webkit-text-stroke-color: {primaryColor}; letter-spacing: 0px; border-radius: 0px; padding-left: 0px;"
        )
        var notes: [String] = []
        let rules = ReedenThemeImporter.highlightRules(
            [ReedenBoundHighlightRule(id: "x", rule: rule)],
            light: schema, dark: nil, bodySize: 15, notes: &notes
        )
        let imported = try #require(rules.first)
        #expect(imported.pattern == "“[^”]+”|「[^」]+」")
        #expect(imported.isEnabled)
        #expect(!imported.isBuiltIn)
        #expect(imported.lightStyle.text.colorHex == 0xE08C75)
        #expect(abs((imported.lightStyle.text.fontSize ?? 0) - 14.53) < 0.01)
        // The Reeden font and the weight chosen for it do not come across.
        #expect(imported.lightStyle.text.fontPostScriptName == nil)
        #expect(imported.lightStyle.text.fontWeight == nil)
        #expect(imported.darkStyle == imported.lightStyle)
        let droppedNote = try #require(notes.first)
        #expect(droppedNote.contains("-webkit-text-stroke-width"))
        #expect(droppedNote.contains("reeden-font-bold"))
    }

    @Test("rules needing artwork, drop caps or title matching are skipped and named")
    func skipsUnreproducibleRules() {
        let artwork = ReedenHighlightRule(
            name: "春水漾", keyword: "^.", isRegex: true, target: "all", enabled: false,
            styleMode: "advanced", styleCssText: "float: left; background-image: url(\"03CD\");",
            backgroundImageData: "H4sI"
        )
        let title = ReedenHighlightRule(
            name: "疏影", keyword: "x", isRegex: false, target: "title", titleOnly: true,
            enabled: true, styleMode: "advanced", styleCssText: "color: red;"
        )
        var notes: [String] = []
        let rules = ReedenThemeImporter.highlightRules(
            [ReedenBoundHighlightRule(rule: artwork), ReedenBoundHighlightRule(rule: title)],
            light: schema, dark: nil, bodySize: 15, notes: &notes
        )
        #expect(rules.isEmpty)
        #expect(notes == [String(
            format: localized("下列高亮規則需要圖片、首字下沉或只套用於標題，本 App 無法重現，已略過：%@"),
            "春水漾" + localized("、") + "疏影"
        )])
    }

    @Test("a plain keyword is matched literally")
    func escapesPlainKeyword() throws {
        let rule = ReedenHighlightRule(
            name: "literal", keyword: "a.b", isRegex: false, target: "all", enabled: true,
            styleMode: "advanced", styleCssText: "color: #FF0000;"
        )
        var notes: [String] = []
        let imported = try #require(ReedenThemeImporter.highlightRules(
            [ReedenBoundHighlightRule(rule: rule)], light: schema, dark: nil, bodySize: 15, notes: &notes
        ).first)
        #expect(imported.pattern == "a\\.b")
    }

    @MainActor
    @Test("pack rules join the user's; a user with highlighting off sees only the pack's")
    func mergesHighlightConfiguration() {
        let pack = RegexHighlightRule.custom(name: "pack", pattern: "x")
        let on = RegexHighlightConfiguration(isEnabled: true, rules: RegexHighlightRule.builtIns, customRules: [])
        let merged = QiThemeImportService.highlightConfiguration(adding: [pack], to: on)
        #expect(merged.isEnabled)
        #expect(merged.rules.map(\.isEnabled) == RegexHighlightRule.builtIns.map(\.isEnabled))
        #expect(merged.customRules.map(\.name) == ["pack"])

        let off = RegexHighlightConfiguration.disabled
        let switched = QiThemeImportService.highlightConfiguration(adding: [pack], to: off)
        #expect(switched.isEnabled)
        #expect(switched.rules.allSatisfy { !$0.isEnabled })
        #expect(switched.customRules.map(\.isEnabled) == [true])

        // A second import of the same pack (fresh ids) replaces its rules, not stacks them.
        let reparsed = RegexHighlightRule.custom(name: "pack", pattern: "x")
        let again = QiThemeImportService.highlightConfiguration(adding: [reparsed], to: merged)
        #expect(again.customRules.count == 1)
    }

    @Test("a numberTitle style becomes an HTML title template")
    func convertsTitleStyle() throws {
        // 薄绿 - 维尼's title, trimmed.
        let bound = ReedenTitleStyle(
            name: "标题",
            layout: "numberTitle",
            containerCss: "padding: 0.25em 0.3em; display: block; margin-bottom: 20px;",
            numberCss: "color: rgba(255,255,255,1); background-color: {primaryColor}; font-weight: 200; reeden-font-bold: 2; font-size: 1.29em; border-radius: 999px;",
            titleCss: "font-family: \"reeden-font:F982E6CF1B4F84A68F5392A140E3A7BA\"; color: {primaryColor}; text-align: center; font-size: 1.75em; text-decoration-line: underline;"
        )
        var notes: [String] = []
        var base = ChapterTitleStyle.default
        base.alignment = .center
        let style = try #require(ReedenThemeImporter.chapterTitleStyle(
            bound, base: base, bodySize: 15, light: schema, dark: nil, notes: &notes
        ))
        #expect(style.advancedCSSEnabled)
        #expect(style.size == 15)
        #expect(style.lightTemplate.contains("{number}"))
        #expect(style.lightTemplate.contains("{name}"))
        #expect(style.lightTemplate.contains("background-color:#E08C75"))
        #expect(style.lightTemplate.contains("font-size:1.75em"))
        #expect(!style.lightTemplate.contains("reeden"))
        #expect(!style.lightTemplate.contains("{primaryColor}"))
        #expect(style.design != nil)
        #expect(notes.first?.contains("reeden-font-bold") == true)
    }

    // MARK: - Whole pack

    @Test("parses a plain pack into the shared import value")
    func parsesSyntheticPack() async throws {
        let theme: [String: Any] = [
            "name": "Fixture",
            "light": [
                "primaryColor": "#FF8ECFD0",
                "backgroundColor": "#FFFAFCFB",
                "foregroundColor": "#FF3F494B",
                "cardColor": "#80FFFFFF",
                "backgroundImage": "ABC",
                "coverGalleryId": "g1",
                "navbarPackId": "n1",
                "readerColorSchemaId": "r1",
                "bookshelfCarouselImageUrls": ["X"],
            ],
            "dark": ["backgroundColor": "#FF000000", "enabled": false],
        ]
        let layout: [String: Any] = [
            "fontSize": 15.0, "lineSpacing": 10.0, "titleAlign": "right",
            "titleMarginTop": -0.6, "titlePaddingBottom": 9.0, "txtTitleFontSizeDiff": 6.0,
            "fontFamily": "93B45D420466DB80A277AEE41691C790",
        ]
        let schema: [String: Any] = [
            "name": "Reader", "backgroundColor": "#FFF2F2F2", "textColor": "#FF586466",
            "backgroundImageUrl": "DEF",
            "layoutConfig": String(data: try JSONSerialization.data(withJSONObject: layout), encoding: .utf8)!,
        ]
        let pack = try await makePack([
            "theme.json": try JSONSerialization.data(withJSONObject: theme),
            "light/theme_bg.img": png(width: 3, height: 3),
            "cover_gallery/g1/meta.json": Data("{}".utf8),
            "cover_gallery/g1/2.jpg": png(width: 2, height: 2),
            "cover_gallery/g1/1.jpg": png(width: 1, height: 1),
            "navbar_pack/n1/meta.json": Data("{}".utf8),
            "navbar_pack/n1/home_normal.png": png(width: 4, height: 4),
            "navbar_pack/n1/home_selected.png": png(width: 4, height: 4),
            "navbar_pack/n1/notes_normal.png": png(width: 4, height: 4),
            "reader_schema/r1/schema.json": try JSONSerialization.data(withJSONObject: schema),
            "reader_schema/r1/bg.img": png(width: 5, height: 5),
        ])

        let result = try await ReedenThemeImporter.parse(pack)

        #expect(result.name == "Fixture")
        let file = try #require(result.themeFile)
        #expect(file.accentHex == 0x8ECFD0)
        #expect(file.backgroundHex == 0xFAFCFB)
        // `enabled: false` — no authored dark palette.
        #expect(file.darkColors == nil)

        let global = try #require(result.pageBackgrounds[AppearancePageBackgroundScope.global.rawValue])
        #expect(global.lightImage?.fileExtension == "png")
        #expect(global.darkImage == nil)

        // The card's alpha lands on the fill, not in the palette.
        let card = try #require(result.cardBackground)
        #expect(card.light.fillHex == 0xFFFFFF)
        #expect(abs(card.light.fillOpacity - Double(0x80) / 255) < 0.0001)
        #expect(card.dark.isEmpty)

        // 1.jpg before 2.jpg, by number.
        #expect(result.defaultCovers.compactMap { QiThemeImporter.pixelSize(of: $0.data)?.width } == [1, 2])

        #expect(result.tabIcons.map(\.tabID) == ["explore"])
        #expect(result.darkTabIcons.isEmpty)
        #expect(result.notes.contains(String(format: localized("分頁圖示「%@」在本 App 沒有對應的分頁，已略過。"), "notes")))
        #expect(result.notes.contains(localized("選中狀態的分頁圖示未套用：本 App 的分頁圖示分淺色／深色，沒有選中態。")))

        #expect(result.readerBackground != nil)
        #expect(result.readerBackground?.fileName == "bg.png")
        #expect(result.readerTextColorHex == 0x586466)
        #expect(result.readerBackgroundColorHex == 0xF2F2F2)
        #expect(result.darkReaderBackground == nil)

        let preset = try ReaderLayoutPresetImporter.decode(data: try #require(result.layoutConfig))
        #expect(preset.fontSize == 15)
        let title = try #require(result.chapterTitleStyle)
        #expect(title.alignment == .right)
        #expect(title.topSpacing == 0)
        #expect(title.size == 21)

        #expect(result.notes.contains(localized("主題包只記錄了 Reeden 字型庫的編號，沒有附帶字型檔，正文與標題仍使用原本的字型。")))
        #expect(result.notes.contains { $0.contains(localized("書架輪播圖")) })
    }

    @Test("a pack without theme.json is refused")
    func refusesPackWithoutManifest() async throws {
        let pack = try await makePack(["light/theme_bg.img": png(width: 1, height: 1)])
        await #expect(throws: QiThemeImportError.notAReedenTheme) {
            try await ReedenThemeImporter.parse(pack)
        }
    }

    // MARK: - Helpers

    private func makePack(_ entries: [String: Data]) async throws -> Data {
        let archive = try await EPUBTestFixtures.makeArchive(entries: entries)
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
        return Data("RED".utf8) + [0x04] + (try Data(contentsOf: archive))
    }

    private func png(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: width, height: height)
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}

private extension ReedenLayoutConfig {
    init(
        fontSize: Double?, lineSpacing: Double?, paragraphSpacing: Double?, letterSpacing: Double?,
        paddingLeft: Double?, paddingRight: Double?, turnPageType: String?
    ) {
        self.init()
        self.fontSize = fontSize
        self.lineSpacing = lineSpacing
        self.paragraphSpacing = paragraphSpacing
        self.letterSpacing = letterSpacing
        self.paddingLeft = paddingLeft
        self.paddingRight = paddingRight
        self.turnPageType = turnPageType
    }
}
