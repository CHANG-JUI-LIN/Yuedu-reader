import Foundation
import Testing
import YueduCoreText
@testable import yuedu_app

/// 排版生效範圍: per reading setting, the worn theme's own value or the one every theme
/// shares. Every setting follows the theme unless the user shares it — a theme, a pack
/// above all, is a whole look (「主題包的設置要獨立」, 2026-09-29). Nothing a theme keeps is
/// lost by changing the scope.
@Suite("排版生效範圍", .serialized)
@MainActor
struct ReadingSettingsScopeTests {
    private var defaultID: String { GlobalSettings.defaultAppearanceThemeID }

    // MARK: - Wearing

    /// The report: a pack's reading setup has to be worn with the pack, and only there.
    @Test func aThemesOwnSetupIsWornWithTheTheme() throws {
        let settings = GlobalSettings.shared
        let fixture = Fixture(settings)
        defer { fixture.restore() }
        fixture.reset()

        var reading = AppearanceThemeReadingSettings()
        reading.fontSize = 24
        reading.scrollMode = true
        let pack = Self.theme("Pack", reading: reading)
        settings.customAppearanceThemes.append(pack)

        settings.appearanceThemeID = pack.id
        #expect(settings.readerFontSize == 24)
        #expect(settings.scrollMode)
        #expect(ReaderConfig.shared.fontSize == 24)

        settings.appearanceThemeID = defaultID
        #expect(settings.readerFontSize == 18)
        #expect(!settings.scrollMode)
        #expect(ReaderConfig.shared.fontSize == 18)
    }

    /// Two packs, each its own: switching swaps the whole setup, and an edit made under
    /// one reaches neither the other nor 默認.
    @Test func eachPackKeepsItsOwnSetup() throws {
        let settings = GlobalSettings.shared
        let fixture = Fixture(settings)
        defer { fixture.restore() }
        fixture.reset()

        var first = AppearanceThemeReadingSettings()
        first.fontSize = 24
        var second = AppearanceThemeReadingSettings()
        second.fontSize = 28
        second.lineHeightMultiple = 2.0
        let packA = Self.theme("A", reading: first)
        let packB = Self.theme("B", reading: second)
        settings.customAppearanceThemes.append(contentsOf: [packA, packB])

        settings.appearanceThemeID = packA.id
        settings.letterSpacing = 1.5
        #expect(Self.ownReading(of: packA.id)?.letterSpacing == 1.5)

        settings.appearanceThemeID = packB.id
        #expect(settings.readerFontSize == 28)
        #expect(settings.lineHeightMultiple == 2.0)
        #expect(settings.letterSpacing == 0)

        settings.appearanceThemeID = defaultID
        #expect(settings.readerFontSize == 18)
        #expect(settings.lineHeightMultiple == 1.6)
        #expect(settings.letterSpacing == 0)

        settings.appearanceThemeID = packA.id
        #expect(settings.readerFontSize == 24)
        #expect(settings.letterSpacing == 1.5)
        // A pack has no value of its own for this one: it wears 全域's.
        #expect(settings.lineHeightMultiple == 1.6)
    }

    @Test func aSettingTheUserSharesIsTheSameOnEveryTheme() throws {
        let settings = GlobalSettings.shared
        let fixture = Fixture(settings)
        defer { fixture.restore() }
        fixture.reset()

        var reading = AppearanceThemeReadingSettings()
        reading.fontSize = 24
        let pack = Self.theme("Pack", reading: reading)
        settings.customAppearanceThemes.append(pack)
        settings.setReadingSettingsScope(.global, for: .fontSize)

        settings.appearanceThemeID = pack.id
        #expect(settings.readerFontSize == 18)
        settings.readerFontSize = 20
        #expect(settings.globalReadingSettings.fontSize == 20)
        // Kept all the same, for when it follows the theme again.
        #expect(Self.ownReading(of: pack.id)?.fontSize == 24)

        settings.appearanceThemeID = defaultID
        #expect(settings.readerFontSize == 20)

        settings.appearanceThemeID = pack.id
        settings.setReadingSettingsScope(.theme, for: .fontSize)
        #expect(settings.readerFontSize == 24)
    }

