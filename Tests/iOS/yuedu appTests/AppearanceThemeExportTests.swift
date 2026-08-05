import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// The theme sharing loop: what an export writes, and what an import accepts.
@Suite("Appearance theme export / import", .serialized)
struct AppearanceThemeExportTests {

    private func makeTheme(
        name: String,
        backgroundHex: UInt32 = 0xEAF2FC,
        pageBackgrounds: [String: AppearancePageBackgroundConfig]? = nil,
        dark: AppearanceCustomThemeDarkColors? = nil
    ) -> AppearanceCustomTheme {
        AppearanceCustomTheme(
            name: name,
            backgroundHex: backgroundHex,
            textHex: 0x263443,
            barHex: 0xDCE9F8,
            accentHex: 0x3478F6,
            dialogueHex: 0xD4E4F7,
            pageBackgrounds: pageBackgrounds,
            dark: dark
        )
    }

    // MARK: - File shapes the importer must accept

    @Test("a single-theme file decodes")
    func decodesSingleThemeFile() throws {
        let file = AppearanceThemeExportFile(customTheme: makeTheme(name: "海霧"))
        let data = try JSONEncoder().encode(file)

        let decoded = AppearanceThemeFileDecoder.themes(in: data)
        #expect(decoded.count == 1)
        #expect(decoded.first?.name == "海霧")
    }

    @Test("a collection file decodes every theme in it")
    func decodesCollectionFile() throws {
        let collection = AppearanceThemeCollectionFile(
            themes: [
                AppearanceThemeExportFile(customTheme: makeTheme(name: "海霧")),
                AppearanceThemeExportFile(customTheme: makeTheme(name: "暮色")),
            ]
        )
        let data = try JSONEncoder().encode(collection)

        let decoded = AppearanceThemeFileDecoder.themes(in: data)
        #expect(decoded.map(\.name) == ["海霧", "暮色"])
    }

    @Test("a bare array of themes decodes")
    func decodesBareArray() throws {
        let files = [
            AppearanceThemeExportFile(customTheme: makeTheme(name: "海霧")),
            AppearanceThemeExportFile(customTheme: makeTheme(name: "暮色")),
        ]
        let data = try JSONEncoder().encode(files)

        #expect(AppearanceThemeFileDecoder.themes(in: data).count == 2)
    }

    @Test("an unrelated JSON file decodes to nothing")
    func rejectsForeignFile() throws {
        let data = try #require(#"{"format":"legado-book-source","name":"x"}"#.data(using: .utf8))
        #expect(AppearanceThemeFileDecoder.themes(in: data).isEmpty)
    }

    // MARK: - Colour fidelity

    @Test("colours and an authored dark palette survive a round trip")
    func roundTripsColours() throws {
        let dark = AppearanceCustomThemeDarkColors(
            backgroundHex: 0x101014,
            textHex: 0xEBEBF0,
            barHex: 0x1C1C1E,
            accentHex: 0x0A84FF,
            dialogueHex: 0x2A3A4A
        )
        let file = AppearanceThemeExportFile(
            customTheme: makeTheme(name: "夜航", backgroundHex: 0x123456, dark: dark)
        )
        let data = try JSONEncoder().encode(file)

        let decoded = try #require(AppearanceThemeFileDecoder.themes(in: data).first)
        #expect(decoded.backgroundHex == 0x123456)
        #expect(decoded.darkColors == dark)
    }

    @Test("a derived dark palette is not exported, so the importer keeps deriving")
    func omitsDerivedDarkPalette() throws {
        let file = AppearanceThemeExportFile(customTheme: makeTheme(name: "海霧", dark: nil))
        #expect(file.darkColors == nil)
    }

    // MARK: - Import

    @Test("importing a collection creates one custom theme per entry")
    @MainActor
    func importsEveryThemeInACollection() throws {
        let settings = GlobalSettings.shared
        let saved = settings.customAppearanceThemes
        let savedID = settings.appearanceThemeID
        defer {
            settings.customAppearanceThemes = saved
            settings.appearanceThemeID = savedID
        }
        settings.customAppearanceThemes = []

        let collection = AppearanceThemeCollectionFile(
            themes: [
                AppearanceThemeExportFile(customTheme: makeTheme(name: "海霧")),
                AppearanceThemeExportFile(customTheme: makeTheme(name: "暮色")),
            ]
        )
        let data = try JSONEncoder().encode(collection)

        let summary = try settings.importAppearanceCustomization(from: data)
        #expect(summary.themes == 2)
        #expect(settings.customAppearanceThemes.count == 2)
        // The last one imported is what the user is left looking at.
        #expect(settings.appearanceThemeID == settings.customAppearanceThemes.last?.id)
    }

