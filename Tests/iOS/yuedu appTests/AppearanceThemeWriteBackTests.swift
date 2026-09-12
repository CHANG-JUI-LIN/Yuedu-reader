import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// Covers the half of the theme contract that says a theme *keeps* its own set:
/// editing a covered setting records it on the selected theme, leaving the theme
/// hands the user's own settings back, and the artwork a theme still points at is
/// not deleted out from under it.
@Suite("Appearance theme write-back", .serialized)
@MainActor
struct AppearanceThemeWriteBackTests {
    @Test func editingASettingRecordsItOnTheSelectedThemeAndSurvivesASwitch() async throws {
        let settings = GlobalSettings.shared
        let fixture = Fixture(settings)
        defer { fixture.restore() }
        fixture.reset(iconSize: 24, columns: 3)

        let a = Self.colourTheme("A")
        let b = Self.colourTheme("B")
        settings.customAppearanceThemes.append(contentsOf: [a, b])

        // Selecting a colour-only theme changes nothing, but must capture the
        // baseline — otherwise the first edit below would have no way back out.
        settings.appearanceThemeID = a.id
        #expect(settings.rootTabIconSize == 24)
        let baseline = try #require(settings.appearanceExtrasBaseline)
        #expect(baseline.tabIconSize == 24)

        settings.rootTabIconSize = 36
        let stored = try #require(
            settings.customAppearanceThemes.first { $0.id == a.id }?.extras?.tabIconSize
        )
        #expect(stored == 36)

        // B says nothing about the icon size, so it gets the user's own value back.
        settings.appearanceThemeID = b.id
        #expect(settings.rootTabIconSize == 24)

        settings.appearanceThemeID = a.id
        #expect(settings.rootTabIconSize == 36)