    /// 排版方向 is a reading setting like the others (2026-10-06): a theme's own direction is
    /// worn with it, and an edit stays with the theme worn when it was made.
    @Test func aThemesWritingModeIsWornAndEditedWithIt() throws {
        let settings = GlobalSettings.shared
        let fixture = Fixture(settings)
        defer { fixture.restore() }
        fixture.reset()

        var reading = AppearanceThemeReadingSettings()
        reading.writingMode = ReaderWritingMode.verticalRTL.rawValue
        let vertical = Self.theme("Vertical", reading: reading)
        let plain = Self.theme("Plain", reading: nil)
        settings.customAppearanceThemes.append(contentsOf: [vertical, plain])

        settings.appearanceThemeID = vertical.id
        #expect(settings.readerWritingMode == .verticalRTL)
        settings.appearanceThemeID = defaultID
        #expect(settings.readerWritingMode == .horizontal)

        settings.appearanceThemeID = plain.id
        settings.readerWritingMode = .verticalRTL
        #expect(Self.ownReading(of: plain.id)?.writingMode == ReaderWritingMode.verticalRTL.rawValue)
        #expect(settings.globalReadingSettings.writingMode == ReaderWritingMode.horizontal.rawValue)
        settings.appearanceThemeID = defaultID
        #expect(settings.readerWritingMode == .horizontal)
        settings.appearanceThemeID = plain.id
        #expect(settings.readerWritingMode == .verticalRTL)
    }

