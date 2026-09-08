import Foundation
import ReadiumZIPFoundation
import Testing
import UIKit
@testable import yuedu_app

@Suite("QiReader .qitheme importer", .serialized)
struct QiThemeImporterTests {

    // MARK: - Alias tables
    //
    // QiReader serializes its enums as Simplified-Chinese display strings while ours are
    // Traditional or English. A miss here fails silently — the value falls back to a
    // default rather than erroring — so every alias is asserted directly.

    @Test("maps QiReader page-turn modes onto legado's pageAnim")
    func mapsPageTurnModes() {
        #expect(QiThemeImporter.pageAnim(forPageMode: "滑动") == 0)
        #expect(QiThemeImporter.pageAnim(forPageMode: "覆盖") == 1)
        #expect(QiThemeImporter.pageAnim(forPageMode: "仿真") == 2)
        #expect(QiThemeImporter.pageAnim(forPageMode: "滚动") == 3)
        #expect(QiThemeImporter.pageAnim(forPageMode: "无动画") == -1)
        // Traditional spellings of the same values must map identically.
        #expect(QiThemeImporter.pageAnim(forPageMode: "滑動") == 0)
        // An unknown mode yields nil so the caller keeps the device's own setting.
        #expect(QiThemeImporter.pageAnim(forPageMode: "翻转") == nil)
        #expect(QiThemeImporter.pageAnim(forPageMode: nil) == nil)
    }

    @Test("maps QiReader layout templates onto the reader interface")
    func mapsLayoutTemplates() {
        #expect(QiThemeImporter.readerInterface(forTemplate: "经典") == .classic)
        #expect(QiThemeImporter.readerInterface(forTemplate: "經典") == .classic)
        #expect(QiThemeImporter.readerInterface(forTemplate: "现代") == .modern)
        #expect(QiThemeImporter.readerInterface(forTemplate: "未知樣式") == nil)
    }

    @Test("maps overlay widget names, and refuses to guess unknown ones")
    func mapsOverlayWidgetNames() {
        #expect(QiThemeImporter.overlayKind(for: "章节名") == .chapterTitle)
        #expect(QiThemeImporter.overlayKind(for: "本章进度(文字)") == .chapterPage)
        #expect(QiThemeImporter.overlayKind(for: "书名") == .bookTitle)
        #expect(QiThemeImporter.overlayKind(for: "电量") == .battery)
        #expect(QiThemeImporter.overlayKind(for: "时间") == .currentTime)
        // A widget we cannot map is dropped, never approximated.
        #expect(QiThemeImporter.overlayKind(for: "書籍作者") == nil)
    }

    @Test("maps only the tabs this app actually has")
    func mapsTabIdentifiers() {
        #expect(QiThemeImporter.tabIdentifier(for: "bookshelf") == "bookshelf")
        #expect(QiThemeImporter.tabIdentifier(for: "explore") == "explore")
        // QiReader has these tabs; we do not.
        #expect(QiThemeImporter.tabIdentifier(for: "stats") == nil)
        #expect(QiThemeImporter.tabIdentifier(for: "fileManager") == nil)
    }

    // MARK: - Value parsing

    @Test("parses colours, percentages, pixels and rotations from the designer CSS")
    func parsesCSSValues() throws {
        #expect(QiThemeValue.hex("A1B4AA") == 0xA1B4AA)
        #expect(QiThemeValue.hex("#A1B4AA") == 0xA1B4AA)
        #expect(QiThemeValue.hex("") == nil)
        #expect(QiThemeValue.hex("nope") == nil)
        #expect(abs(try #require(QiThemeValue.percentFraction("24.9%")) - 0.249) < 1e-12)
        #expect(QiThemeValue.percentFraction("auto") == nil)
        #expect(QiThemeValue.pixels("22px") == 22)
        #expect(QiThemeValue.pixels("22") == 22)
        #expect(QiThemeValue.rotationDegrees("rotate(12deg)") == 12)
        #expect(QiThemeValue.rotationDegrees("rotate(0deg)") == 0)
        // Transforms we cannot express on a layer must not be silently read as a rotation.
        #expect(QiThemeValue.rotationDegrees("translate(4px, 2px)") == nil)
    }

    // MARK: - Detection