        settings.appearanceThemeID = GlobalSettings.defaultAppearanceThemeID
        #expect(settings.rootTabIconSize == 24)
        #expect(settings.appearanceExtrasBaseline == nil)
    }

    @Test func writeBackIsPerFieldSoAThemeKeepsItsSilence() async throws {
        let settings = GlobalSettings.shared
        let fixture = Fixture(settings)
        defer { fixture.restore() }
        fixture.reset(iconSize: 24, columns: 3)
        settings.useDefaultCoverForAllBooks = false

        var declared = AppearanceThemeExtras()
        declared.tabIconSize = 32
        let pack = Self.colourTheme("Pack", extras: declared)
        settings.customAppearanceThemes.append(pack)
        settings.appearanceThemeID = pack.id
        #expect(settings.rootTabIconSize == 32)

        settings.bookshelfGridColumnCount = 5

        let extras = try #require(
            settings.customAppearanceThemes.first { $0.id == pack.id }?.extras
        )
        #expect(extras.bookshelfGridColumnCount == 5)
        // The edit above must not have pinned every other setting to the baseline.
        #expect(extras.forceDefaultCover == nil)
        #expect(extras.defaultCoverLightFileNames == nil)
        #expect(extras.globalFontPostScript == nil)
    }

    @Test func savingTheCurrentAppearanceCapturesTheWholeLook() async throws {
        let settings = GlobalSettings.shared
        let fixture = Fixture(settings)
        defer { fixture.restore() }
        fixture.reset(iconSize: 24, columns: 3)

        settings.interfaceGlassCards = true
        settings.readerChromeHiddenIDs = ["progress"]
        settings.readerChromeColors = ["classic.background": 0x102030]
        settings.useDefaultCoverForAllBooks = true

        let saved = settings.saveCurrentAppearanceAsTheme(
            named: "Whole look",
            basedOn: AppearanceThemePreset.classic
        )
        let extras = try #require(
            settings.customAppearanceThemes.first { $0.id == saved.id }?.extras
        )
        #expect(extras.glassCards == true)
        #expect(extras.readerChromeHiddenIDs == ["progress"])
        #expect(extras.readerChromeColors?["classic.background"] == 0x102030)
        #expect(extras.forceDefaultCover == true)
        #expect(extras.bookshelfGridColumnCount == 3)
    }

    @Test func resettingAnImportedThemeRestoresThePackOriginal() async throws {
        let settings = GlobalSettings.shared
        let fixture = Fixture(settings)
        defer { fixture.restore() }
        fixture.reset(iconSize: 24, columns: 3)

        var original = AppearanceThemeExtras()
        original.tabIconSize = 30
        var pack = Self.colourTheme("Imported", extras: original)
        pack.originalExtras = original
        settings.customAppearanceThemes.append(pack)

        settings.appearanceThemeID = pack.id
        #expect(!settings.canResetCustomAppearanceTheme(id: pack.id))

        settings.rootTabIconSize = 36
        #expect(settings.canResetCustomAppearanceTheme(id: pack.id))

        settings.resetCustomAppearanceTheme(id: pack.id)
        #expect(settings.customAppearanceThemes.first { $0.id == pack.id }?.extras == original)
        // The theme on screen is re-applied in the same turn, not on the next pick.
        #expect(settings.rootTabIconSize == 30)
    }

    @Test func removingACoverAnotherThemeStillShowsLeavesTheFileOnDisk() async throws {
        let settings = GlobalSettings.shared
        let fixture = Fixture(settings)
        defer { fixture.restore() }
        fixture.reset(iconSize: 24, columns: 3)

        let fileName = try DefaultCoverStorageManager.shared.importImage(
            data: Self.pngData(),
            scheme: .light
        )
        let url = try DefaultCoverStorageManager.shared.fileURL(fileName: fileName)
        defer { DefaultCoverStorageManager.shared.delete(fileName: fileName) }
        #expect(FileManager.default.fileExists(atPath: url.path))

        var holder = AppearanceThemeExtras()
        holder.defaultCoverLightFileNames = [fileName]
        let keeper = Self.colourTheme("Keeper", extras: holder)
        settings.customAppearanceThemes.append(keeper)
        settings.defaultCoverLightFileNames = [fileName]

        // 默認 is selected, so this removal is purely the live set losing the cover.
        settings.removeDefaultCover(fileName: fileName, for: .light)
        #expect(settings.defaultCoverLightFileNames.isEmpty)
        #expect(FileManager.default.fileExists(atPath: url.path))

        // Nothing points at it once its last theme is gone.
        settings.deleteCustomAppearanceTheme(id: keeper.id)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func editingAPageBackgroundRecordsItOnTheSelectedTheme() async throws {
        let settings = GlobalSettings.shared
        let fixture = Fixture(settings)
        defer { fixture.restore() }
        fixture.reset(iconSize: 24, columns: 3)

        let a = Self.colourTheme("A")
        let b = Self.colourTheme("B")
        settings.customAppearanceThemes.append(contentsOf: [a, b])

        settings.appearanceThemeID = a.id
        var config = AppearancePageBackgroundConfig()
        config.lightPrimaryHex = 0x112233
        settings.updatePageBackgroundConfig(config, for: .bookshelf)

        let stored = settings.customAppearanceThemes
            .first { $0.id == a.id }?.extras?.pageBackgrounds
        #expect(stored?["bookshelf"]?.lightPrimaryHex == 0x112233)

        // B says nothing about backgrounds, so the user's own (none) come back.
        settings.appearanceThemeID = b.id
        #expect(settings.pageBackgroundConfig(for: .bookshelf).lightPrimaryHex == nil)

        settings.appearanceThemeID = a.id
        #expect(settings.pageBackgroundConfig(for: .bookshelf).lightPrimaryHex == 0x112233)

        settings.appearanceThemeID = GlobalSettings.defaultAppearanceThemeID
        #expect(settings.appearancePageBackgrounds.isEmpty)
    }

    @Test func aPageBackgroundImageAnotherThemeShowsIsNotReclaimed() async throws {
        let settings = GlobalSettings.shared
        let fixture = Fixture(settings)
        defer { fixture.restore() }
        fixture.reset(iconSize: 24, columns: 3)

        let store = AppearancePageBackgroundImageStore.shared
        let fileName = try store.importImage(data: Self.pngData())
        defer { store.delete(fileName: fileName) }

        var config = AppearancePageBackgroundConfig()
        config.lightImageFileName = fileName

        var held = AppearanceThemeExtras()
        held.pageBackgrounds = ["global": config]
        let keeper = Self.colourTheme("Keeper", extras: held)
        settings.customAppearanceThemes.append(keeper)
        // The live settings name the same file — no duplicate copy any more.
        settings.appearancePageBackgrounds = ["global": config]

        settings.resetAllPageBackgrounds()
        #expect(settings.appearancePageBackgrounds.isEmpty)
        #expect(store.fileData(fileName: fileName) != nil)

        settings.deleteCustomAppearanceTheme(id: keeper.id)
        #expect(store.fileData(fileName: fileName) == nil)
    }

    @Test func deletingAThemeReclaimsItsCardArtwork() async throws {
        let settings = GlobalSettings.shared
        let fixture = Fixture(settings)
        defer { fixture.restore() }
        fixture.reset(iconSize: 24, columns: 3)

        let store = AppearanceCardBackgroundImageStore.shared
        let fileName = try store.importImage(data: Self.pngData())
        defer { store.delete(fileName: fileName) }

        let card = AppearanceCardBackground(
            light: AppearanceCardBackgroundLayer(imageFileName: fileName),
            dark: AppearanceCardBackgroundLayer()
        )
        var first = AppearanceThemeExtras()
        first.cardBackground = card
        var second = AppearanceThemeExtras()
        second.cardBackground = card
        let a = Self.colourTheme("Card A", extras: first)
        let b = Self.colourTheme("Card B", extras: second)
        settings.customAppearanceThemes.append(contentsOf: [a, b])

        // Nothing in the app ever deleted from this store, so both halves are new:
        // the second theme must block the delete, and the last one must perform it.
        settings.deleteCustomAppearanceTheme(id: a.id)
        #expect(store.fileData(fileName: fileName) != nil)

        settings.deleteCustomAppearanceTheme(id: b.id)
        #expect(store.fileData(fileName: fileName) == nil)
    }

    @Test func legacyPageBackgroundsMoveIntoExtrasOnLoad() async throws {
        var config = AppearancePageBackgroundConfig()
        config.darkPrimaryHex = 0x445566
        var legacy = Self.colourTheme("Legacy")
        legacy.pageBackgrounds = ["settings": config]

        let migrated = GlobalSettings.migratedPageBackgrounds(legacy)
        #expect(migrated.pageBackgrounds == nil)
        #expect(migrated.extras?.pageBackgrounds?["settings"]?.darkPrimaryHex == 0x445566)

        // A theme that already speaks through extras keeps what it has.
        var current = Self.colourTheme("Current")
        var extras = AppearanceThemeExtras()
        extras.pageBackgrounds = [:]
        current.extras = extras
        current.pageBackgrounds = ["settings": config]
        #expect(GlobalSettings.migratedPageBackgrounds(current).extras?.pageBackgrounds?.isEmpty == true)
    }

    @Test func hidingATabRecordsItOnTheSelectedThemeAndStaysUsable() async throws {
        let settings = GlobalSettings.shared
        let fixture = Fixture(settings)
        defer { fixture.restore() }
        fixture.reset(iconSize: 24, columns: 3)
        settings.rootTabVisibleIDs = RootTabItem.allCases.map(\.rawValue)

        let a = Self.colourTheme("A")
        let b = Self.colourTheme("B")
        settings.customAppearanceThemes.append(contentsOf: [a, b])

        settings.appearanceThemeID = a.id
        settings.rootTabVisibleIDs = [RootTabItem.bookshelf.rawValue]
        // 設定 is re-added by the sanitizer, and that sanitized value is what the theme
        // records — a theme must not be able to store a bar the user cannot escape.
        let stored = settings.customAppearanceThemes.first { $0.id == a.id }?.extras?.visibleTabIDs
        #expect(stored == [RootTabItem.bookshelf.rawValue, RootTabItem.settings.rawValue])

        settings.appearanceThemeID = b.id
        #expect(settings.visibleRootTabs.count == RootTabItem.allCases.count)

        settings.appearanceThemeID = a.id
        #expect(settings.visibleRootTabs == [.bookshelf, .settings])

        settings.appearanceThemeID = GlobalSettings.defaultAppearanceThemeID
        #expect(settings.visibleRootTabs.count == RootTabItem.allCases.count)
    }

    @Test func aThemeNamingNoUsableTabFallsBackRatherThanEmptyingTheBar() async throws {
        let settings = GlobalSettings.shared
        let fixture = Fixture(settings)
        defer { fixture.restore() }
        fixture.reset(iconSize: 24, columns: 3)

        var hostile = AppearanceThemeExtras()
        hostile.visibleTabIDs = ["no-such-tab"]
        let theme = Self.colourTheme("Hostile", extras: hostile)
        settings.customAppearanceThemes.append(theme)

        settings.appearanceThemeID = theme.id
        // Bound first: #expect rewrites `contains(where:)` into a form the compiler
        // reads as a throwing call.
        let keepsAContentTab = settings.visibleRootTabs.contains { $0.isContentTab }
        #expect(settings.visibleRootTabs.contains(.settings))
        #expect(keepsAContentTab)
    }

    // MARK: - Fixture

    private static func colourTheme(
        _ name: String,
        extras: AppearanceThemeExtras? = nil
    ) -> AppearanceCustomTheme {
        AppearanceCustomTheme(
            name: name,
            backgroundHex: 0xFFFFFF, textHex: 0, barHex: 0xFFFFFF,
            accentHex: 0, dialogueHex: 0, extras: extras
        )
    }

    private static func pngData() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4))
        return renderer.pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }

    /// Snapshots every global this suite writes and puts it back. Deliberately
    /// verbose rather than routed through `currentAppearanceExtrasSnapshot()`: the
    /// restore must not depend on the mechanism under test.
    @MainActor
    private final class Fixture {
        private let settings: GlobalSettings
        private let lightID: String
        private let darkID: String
        private let themes: [AppearanceCustomTheme]
        private let baseline: AppearanceThemeExtras?
        private let iconSize: Double
        private let columns: Int
        private let glassCards: Bool
        private let chromeColors: [String: UInt32]
        private let chromeHidden: [String]
        private let forceCover: Bool
        private let lightCovers: [String]
        private let backgrounds: [String: AppearancePageBackgroundConfig]
        private let cardBackground: AppearanceCardBackground?
        private let visibleTabs: [String]

        init(_ settings: GlobalSettings) {
            self.settings = settings
            lightID = settings.appearanceThemeID
            darkID = settings.appearanceDarkThemeID
            themes = settings.customAppearanceThemes
            baseline = settings.appearanceExtrasBaseline
            iconSize = settings.rootTabIconSize
            columns = settings.bookshelfGridColumnCount
            glassCards = settings.interfaceGlassCards
            chromeColors = settings.readerChromeColors
            chromeHidden = settings.readerChromeHiddenIDs
            forceCover = settings.useDefaultCoverForAllBooks
            lightCovers = settings.defaultCoverLightFileNames
            backgrounds = settings.appearancePageBackgrounds
            cardBackground = settings.appearanceCardBackground
            visibleTabs = settings.rootTabVisibleIDs
        }

        /// Puts the app on a built-in preset with a known starting state, so a test
        /// reads the mechanism rather than whatever the simulator was left in.
        func reset(iconSize: Double, columns: Int) {
            settings.appearanceThemeID = GlobalSettings.defaultAppearanceThemeID
            settings.appearanceDarkThemeID = GlobalSettings.defaultAppearanceThemeID
            settings.appearanceExtrasBaseline = nil
            // Clearing the live backgrounds now reclaims the image files nothing else
            // names, so park this simulator's own artwork on a theme first — otherwise
            // the fixture would delete pictures the developer set by hand.
            var custody = AppearanceThemeExtras()
            custody.pageBackgrounds = settings.appearancePageBackgrounds
            settings.customAppearanceThemes = [
                AppearanceCustomTheme(
                    name: "fixture-custody",
                    backgroundHex: 0xFFFFFF, textHex: 0, barHex: 0xFFFFFF,
                    accentHex: 0, dialogueHex: 0, extras: custody
                )
            ]
            settings.appearancePageBackgrounds = [:]
            settings.appearanceCardBackground = nil
            settings.rootTabIconSize = iconSize
            settings.bookshelfGridColumnCount = columns
            settings.defaultCoverLightFileNames = []
        }

        func restore() {
            settings.appearanceThemeID = GlobalSettings.defaultAppearanceThemeID
            settings.appearanceDarkThemeID = GlobalSettings.defaultAppearanceThemeID
            settings.appearanceExtrasBaseline = nil
            settings.customAppearanceThemes = themes
            settings.rootTabIconSize = iconSize
            settings.bookshelfGridColumnCount = columns
            settings.interfaceGlassCards = glassCards
            settings.readerChromeColors = chromeColors
            settings.readerChromeHiddenIDs = chromeHidden
            settings.useDefaultCoverForAllBooks = forceCover
            settings.defaultCoverLightFileNames = lightCovers
            settings.appearancePageBackgrounds = backgrounds
            settings.appearanceCardBackground = cardBackground
            settings.rootTabVisibleIDs = visibleTabs
            settings.appearanceExtrasBaseline = baseline
            settings.appearanceThemeID = lightID
            settings.appearanceDarkThemeID = darkID
        }
    }
}
