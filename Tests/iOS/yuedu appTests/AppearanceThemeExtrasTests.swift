import Foundation
import Testing
@testable import yuedu_app

@Suite("Appearance theme extras restoration", .serialized)
@MainActor
struct AppearanceThemeExtrasTests {
    @Test func switchingPacksRestoresUnspecifiedFieldsAndDefaultRestoresBaseline() async throws {
        let settings = GlobalSettings.shared
        let oldLight = settings.appearanceThemeID
        let oldDark = settings.appearanceDarkThemeID
        let oldThemes = settings.customAppearanceThemes
        let oldBaseline = settings.appearanceExtrasBaseline
        let oldIconSize = settings.rootTabIconSize
        let oldHidden = settings.rootTabHidesLabels
        let oldColumns = settings.bookshelfGridColumnCount
        let oldBackgrounds = settings.appearancePageBackgrounds
        defer {
            settings.appearanceThemeID = GlobalSettings.defaultAppearanceThemeID
            settings.appearanceDarkThemeID = GlobalSettings.defaultAppearanceThemeID
            settings.customAppearanceThemes = oldThemes
            settings.rootTabIconSize = oldIconSize
            settings.rootTabHidesLabels = oldHidden
            settings.bookshelfGridColumnCount = oldColumns
            settings.appearanceExtrasBaseline = oldBaseline
            settings.appearanceThemeID = oldLight
            settings.appearanceDarkThemeID = oldDark
            settings.appearancePageBackgrounds = oldBackgrounds
        }
        settings.appearanceThemeID = GlobalSettings.defaultAppearanceThemeID
        settings.appearanceDarkThemeID = GlobalSettings.defaultAppearanceThemeID
        // The import service replaces the live background files; keep any
        // pre-existing simulator artwork outside this fixture's ownership.
        settings.appearancePageBackgrounds = [:]
        settings.rootTabIconSize = 24
        settings.rootTabHidesLabels = false
        settings.bookshelfGridColumnCount = 3

        var first = AppearanceThemeExtras()
        first.tabIconSize = 32
        first.hidesTabLabels = true
        var second = AppearanceThemeExtras()
        second.bookshelfGridColumnCount = 4
        let a = theme("A", extras: first)
        let b = theme("B", extras: second)
        settings.customAppearanceThemes.append(b)
        // Exercise the actual compatibility-layer apply path. It must capture
        // the baseline before installing the pack's live settings.
        var imported = QiThemeImport(name: a.name, themeFile: AppearanceThemeExportFile(customTheme: a))
        imported.tabIconSize = first.tabIconSize
        imported.hidesTabLabels = first.hidesTabLabels
        let outcome = try await QiThemeImportService.apply(imported, includeOverlayLayout: false)
        #expect(outcome.appearance.themes == 1)
        #expect(settings.rootTabIconSize == 32)
        #expect(settings.rootTabHidesLabels)
        let baseline = try #require(settings.appearanceExtrasBaseline)
        #expect(baseline.tabIconSize == 24)

        settings.appearanceThemeID = b.id
        #expect(settings.bookshelfGridColumnCount == 4)
        #expect(settings.rootTabIconSize == 24)
        #expect(!settings.rootTabHidesLabels)
        #expect(settings.appearanceExtrasBaseline == baseline)

        settings.appearanceThemeID = GlobalSettings.defaultAppearanceThemeID
        #expect(settings.bookshelfGridColumnCount == 3)
        #expect(settings.rootTabIconSize == 24)
        #expect(!settings.rootTabHidesLabels)
        #expect(settings.appearanceExtrasBaseline == nil)
    }

    private func theme(_ name: String, extras: AppearanceThemeExtras) -> AppearanceCustomTheme {
        AppearanceCustomTheme(name: name, backgroundHex: 0xFFFFFF, textHex: 0,
                              barHex: 0xFFFFFF, accentHex: 0, dialogueHex: 0, extras: extras)
    }
}