    /// A shared setup saved before 排版方向 joined it has no direction; it is completed
    /// from what is on screen, or a theme with none of its own would keep the last one's.
    @Test func aSharedSetupFromBeforeWritingModeIsCompleted() throws {
        let settings = GlobalSettings.shared
        let fixture = Fixture(settings)
        defer { fixture.restore() }
        fixture.reset()

        settings.readerWritingMode = .verticalRTL
        UserDefaults.standard.set(Data(#"{"fontSize": 18}"#.utf8), forKey: GlobalSettings.globalReadingKey)
        #expect(settings.globalReadingSettings.writingMode == ReaderWritingMode.verticalRTL.rawValue)
        let stored = try #require(UserDefaults.standard.data(forKey: GlobalSettings.globalReadingKey))
        let decoded = try JSONDecoder().decode(AppearanceThemeReadingSettings.self, from: stored)
        #expect(decoded.writingMode == ReaderWritingMode.verticalRTL.rawValue)
        #expect(decoded.fontSize == 18)
    }

    // MARK: - Editing

    @Test func anEditGoesWhereItsSettingComesFrom() throws {
        let settings = GlobalSettings.shared
        let fixture = Fixture(settings)
        defer { fixture.restore() }
        fixture.reset()

        let plain = Self.theme("Plain", reading: nil)
        settings.customAppearanceThemes.append(plain)
        settings.setReadingSettingsScope(.global, for: .letterSpacing)
        settings.appearanceThemeID = plain.id

        settings.readerFontSize = 21
        settings.letterSpacing = 1.5
        let own = try #require(Self.ownReading(of: plain.id))
        #expect(own.fontSize == 21)
        // Per field: the theme says nothing about what it was not given.
        #expect(own.letterSpacing == nil)
        #expect(settings.globalReadingSettings.fontSize == 18)
        #expect(settings.globalReadingSettings.letterSpacing == 1.5)

        settings.appearanceThemeID = defaultID
        #expect(settings.readerFontSize == 18)
        #expect(settings.letterSpacing == 1.5)
        settings.appearanceThemeID = plain.id
        #expect(settings.readerFontSize == 21)
    }

    /// Built-in themes have no extras, but following the theme has to mean the same
    /// thing on them: 默認 with 護眼綠 and another preset with 白色.
    @Test func aBuiltInThemeKeepsItsOwnValuesToo() throws {
        let settings = GlobalSettings.shared
        let fixture = Fixture(settings)
        defer { fixture.restore() }
        fixture.reset()
        ReaderConfig.shared.theme = .white
        fixture.forgetEdits()

        ReaderConfig.shared.theme = .green
        #expect(settings.themeReadingSettings(themeID: defaultID)?.readerTheme == ReaderTheme.green.rawValue)
        #expect(settings.globalReadingSettings.readerTheme == ReaderTheme.white.rawValue)

        let other = try #require(AppearanceThemePreset.freeSolidPresets.first { $0.id != defaultID })
        settings.appearanceThemeID = other.id
        #expect(ReaderTheme.loadPersisted() == .white)
        #expect(ReaderConfig.shared.theme == .white)

        settings.appearanceThemeID = defaultID
        #expect(ReaderTheme.loadPersisted() == .green)
        #expect(ReaderConfig.shared.theme == .green)
    }

    @Test func resettingTheScopeWearsEveryThemesOwnValuesAgain() throws {
        let settings = GlobalSettings.shared
        let fixture = Fixture(settings)
        defer { fixture.restore() }
        fixture.reset()

        var reading = AppearanceThemeReadingSettings()
        reading.fontSize = 24
        let pack = Self.theme("Pack", reading: reading)
        settings.customAppearanceThemes.append(pack)
        settings.appearanceThemeID = pack.id
        settings.setReadingSettingsScope(.global, for: .fontSize)
        settings.setReadingSettingsScope(.global, for: .lineSpacing)
        #expect(!settings.readingSettingsScope.themeItems.contains(.fontSize))
        #expect(settings.readerFontSize == 18)

        settings.readingSettingsScope = .default
        #expect(settings.readingSettingsScope.themeItems == Set(ReadingSettingsScopeItem.allCases))
        #expect(settings.readerFontSize == 24)
    }

    @Test func aRowSetToTheDefaultMovesWithTheDefault() {
        var scope = ReadingSettingsScopeConfiguration.default
        #expect(scope.defaultScope == .theme)
        scope.setScope(.global, for: .font)
        scope.setScope(.theme, for: .fontSize)
        #expect(!scope.themeItems.contains(.font))
        #expect(scope.themeItems.contains(.fontSize))

        scope.defaultScope = .global
        // 字體 was set on its own; 字體大小 only ever said what the default said.
        #expect(scope.scope(of: .font) == .global)
        #expect(scope.scope(of: .fontSize) == .global)
        #expect(scope.scope(of: .background) == .global)
    }

    /// A scope saved on the day the default was 全域 held nothing the user chose — its
    /// overrides could only be rows an import set to 跟隨主題 — so it gives way to the new
    /// default. One whose default the user had made 跟隨主題 is kept, shared rows and all.
    @Test func theOneDayGlobalDefaultGivesWayToFollowingTheTheme() throws {
        let settings = GlobalSettings.shared
        let fixture = Fixture(settings)
        defer { fixture.restore() }
        fixture.reset()
        let legacyKey = "yd_reading_settings_scope"

        var importMade = ReadingSettingsScopeConfiguration.default
        importMade.defaultScope = .global
        importMade.setScope(.theme, for: .fontSize)
        ReadingSettingsStoresSnapshot.clear()
        UserDefaults.standard.set(try JSONEncoder().encode(importMade), forKey: legacyKey)
        #expect(settings.readingSettingsScope == .default)
        #expect(UserDefaults.standard.data(forKey: legacyKey) == nil)

        var chosen = ReadingSettingsScopeConfiguration.default
        chosen.setScope(.global, for: .pageTurn)
        ReadingSettingsStoresSnapshot.clear()
        UserDefaults.standard.set(try JSONEncoder().encode(chosen), forKey: legacyKey)
        #expect(settings.readingSettingsScope == chosen)
        #expect(settings.readingSettingsScope.scope(of: .pageTurn) == .global)
    }

    /// A theme that only keeps reading values speaks for no appearance setting, so
    /// selecting it must not write its absent card background over the user's.
    @Test func readingValuesAloneSpeakForNoAppearanceSetting() {
        var extras = AppearanceThemeExtras()
        var reading = AppearanceThemeReadingSettings()
        reading.fontSize = 20
        extras.reading = reading
        #expect(extras.isEmpty)
    }

    // MARK: - The shared setup

    /// Before 排版生效範圍 the user's own reading setup lived in the appearance baseline
    /// while a custom theme was selected; that is what the shared setup starts from.
    @Test func theSharedSetupStartsFromTheOldBaseline() throws {
        let settings = GlobalSettings.shared
        let fixture = Fixture(settings)
        defer { fixture.restore() }
        fixture.reset()

        var own = settings.currentReadingSettingsSnapshot()
        own.fontSize = 19
        var baseline = settings.currentAppearanceExtrasSnapshot()
        baseline.reading = own
        settings.appearanceExtrasBaseline = baseline
        ReadingSettingsStoresSnapshot.clear()

        #expect(settings.globalReadingSettings.fontSize == 19)
    }

    // MARK: - Imports

    /// Nothing is asked: the pack's setup rides its theme, is worn at once, and leaves
    /// with it — 「老子原本外觀主題所有設定都隨著閱讀主題切換」.
    @Test func aPackIsWornWithItsThemeWithoutAQuestion() async throws {
        let settings = GlobalSettings.shared
        let fixture = Fixture(settings)
        defer { fixture.restore() }
        fixture.reset()

        let pack = Self.pack(textSize: 26)
        #expect(SharedCustomizationImportService.Plan.qiTheme(pack).prompt == nil)

        let outcome = try await QiThemeImportService.apply(pack)
        let theme = try #require(outcome.theme)
        fixture.imported.append(theme.id)
        #expect(theme.extras?.reading?.fontSize == 26)
        #expect(settings.readingSettingsScope == .default)
        #expect(settings.readerFontSize == 26)
        #expect(settings.globalReadingSettings.fontSize == 18)

        let overview = CustomizationImportOverview(qiTheme: outcome)
        #expect(overview.readingPlacement == .followsTheme(name: theme.name))
        #expect(overview.readingItems.map(\.id).contains(ReadingSetupPart.layout.titleKey))

        settings.appearanceThemeID = defaultID
        #expect(settings.readerFontSize == 18)
        settings.appearanceThemeID = theme.id
        #expect(settings.readerFontSize == 26)
    }

    @Test func aPackLeavesASettingTheUserSharesAlone() async throws {
        let settings = GlobalSettings.shared
        let fixture = Fixture(settings)
        defer { fixture.restore() }
        fixture.reset()
        settings.setReadingSettingsScope(.global, for: .fontSize)

        let outcome = try await QiThemeImportService.apply(Self.pack(textSize: 26))
        let theme = try #require(outcome.theme)
        fixture.imported.append(theme.id)
        #expect(settings.readingSettingsScope.scope(of: .fontSize) == .global)
        #expect(settings.readerFontSize == 18)
        #expect(theme.extras?.reading?.fontSize == 26)
    }

    /// A reading-settings file lands like an edit: the settings that follow the theme on
    /// the worn one, the rest in 全域 — and the sheet says so.
    @Test func aReadingSettingsFileLandsSettingBySetting() throws {
        let settings = GlobalSettings.shared
        let fixture = Fixture(settings)
        defer { fixture.restore() }
        fixture.reset()
        settings.setReadingSettingsScope(.global, for: .lineSpacing)

        var file = AppearanceThemeReadingSettings()
        file.fontSize = 30
        file.lineHeightMultiple = 2.0
        #expect(CustomizationImportOverview.ReadingPlacement.current(for: file)
            == .split(themeName: settings.readingSettingsThemeName))

        try settings.writeReadingSettings(file, origin: .userImport)
        #expect(settings.themeReadingSettings(themeID: defaultID)?.fontSize == 30)
        #expect(settings.globalReadingSettings.fontSize == 18)
        #expect(settings.globalReadingSettings.lineHeightMultiple == 2.0)
    }

    // MARK: - Files

    @Test func anExportedThemeLeavesItsReadingValuesBehind() {
        var extras = AppearanceThemeExtras()
        extras.tabIconSize = 30
        var reading = AppearanceThemeReadingSettings()
        reading.fontSize = 22
        extras.reading = reading
        let file = AppearanceThemeExportFile(customTheme: Self.theme("Export", extras: extras))
        #expect(file.extras?.reading == nil)
        #expect(file.extras?.tabIconSize == 30)
    }

    @Test func aFieldThisBuildCannotReadCostsOnlyThatField() throws {
        let json = #"{"fontSize": 20, "barLayout": {"version": "not a number"}, "scrollMode": true, "writingMode": "verticalRTL"}"#
        let decoded = try JSONDecoder().decode(AppearanceThemeReadingSettings.self, from: Data(json.utf8))
        #expect(decoded.fontSize == 20)
        #expect(decoded.scrollMode == true)
        #expect(decoded.writingMode == "verticalRTL")
        #expect(decoded.barLayout == nil)
    }

    // MARK: - Helpers

    private static func ownReading(of themeID: String) -> AppearanceThemeReadingSettings? {
        GlobalSettings.shared.themeReadingSettings(themeID: themeID)
    }

    private static func theme(_ name: String, reading: AppearanceThemeReadingSettings?) -> AppearanceCustomTheme {
        var extras = AppearanceThemeExtras()
        extras.reading = reading
        return theme(name, extras: reading == nil ? nil : extras)
    }

    private static func theme(_ name: String, extras: AppearanceThemeExtras?) -> AppearanceCustomTheme {
        AppearanceCustomTheme(name: name, backgroundHex: 0xFFFFFF, textHex: 0,
                              barHex: 0xFFFFFF, accentHex: 0x123456, dialogueHex: 0, extras: extras)
    }

    /// A pack with one reading value, and a theme to carry it.
    private static func pack(textSize: Int) -> QiThemeImport {
        let config = try? JSONSerialization.data(withJSONObject: ["textSize": textSize])
        return QiThemeImport(
            name: "Reading Fixture",
            themeFile: AppearanceThemeExportFile(customTheme: theme("Reading Fixture", extras: nil)),
            layoutConfig: config
        )
    }

    /// Saves and restores field by field rather than through the machinery under test.
    @MainActor
    private final class Fixture {
        private let settings: GlobalSettings
        private let lightID: String
        private let darkID: String
        private let themes: [AppearanceCustomTheme]
        private let baseline: AppearanceThemeExtras?
        private let stores = ReadingSettingsStoresSnapshot()
        private let readerTheme: ReaderTheme
        /// Everything else a test may have written into the live settings.
        private let reading: AppearanceThemeReadingSettings
        var imported: [String] = []

        init(_ settings: GlobalSettings) {
            self.settings = settings
            lightID = settings.appearanceThemeID
            darkID = settings.appearanceDarkThemeID
            themes = settings.customAppearanceThemes
            baseline = settings.appearanceExtrasBaseline
            readerTheme = ReaderTheme.loadPersisted()
            reading = settings.currentReadingSettingsSnapshot()
        }

        /// 默認, the default scope, and a known shared setup, so each test reads the
        /// mechanism rather than whatever the simulator was left in.
        func reset() {
            settings.appearanceThemeID = GlobalSettings.defaultAppearanceThemeID
            settings.appearanceDarkThemeID = GlobalSettings.defaultAppearanceThemeID
            settings.appearanceExtrasBaseline = nil
            settings.customAppearanceThemes = themes
            ReadingSettingsStoresSnapshot.clear()
            settings.readerFontSize = 18
            settings.lineHeightMultiple = 1.6
            settings.letterSpacing = 0
            settings.scrollMode = false
            settings.readerWritingMode = .horizontal
            settings.readerFollowSystemTheme = false
            settings.appearanceBindReaderTheme = false
            ReaderConfig.shared.syncFromGlobalSettings()
            forgetEdits()
        }

        /// Every setting follows the theme by default, so the writes above were recorded
        /// on 默認 as edits. Empties the stores again and captures 全域 from what is on
        /// screen, so each test starts with no theme holding values of its own.
        func forgetEdits() {
            ReadingSettingsStoresSnapshot.clear()
            _ = settings.globalReadingSettings
        }

        func restore() {
            settings.appearanceThemeID = GlobalSettings.defaultAppearanceThemeID
            settings.appearanceDarkThemeID = GlobalSettings.defaultAppearanceThemeID
            for id in imported {
                settings.deleteCustomAppearanceTheme(id: id)
            }
            settings.appearanceExtrasBaseline = nil
            settings.customAppearanceThemes = themes
            readerTheme.persist()
            try? settings.writeReadingSettings(reading, origin: .theme)
            // After the live values: writing those records them as edits.
            stores.restore()
            settings.appearanceExtrasBaseline = baseline
            settings.appearanceThemeID = lightID
            settings.appearanceDarkThemeID = darkID
            ReaderConfig.shared.syncFromGlobalSettings()
        }
    }
}