    @Test("rejects an archive whose manifest sits at the root")
    func rejectsRootManifestArchive() async throws {
        // This is the shape of our own .yuedustyle package. Accepting it would let the
        // Qi path steal a format that already has an importer.
        let archive = try await makeArchive([
            "manifest.json": Data(#"{"version":1}"#.utf8),
        ])
        await #expect(throws: QiThemeImportError.notAQiTheme) {
            _ = try await QiThemeImporter.parse(archive)
        }
    }

    @Test("rejects a UUID-rooted archive whose manifest lacks id and name")
    func rejectsManifestWithoutIdentity() async throws {
        let archive = try await makeArchive([
            "\(UUID().uuidString)/manifest.json": Data(#"{"accentColorHex":"000000"}"#.utf8),
        ])
        await #expect(throws: QiThemeImportError.notAQiTheme) {
            _ = try await QiThemeImporter.parse(archive)
        }
    }

    @Test("rejects an archive with several top-level directories")
    func rejectsMultipleRoots() async throws {
        let archive = try await makeArchive([
            "a/manifest.json": Data(#"{"id":"x","name":"y"}"#.utf8),
            "b/other.json": Data("{}".utf8),
        ])
        await #expect(throws: QiThemeImportError.notAQiTheme) {
            _ = try await QiThemeImporter.parse(archive)
        }
    }

    // MARK: - App-level appearance

