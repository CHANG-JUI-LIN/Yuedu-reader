import Testing
import UIKit
@testable import yuedu_app

/// 文字顏色 in 閱讀設定 stores one color per reading background. These cover the
/// resolution order in `ReaderTheme.uiTextColor` — the user's own pick outranks a
/// bound appearance palette, and clearing it hands the background back to 跟隨主題.
@Suite("Reader Text Color Override")
struct ReaderTextColorOverrideTests {
    private func withCleanOverrides(_ body: () throws -> Void) rethrows {
        let settings = GlobalSettings.shared
        let previousOverrides = settings.readerTextColorOverrides
        let previousActiveTheme = AppearanceThemePreset.activeReaderTheme
        settings.readerTextColorOverrides = [:]
        AppearanceThemePreset.activeReaderTheme = nil
        defer {
            settings.readerTextColorOverrides = previousOverrides
            AppearanceThemePreset.activeReaderTheme = previousActiveTheme
        }
        try body()
    }

    private func rgb(_ color: UIColor) -> UInt32? {
        color.rgbHex
    }

    @Test("no override leaves every background on its built-in text color")
    func defaultsToTheme() {
        withCleanOverrides {
            #expect(GlobalSettings.shared.readerTextColorOverride(for: .white) == nil)
            #expect(rgb(ReaderTheme.white.uiTextColor) == 0x333333)
            #expect(rgb(ReaderTheme.night.uiTextColor) == 0xD9D9D9)
        }
    }

    @Test("an override repaints only the background it was set on")
    func overrideIsPerBackground() {
        withCleanOverrides {
            GlobalSettings.shared.setReaderTextColorOverride(0xFF0000, for: .white)

            #expect(rgb(ReaderTheme.white.uiTextColor) == 0xFF0000)
            // 黑色 keeps its own color, which is the point of keying per
            // background: red-on-white can't follow the reader into night mode.
            #expect(rgb(ReaderTheme.night.uiTextColor) == 0xD9D9D9)
        }
    }

    @Test("clearing an override goes back to 跟隨主題")
    func clearingRestoresTheme() {
        withCleanOverrides {
            let settings = GlobalSettings.shared
            settings.setReaderTextColorOverride(0x00FF00, for: .sepia)
            #expect(rgb(ReaderTheme.sepia.uiTextColor) == 0x00FF00)

            settings.setReaderTextColorOverride(nil, for: .sepia)
            #expect(settings.readerTextColorOverride(for: .sepia) == nil)
            #expect(rgb(ReaderTheme.sepia.uiTextColor) == 0x5B4636)
        }
    }

    @Test("the user's pick outranks a bound appearance palette")
    func overrideBeatsAppearancePreset() {
        withCleanOverrides {
            AppearanceThemePreset.activeReaderTheme = AppearanceThemePreset(
                id: "test_palette",
                nameKey: "測試",
                displayName: "測試",
                background: AppearanceThemePreset.hex(0xFFFFFF),
                text: AppearanceThemePreset.hex(0x112233),
                bar: AppearanceThemePreset.hex(0xFFFFFF),
                accent: AppearanceThemePreset.hex(0x007AFF),
                dialogue: AppearanceThemePreset.hex(0x007AFF),
                previewBackground: AppearanceThemePreset.hex(0xFFFFFF),
                relativePreviewImagePath: nil,
                imagePaths: [],
                requiresPro: false,
                isImagePreset: false,
                isCustom: true
            )
            #expect(rgb(ReaderTheme.white.uiTextColor) == 0x112233)

            GlobalSettings.shared.setReaderTextColorOverride(0xABCDEF, for: .white)
            #expect(rgb(ReaderTheme.white.uiTextColor) == 0xABCDEF)
        }
    }

    @Test("overrides survive a round trip through synced reader preferences")
    func syncsThroughReaderPreferences() {
        withCleanOverrides {
            let settings = GlobalSettings.shared
            settings.setReaderTextColorOverride(0x445566, for: .green)

            let snapshot = ReaderPreferences.current(settings: settings)
            #expect(snapshot.readerTextColorOverrides?[ReaderTheme.green.rawValue] == 0x445566)
        }
    }
}
