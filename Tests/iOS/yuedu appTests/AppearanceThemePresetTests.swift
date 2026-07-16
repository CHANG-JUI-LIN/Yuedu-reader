import CoreGraphics
import Testing
import UIKit
@testable import yuedu_app

@Suite("Appearance theme presets", .serialized)
struct AppearanceThemePresetTests {
    @Test("image reader backgrounds keep chrome transparent")
    @MainActor
    func imageReaderBackgroundKeepsChromeTransparent() {
        let settings = GlobalSettings.shared
        let savedMode = settings.readerCustomBackgroundMode
        let savedFileName = settings.readerCustomBackgroundImageFileName
        defer {
            settings.readerCustomBackgroundMode = savedMode
            settings.readerCustomBackgroundImageFileName = savedFileName
        }

        settings.readerCustomBackgroundMode = .image
        settings.readerCustomBackgroundImageFileName = "reader-background-test.jpg"

        let barAlpha = settings.readerCustomBackgroundPreset?.bar.cgColor.alpha
        #expect(barAlpha == 0)
    }

    @Test("free users get classic plus six built-in appearance themes")
    func freeThemeCount() {
        #expect(AppearanceThemePreset.freeSolidPresets.count == 6)
        #expect(AppearanceThemePreset.freeSolidPresets.allSatisfy { !$0.requiresPro })
        #expect(AppearanceThemePreset.classic.isClassic)
        #expect(!AppearanceThemePreset.classic.requiresPro)
        #expect(AppearanceThemePreset.allDefaultPresets.first?.id == AppearanceThemePreset.classicID)
    }

    @Test("classic is the default and the fallback when Pro lapses")
    func classicIsDefault() {
        #expect(GlobalSettings.defaultAppearanceThemeID == AppearanceThemePreset.classicID)
        #expect(AppearanceThemePreset.preset(id: AppearanceThemePreset.classicID)?.isClassic == true)
    }

    @Test("bundled theme packs accept common background image formats")
    func acceptsCommonBackgroundImageFormats() {
        #expect(AppearanceThemePreset.shouldIncludeBundledThemeImage(relativePath: "宮/宮·日.jpg"))
        #expect(AppearanceThemePreset.shouldIncludeBundledThemeImage(relativePath: "主題/example.jpeg"))
        #expect(AppearanceThemePreset.shouldIncludeBundledThemeImage(relativePath: "主題/example.webp"))
        #expect(AppearanceThemePreset.shouldIncludeBundledThemeImage(relativePath: "主題/example.png"))
    }

    @Test("theme scanner skips icon folders and the loose background library")
    func skipsIconFolders() {
        #expect(!AppearanceThemePreset.shouldIncludeBundledThemeImage(relativePath: "芝士就是力量/图标/主页.png"))
        #expect(!AppearanceThemePreset.shouldIncludeBundledThemeImage(relativePath: "Theme/icons/home.png"))
        #expect(!AppearanceThemePreset.shouldIncludeBundledThemeImage(relativePath: "界面背景/example.jpeg"))
    }

    @Test("deleting a selected custom theme falls back to classic")
    @MainActor
    func deleteSelectedCustomThemeFallsBack() {
        let gs = GlobalSettings.shared
        let savedThemes = gs.customAppearanceThemes
        let savedLight = gs.appearanceThemeID
        let savedDark = gs.appearanceDarkThemeID
        defer {
            gs.customAppearanceThemes = savedThemes
            gs.appearanceThemeID = savedLight
            gs.appearanceDarkThemeID = savedDark
        }

        let custom = gs.createCustomAppearanceTheme(from: AppearanceThemePreset.classic)
        gs.appearanceDarkThemeID = custom.id
        #expect(gs.appearanceThemeID == custom.id)

        gs.deleteCustomAppearanceTheme(id: custom.id)
        #expect(!gs.customAppearanceThemes.contains { $0.id == custom.id })
        #expect(gs.appearanceThemeID == GlobalSettings.defaultAppearanceThemeID)
        #expect(gs.appearanceDarkThemeID == GlobalSettings.defaultAppearanceThemeID)
    }
}