    @Test("maps the app-level manifest onto our appearance models")
    func mapsAppearanceManifest() async throws {
        let root = UUID().uuidString
        let manifest: [String: Any] = [
            "id": root,
            "name": "古风",
            "accentColorHex": "A1B4AA",
            "hideTabText": true,
            "tabIconSize": 42,
            "glowIntensity": 0.55,
            "enableFrostedGlass": true,
            "frostedGlassOpacity": 0.75,
            "forceDefaultCover": true,
            "coverCornerRadius": 8,
            "bookshelfGridColumnCount": 3,
            "readerBottomToolbarStyle": "classic",
            "coverImageFiles": ["covers/cover_0.png"],
            "splashEnabled": true,
            "splashImageFiles": ["covers/splash_0.png", "covers/splash_1.png"],
            "defaultBackground": [
                "lightPrimaryColorHex": "FFEBD3",
                "lightSecondaryColorHex": "FFB4AE",
                "darkPrimaryColorHex": "231942",
                "darkSecondaryColorHex": "321E3D",
                "backgroundImageFile": "backgrounds/bg_default_light.png",
                "backgroundImageOpacity": 1,
                "darkBackgroundImageOpacity": 0.1,
            ],
            "tabBackgrounds": [
                "search": ["lightPrimaryColorHex": "112233"],
                // QiReader has a stats tab; we do not, so this one is reported and dropped.
                "stats": ["lightPrimaryColorHex": "445566"],
            ],
            "tabIcons": [
                "bookshelf": ["type": "custom", "imageFileName": "icons/tab_bookshelf.png"],
                "fileManager": ["type": "custom", "imageFileName": "icons/tab_fileManager.png"],
            ],
            "selectedTabIcons": [
                "bookshelf": ["type": "custom", "imageFileName": "icons/sel_bookshelf.png"],
            ],
            "primaryTextColorHex": "253D0E",
            "bookshelfHeaderStyle": "librarySearch",
        ]
        let png = try Self.pngData()
        let archive = try await makeArchive([
            "\(root)/manifest.json": try JSONSerialization.data(withJSONObject: manifest),
            "\(root)/covers/cover_0.png": png,
            "\(root)/covers/splash_0.png": png,
            "\(root)/covers/splash_1.png": png,
            "\(root)/backgrounds/bg_default_light.png": png,
            "\(root)/icons/tab_bookshelf.png": png,
            "\(root)/icons/tab_fileManager.png": png,
        ])

        let result = try await QiThemeImporter.parse(archive)

        #expect(result.name == "古风")
        #expect(result.themeFile?.accentHex == 0xA1B4AA)
        #expect(result.hidesTabLabels == true)
        #expect(result.tabIconSize == 42)
        #expect(result.effects.glowIntensity == 0.55)
        #expect(result.effects.frostedGlass == true)
        // Theirs is opacity, ours is transparency: 0.75 opaque becomes 0.25 transparent.
        #expect(abs(try #require(result.effects.glassTransparency) - 0.25) < 0.0001)
        #expect(result.bookshelf.forceDefaultCover == true)
        #expect(result.bookshelf.gridColumnCount == 3)
        #expect(result.readerInterface == .classic)
        #expect(result.defaultCovers.count == 1)

        // The eight background fields line up one-for-one with ours.
        let global = try #require(result.pageBackgrounds[AppearancePageBackgroundScope.global.rawValue])
        #expect(global.lightPrimaryHex == 0xFFEBD3)
        #expect(global.lightSecondaryHex == 0xFFB4AE)
        #expect(global.darkPrimaryHex == 0x231942)
        #expect(global.darkSecondaryHex == 0x321E3D)
        #expect(global.lightImage != nil)
        #expect(global.lightImageOpacity == 1)
        #expect(global.darkImageOpacity == 0.1)
        #expect(result.pageBackgrounds[AppearancePageBackgroundScope.search.rawValue] != nil)
        #expect(result.pageBackgrounds["stats"] == nil)

        // Only the tab we actually have is imported.
        #expect(result.tabIcons.map(\.tabID) == ["bookshelf"])

        // Multiple splash images collapse to one.
        #expect(result.launchImage != nil)
        #expect(result.launchEnabled == true)

        // Everything lossy is reported rather than dropped in silence.
        let notes = result.notes.joined(separator: "\n")
        #expect(notes.contains("stats"))
        #expect(notes.contains("fileManager"))
        #expect(result.notes.contains(
            localized("選中狀態的分頁圖示未套用：本 App 的分頁圖示分淺色／深色，沒有選中態。")
        ))
        // The fixture gives only the primary level, so the trio cannot be applied —
        // one custom level against two system ones reads as a bug, not a theme.
        #expect(result.themeFile?.textPrimaryHex == 0x253D0E)
        #expect(result.themeFile?.textSecondaryHex == nil)
        #expect(result.notes.contains(
            localized("全域文字顏色需要主要／次要／第三階三個都提供才會套用，這個外觀包只給了一部分。")
        ))
        #expect(result.notes.contains { $0.contains(localized("書架標題樣式")) })
    }

    @Test("maps a complete text-colour trio, and the card background's slice insets")
    func mapsTextColoursAndCardBackground() async throws {
        let root = UUID().uuidString
        let png = try Self.pngData(width: 200, height: 100)
        let manifest: [String: Any] = [
            "id": root,
            "name": "卡片",
            "primaryTextColorHex": "253D0E",
            "secondaryTextColorHex": "375619",
            "tertiaryTextColorHex": "999999",
            "darkPrimaryTextColorHex": "F2F2F2",
            "darkSecondaryTextColorHex": "B8B8B8",
            "darkTertiaryTextColorHex": "7A7A7A",
            "cardBackground": [
                "isEnabled": true,
                "backgroundImageFile": "card-backgrounds/card_light.png",
                "backgroundOpacity": 0.5,
                "cornerRadius": 32,
                "lightImageMode": "nineSlice",
                "darkImageMode": "stretch",
                "lightBackgroundColorHex": "FFFFFF",
                "darkBackgroundColorHex": "1C1C1E",
                "lightBorderColorHex": "E5E5EA",
                "borderWidth": 0.7,
                "borderOpacity": 0.5,
                // 50 of 200 wide and 25 of 100 tall — a quarter in from each edge.
                "lightLayout": [
                    "opacity": 1,
                    "sliceInsets": ["top": 25, "left": 50, "bottom": 25, "right": 50],
                    "contentInsets": ["top": 2, "left": 4, "bottom": 2, "right": 4],
                ],
            ],
        ]
        let archive = try await makeArchive([
            "\(root)/manifest.json": try JSONSerialization.data(withJSONObject: manifest),
            "\(root)/card-backgrounds/card_light.png": png,
        ])
        let result = try await QiThemeImporter.parse(archive)

        let file = try #require(result.themeFile)
        #expect(file.textPrimaryHex == 0x253D0E)
        #expect(file.textSecondaryHex == 0x375619)
        #expect(file.textTertiaryHex == 0x999999)
        #expect(file.darkTextPrimaryHex == 0xF2F2F2)
        #expect(result.notes.contains { $0.contains(localized("全域文字顏色")) } == false)

        let card = try #require(result.cardBackground)
        #expect(result.cardBackgroundImage != nil)
        #expect(card.light.mode == .nineSlice)
        #expect(card.dark.mode == .stretch)
        // Pixel insets become fractions of the source image, so they survive the
        // store's downsampling.
        #expect(abs(card.light.sliceLeft - 0.25) < 0.0001)
        #expect(abs(card.light.sliceTop - 0.25) < 0.0001)
        #expect(card.light.fillHex == 0xFFFFFF)
        #expect(card.light.borderHex == 0xE5E5EA)
        #expect(abs(card.light.imageOpacity - 0.5) < 0.0001)
        // The card's outline stays the app's own, so a pack radius is reported.
        #expect(result.notes.contains(
            localized("卡片背景的圓角未套用：卡片外框由本 App 自己的版面決定。")
        ))
    }

    // MARK: - Reader preset

    @Test("translates the reading preset into legado readConfig keys")
    func translatesReaderPreset() async throws {
        let result = try await parsePack(preset: [
            "name": "江湖浪人",
            "fontSize": 22,
            "isBold": false,
            "lineSpacing": 8,
            "paragraphSpacing": 8,
            "leftPageMargin": 16,
            "rightPageMargin": 16,
            "pageModeRaw": "滑动",
            "layoutTemplateRaw": "经典",
            "textAlignmentRaw": "两端对齐",
            "textIndent": 2,
            "fontWeightRaw": 0.186,
        ])

        let config = try #require(result.layoutConfig)
        let json = try #require(
            try JSONSerialization.jsonObject(with: config) as? [String: Any]
        )
        #expect(json["textSize"] as? Double == 22)
        #expect(json["lineSpacingExtra"] as? Double == 8)
        #expect(json["paragraphSpacing"] as? Double == 8)
        #expect(json["paddingLeft"] as? Double == 16)
        #expect(json["pageAnim"] as? Int == 0)
        #expect(result.readerInterface == .classic)

        // Absent values must be omitted, not written as null: the layout importer gates on
        // which keys are present, so a null key would make an empty preset look recognized.
        #expect(json["titleSize"] == nil)
        #expect(json["headerMode"] == nil)

        // The reading-page settings we cannot reproduce are named.
        #expect(result.notes.contains(localized("字重是連續數值，本 App 只有粗體開關，已略過。")))
        #expect(result.notes.contains(localized("首行縮排固定為兩字元，無法調整，已略過。")))
        #expect(result.notes.contains(localized("正文對齊方式固定為兩端對齊，已略過。")))

        // The translated config must survive the app's single layout parser.
        let preset = try ReaderLayoutPresetImporter.decode(data: config)
        #expect(preset.fontSize == 22)
        #expect(preset.pageTurnStyle == .slide)
    }

    @Test("averages differing left and right margins and says so")
    func averagesAsymmetricMargins() async throws {
        let result = try await parsePack(preset: [
            "fontSize": 20,
            "leftPageMargin": 10,
            "rightPageMargin": 30,
        ])
        let preset = try ReaderLayoutPresetImporter.decode(data: try #require(result.layoutConfig))
        #expect(preset.pageMarginH == 20)
        #expect(result.notes.contains(localized("左右頁邊距不同，本 App 只有單一邊距，已取兩者平均。")))
    }

    // MARK: - Overlay widgets

    @Test("splits overlay widgets by page scope and drops unknown ones by name")
    func mapsOverlayWidgets() async throws {
        let widgets: [[String: Any]] = [
            [
                "item": "章节名",
                "xPercent": 0.05,
                "yPercent": 0.06,
                "fontSize": 12,
                "opacity": 0.4,
                "customColorHex": "000000",
                "pageScope": "仅正文页",
            ],
            [
                "item": "本章进度(文字)",
                "xPercent": 0.6,
                "yPercent": 0.98,
                "fontSize": 12,
                "opacity": 0.4,
                "pageScope": "仅首页",
            ],
            ["item": "書籍作者", "xPercent": 0.1, "yPercent": 0.1, "pageScope": "仅首页"],
        ]
        let result = try await parsePack(preset: [
            "fontSize": 20,
            "layoutWidgetsData": try Self.base64JSON(widgets),
            "topInsetExtra": 10,
            "bottomInsetExtra": 20,
        ])

        let layout = try #require(result.overlayLayout)
        #expect(layout.components.map(\.kind) == [.chapterTitle])
        #expect(layout.chapterOpeningComponents.map(\.kind) == [.chapterPage])
        #expect(layout.contentReservations.top == 10)
        #expect(layout.contentReservations.bottom == 20)

        let body = try #require(layout.components.first)
        #expect(body.style.color.source == .custom)
        // Their hex is RGB; ours is RGBA, so the alpha byte must be filled in.
        #expect(body.style.color.hexRGBA == 0x000000FF)
        #expect(abs(body.position.y - 0.06) < 0.0001)

        #expect(result.notes.contains { $0.contains("書籍作者") })
    }

    // MARK: - Comment bubble

    @Test("imports a raster bubble that draws no count")
    func importsArtworkOnlyBubble() async throws {
        // The 侠客 bubble's real shape: one <image> holding a PNG, and no <text> at all
        // because QiReader was told not to draw the count.
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='90' height='120'"
            + " viewBox='0 0 90 120'><image href='data:image/png;base64,"
            + (try Self.pngData()).base64EncodedString()
            + "' width='90' height='120'/></svg>"
        let bubble: [String: Any] = [
            "name": "侠客",
            "backgroundSVGData": svg,
            "svgSizeMultiplier": 1.7,
            "svgFontScale": 0.3,
            "fillColorHex": "808080",
            "showLabel": false,
            "opacity": 0,
            "cornerRadiusFraction": 0.5,
        ]
        let result = try await parsePack(preset: [
            "fontSize": 20,
            "commentBubbleStyleData": try Self.base64JSON(bubble),
        ])

        let imported = try #require(result.bubble)
        #expect(imported.style.name == "侠客")
        #expect(imported.style.svg == svg)
        #expect(imported.scale == 1.7)
        #expect(imported.textScale == 0.3)
        // No ${color} placeholder in the SVG, so the colour slots stay empty rather than
        // carrying values nothing will ever substitute.
        #expect(imported.style.dayNormalColor == nil)
        #expect(result.notes.contains(localized("段評氣泡設定為不顯示數字，已照原樣匯入（氣泡只顯示圖案）。")))

        // And it must actually be renderable through the user-template path.
        #expect(CommentBubbleSVGRecognizer.recognizeUserTemplate(imported.style.svg) != nil)
    }

    // MARK: - Chapter title

    @Test("builds layers from the light variant and reports a divergent dark one")
    func buildsChapterTitleFromLightVariant() async throws {
        let assetID = "asset-\(UUID().uuidString.lowercased())"
        let light = designerProject(height: 229, elements: [
            element(type: "chapterNumber", z: 0, left: "24.9%", top: "65.6%", width: "60.2%"),
            element(type: "image", z: 4, left: "0%", top: "0%", width: "99.7%", assetId: assetID),
            element(type: "chapterName", z: 3, left: "23.9%", top: "75.6%", width: "60.2%"),
        ])
        let dark = designerProject(height: 205, elements: [
            element(type: "chapterNumber", z: 2, left: "10%", top: "60%", width: "50%"),
        ])
        let package: [String: Any] = [
            "version": 4,
            "name": "江湖浪人",
            "assets": [[
                "id": assetID,
                "fileName": "\(assetID).png",
                "mimeType": "image/png",
                "data": (try Self.pngData()).base64EncodedString(),
            ]],
            "light": [
                "isEnabled": true,
                "useHTMLMode": true,
                "useCustomFont": true,
                "fontSize": 22,
                "fontWeight": "semibold",
                "alignment": "left",
                "topSpacing": 0,
                "bottomSpacing": 0,
                "htmlHeight": 229,
                "chapterNameFont": "YUWEIXSJ2019",
                "chapterNumberFont": "KyoMadoka",
                "maxLines": 2,
                "designerProjectJSON": try Self.jsonString(light),
            ],
            "dark": [
                "isEnabled": true,
                "useHTMLMode": true,
                "htmlHeight": 205,
                "designerProjectJSON": try Self.jsonString(dark),
            ],
        ]
        let result = try await parsePack(preset: ["fontSize": 20], chapterTitlePackage: package)

        let style = try #require(result.chapterTitleStyle)
        #expect(style.advancedCSSEnabled)
        #expect(style.weight == .semibold)
        #expect(style.alignment == .left)
        // `useCustomFont` is the inverse of our `followsBodyFont`.
        #expect(style.followsBodyFont == false)
        #expect(style.nameFontPostScript == "YUWEIXSJ2019")
        #expect(style.numberFontPostScript == "KyoMadoka")

        let design = try #require(style.design)
        #expect(design.canvasHeight == 229)
        // The light variant is the skeleton: three elements in, three layers out, ordered
        // by z-index rather than by their order in the file.
        #expect(design.layers.map(\.kind) == [.chapterNumber, .chapterName, .image])
        let image = try #require(design.layers.first { $0.kind == .image })
        guard case .image = image.content else {
            Issue.record("image layer lost its asset reference")
            return
        }
        let number = try #require(design.layers.first { $0.kind == .chapterNumber })
        #expect(abs(number.frame.x - 0.249) < 0.0001)
        #expect(abs(number.frame.width - 0.602) < 0.0001)

        // Three light elements against one dark one, and 229 vs 205 canvas heights: both
        // divergences must be named, with the real numbers in them.
        #expect(result.notes.contains(String(
            format: localized("章節標題的淺色版有 %d 個圖層、深色版有 %d 個，已以淺色版為準，配不到的圖層沿用淺色樣式。"),
            3,
            1
        )))
        #expect(result.notes.contains(String(
            format: localized("章節標題的淺色與深色畫布高度不同（%d／%d），已採用淺色版的高度。"),
            229,
            205
        )))
        #expect(result.notes.contains { $0.contains(localized("標題最大行數")) })
    }

    // MARK: - Fixtures

    /// Builds a `.qitheme` around one reading preset, so preset-focused tests do not each
    /// have to spell out a whole pack.
    private func parsePack(
        preset: [String: Any],
        chapterTitlePackage: [String: Any]? = nil
    ) async throws -> QiThemeImport {
        let root = UUID().uuidString
        var presetManifest: [String: Any] = ["formatVersion": 2, "preset": preset]
        if let chapterTitlePackage {
            presetManifest["chapterTitleStylePackage"] = chapterTitlePackage
        }
        let presetArchive = try await makeArchive([
            "江湖浪人/manifest.json": try JSONSerialization.data(withJSONObject: presetManifest),
        ])
        let archive = try await makeArchive([
            "\(root)/manifest.json": try JSONSerialization.data(
                withJSONObject: ["id": root, "name": "測試包"]
            ),
            "\(root)/reader_themes/manifest.json": try JSONSerialization.data(
                withJSONObject: [
                    "formatVersion": 1,
                    "bindings": [["presetFile": "reader_0.qipreset", "slot": "light"]],
                ]
            ),
            "\(root)/reader_themes/reader_0.qipreset": presetArchive,
        ])
        return try await QiThemeImporter.parse(archive)
    }

    private func designerProject(height: Double, elements: [[String: Any]]) -> [String: Any] {
        ["schemaVersion": 1, "canvas": ["height": height], "elements": elements]
    }

    private func element(
        type: String,
        z: Int,
        left: String,
        top: String,
        width: String,
        assetId: String = ""
    ) -> [String: Any] {
        [
            "id": "qr-\(type)-\(z)",
            "type": type,
            "visible": true,
            "locked": true,
            "assetId": assetId,
            "css": [
                "left": left,
                "top": top,
                "width": width,
                "height": "auto",
                "z-index": String(z),
                "opacity": "1",
                "transform": "rotate(0deg)",
                "color": "#000000",
                "font-size": "22px",
                "line-height": "1.35",
                "text-align": "center",
            ],
        ]
    }

    private func makeArchive(_ files: [String: Data]) async throws -> Data {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("qitheme-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let archiveURL = directory.appendingPathComponent("pack.qitheme", isDirectory: false)
        let archive = try await Archive(url: archiveURL, accessMode: .create)
        for (path, data) in files.sorted(by: { $0.key < $1.key }) {
            let fileURL = directory.appendingPathComponent(
                path.replacingOccurrences(of: "/", with: "_"),
                isDirectory: false
            )
            try data.write(to: fileURL, options: .atomic)
            try await archive.addEntry(with: path, fileURL: fileURL, compressionMethod: .deflate)
        }
        return try Data(contentsOf: archiveURL)
    }

    private static func pngData(width: Int = 8, height: Int = 8) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        // Scale 1 so the encoded pixel size is exactly what the test asked for —
        // the slice fractions are computed from those pixels.
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height),
            format: format
        )
        let image = renderer.image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return try #require(image.pngData())
    }

    private static func base64JSON(_ object: Any) throws -> String {
        try JSONSerialization.data(withJSONObject: object).base64EncodedString()
    }

    private static func jsonString(_ object: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
}
