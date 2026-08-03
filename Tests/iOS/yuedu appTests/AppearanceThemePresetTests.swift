import Testing
import SwiftUI
import UIKit
@testable import yuedu_app

@Suite("Appearance theme presets", .serialized)
struct AppearanceThemePresetTests {
    @Test("image reader backgrounds keep the white chrome")
    @MainActor
    func imageReaderBackgroundKeepsWhiteChrome() {
        let settings = GlobalSettings.shared
        let savedMode = settings.readerCustomBackgroundMode
        let savedFileName = settings.readerCustomBackgroundImageFileName
        defer {
            settings.readerCustomBackgroundMode = savedMode
            settings.readerCustomBackgroundImageFileName = savedFileName
        }

        settings.readerCustomBackgroundMode = .image
        settings.readerCustomBackgroundImageFileName = "reader-background-test.jpg"

        let barColor = settings.readerCustomBackgroundPreset?.bar
        #expect(barColor?.rgbHex == UIColor.white.rgbHex)
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

    @Test("app appearance can pin the current color scheme independently of the system")
    @MainActor
    func appAppearanceCanPinColorScheme() {
        let settings = GlobalSettings.shared
        let savedFollowsSystem = settings.appearanceFollowsSystem
        let savedPinnedScheme = settings.appearancePinnedColorScheme
        defer {
            settings.appearanceFollowsSystem = savedFollowsSystem
            settings.appearancePinnedColorScheme = savedPinnedScheme
        }

        #expect(GlobalSettings.defaultAppearanceFollowsSystem)

        settings.setAppearanceFollowsSystem(false, currentColorScheme: .dark)
        #expect(!settings.appearanceFollowsSystem)
        #expect(settings.appearancePinnedColorScheme == .dark)
        #expect(settings.effectiveAppearanceColorScheme(systemColorScheme: .light) == .dark)

        settings.setAppearanceFollowsSystem(true, currentColorScheme: .light)
        #expect(settings.effectiveAppearanceColorScheme(systemColorScheme: .light) == .light)
        #expect(settings.effectiveAppearanceColorScheme(systemColorScheme: .dark) == .dark)
    }

    @Test("invalid stored appearance schemes fall back to light")
    func invalidStoredAppearanceSchemeFallsBackToLight() {
        #expect(AppearanceColorScheme(storageValue: "unknown") == .light)
        #expect(AppearanceColorScheme(storageValue: nil) == .light)
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