    @Test("importing twice keeps both copies under distinct names")
    @MainActor
    func deduplicatesImportedNames() throws {
        let settings = GlobalSettings.shared
        let saved = settings.customAppearanceThemes
        let savedID = settings.appearanceThemeID
        defer {
            settings.customAppearanceThemes = saved
            settings.appearanceThemeID = savedID
        }
        settings.customAppearanceThemes = []

        let file = AppearanceThemeExportFile(customTheme: makeTheme(name: "海霧"))
        let data = try JSONEncoder().encode(file)

        _ = try settings.importAppearanceCustomization(from: data)
        _ = try settings.importAppearanceCustomization(from: data)

        let names = settings.customAppearanceThemes.map(\.name)
        #expect(names.count == 2)
        #expect(Set(names).count == 2)
    }

    @Test("an unreadable file throws instead of importing nothing quietly")
    @MainActor
    func throwsOnForeignFile() throws {
        let settings = GlobalSettings.shared
        let saved = settings.customAppearanceThemes
        defer { settings.customAppearanceThemes = saved }

        let data = try #require("not a theme".data(using: .utf8))
        #expect(throws: AppearanceThemeImportError.self) {
            _ = try settings.importAppearanceCustomization(from: data)
        }
    }

    // MARK: - Which backgrounds travel

    @Test("exporting a saved theme carries its own snapshot, not the live one")
    @MainActor
    func exportsTheThemesOwnSnapshot() throws {
        let settings = GlobalSettings.shared
        let savedThemes = settings.customAppearanceThemes
        let savedBackgrounds = settings.appearancePageBackgrounds
        defer {
            settings.customAppearanceThemes = savedThemes
            settings.appearancePageBackgrounds = savedBackgrounds
        }

        var snapshot = AppearancePageBackgroundConfig()
        snapshot.lightPrimaryHex = 0xAABBCC
        let theme = makeTheme(
            name: "有背景",
            pageBackgrounds: [AppearancePageBackgroundScope.global.rawValue: snapshot]
        )
        settings.customAppearanceThemes = [theme]

        // Live backgrounds are deliberately different from the theme's snapshot.
        var live = AppearancePageBackgroundConfig()
        live.lightPrimaryHex = 0x112233
        settings.appearancePageBackgrounds = [AppearancePageBackgroundScope.global.rawValue: live]

        let exported = settings.appearanceThemeExportSnapshot(
            for: AppearanceThemePreset.preset(from: theme)
        )
        let key = AppearancePageBackgroundScope.global.rawValue
        #expect(exported.pageBackgrounds?[key]?.lightPrimaryHex == 0xAABBCC)
    }

    @Test("exporting a built-in carries the page backgrounds in effect now")
    @MainActor
    func exportsLiveBackgroundsForBuiltIns() throws {
        let settings = GlobalSettings.shared
        let savedBackgrounds = settings.appearancePageBackgrounds
        defer { settings.appearancePageBackgrounds = savedBackgrounds }

        var live = AppearancePageBackgroundConfig()
        live.lightPrimaryHex = 0x112233
        settings.appearancePageBackgrounds = [AppearancePageBackgroundScope.global.rawValue: live]

        let exported = settings.appearanceThemeExportSnapshot(
            for: AppearanceThemePreset.freeSolidPresets[0]
        )
        let key = AppearancePageBackgroundScope.global.rawValue
        #expect(exported.pageBackgrounds?[key]?.lightPrimaryHex == 0x112233)
    }

    // MARK: - Filenames

    @Test("theme names with path separators produce a writable filename")
    func sanitizesExportFilename() {
        let name = AppearanceThemeExportPayload.filename(for: "海/霧\n藍")
        #expect(!name.contains("/"))
        #expect(!name.contains("\n"))
        #expect(name.hasSuffix(".json"))
    }

    @Test("an empty theme name still produces a filename")
    func fallsBackForEmptyName() {
        #expect(AppearanceThemeExportPayload.filename(for: "   ") == "yuedu-theme-theme.json")
    }
}
