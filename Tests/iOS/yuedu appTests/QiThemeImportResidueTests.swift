import Foundation
import Testing
@testable import yuedu_app

/// Importing a QiReader pack and then choosing 默認 again must leave the app exactly as it
/// was before the import. Reported 2026-09-28 with 山风 - 春水漾: after the first import,
/// switching back to 默認 kept the pack's page background.
@Suite("QiReader pack leaves nothing behind", .serialized)
@MainActor
struct QiThemeImportResidueTests {
    nonisolated private static let chunshuiyangPath = "/Users/zhangruilin/Downloads/山风 - 春水漾.qitheme"
    nonisolated private static let qimeidiPath = "/Users/zhangruilin/Downloads/山风-凄美地.qitheme"

    private static let global = AppearancePageBackgroundScope.global.rawValue

    /// The pack's page background belongs to its theme. It used to be written into the
    /// live settings first, as if it were the user's own look, so the baseline captured
    /// when the theme got selected already held it.
    @Test func leavingAnImportedPackGivesTheUsersPageBackgroundBack() async throws {
        let settings = GlobalSettings.shared
        let fixture = Fixture(settings)
        defer { fixture.restore() }

        let own = AppearancePageBackgroundConfig(
            lightPrimaryHex: 0x111111, lightSecondaryHex: nil,
            darkPrimaryHex: nil, darkSecondaryHex: nil
        )
        settings.appearancePageBackgrounds = [Self.global: own]

        var extras = AppearanceThemeExtras()
        extras.pageBackgrounds = [Self.global: AppearancePageBackgroundConfig(
            lightPrimaryHex: 0xABCDEF, lightSecondaryHex: nil,
            darkPrimaryHex: nil, darkSecondaryHex: nil
        )]
        let file = AppearanceThemeExportFile(customTheme: AppearanceCustomTheme(
            name: "Residue Fixture", backgroundHex: 0xFFFFFF, textHex: 0, barHex: 0xFFFFFF,
            accentHex: 0x123456, dialogueHex: 0, extras: extras
        ))
        var pack = QiThemeImport(name: "Residue Fixture", themeFile: file)
        // Where the importer puts a pack's backgrounds: on the theme file and here.
        pack.pageBackgrounds = file.pageBackgrounds ?? [:]

        let outcome = try await QiThemeImportService.apply(pack)
        let theme = try #require(outcome.theme)
        fixture.imported.append(theme.id)
        #expect(settings.appearancePageBackgrounds[Self.global]?.lightPrimaryHex == 0xABCDEF)

        settings.appearanceThemeID = GlobalSettings.defaultAppearanceThemeID
        #expect(settings.appearancePageBackgrounds == [Self.global: own])
    }

    /// The report itself, with the pack it was made with: import, choose 默認, and nothing
    /// of the pack's look or reading setup may still be on screen.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: chunshuiyangPath), "Needs ~/Downloads/山风 - 春水漾.qitheme"))
    func chunshuiyangLeavesNothingBehindOnceDefaultIsChosen() async throws {
        let url = URL(fileURLWithPath: Self.chunshuiyangPath)
        let settings = GlobalSettings.shared
        let fixture = Fixture(settings)
        defer { fixture.restore() }

        let appearanceBefore = settings.currentAppearanceExtrasSnapshot()
        let readingBefore = settings.currentReadingSettingsSnapshot()

        let pack = try await QiThemeImportService.load(Data(contentsOf: url))
        let outcome = try await QiThemeImportService.apply(pack)
        let theme = try #require(outcome.theme)
        fixture.imported.append(theme.id)
        // Worn while selected…
        #expect(settings.appearancePageBackgrounds != appearanceBefore.pageBackgrounds)

        // …and gone once 默認 is chosen again.
        settings.appearanceThemeID = GlobalSettings.defaultAppearanceThemeID
        let appearanceAfter = settings.currentAppearanceExtrasSnapshot()
        #expect(appearanceAfter.pageBackgrounds == appearanceBefore.pageBackgrounds)
        #expect(appearanceAfter.tabIcons == appearanceBefore.tabIcons)
        #expect(appearanceAfter.hidesTabLabels == appearanceBefore.hidesTabLabels)
        #expect(appearanceAfter.launchImageEnabled == appearanceBefore.launchImageEnabled)
        #expect(appearanceAfter.launchImageLightFileName == appearanceBefore.launchImageLightFileName)
        #expect(appearanceAfter.defaultCoverLightFileNames == appearanceBefore.defaultCoverLightFileNames)
        #expect(appearanceAfter.forceDefaultCover == appearanceBefore.forceDefaultCover)
        #expect(appearanceAfter.globalFontPostScript == appearanceBefore.globalFontPostScript)
        #expect(appearanceAfter.frostedGlass == appearanceBefore.frostedGlass)
        #expect(appearanceAfter.glassTransparency == appearanceBefore.glassTransparency)
        #expect(appearanceAfter.glowIntensity == appearanceBefore.glowIntensity)
        #expect(appearanceAfter.bookshelfGridColumnCount == appearanceBefore.bookshelfGridColumnCount)
        #expect(appearanceAfter.bookshelfCoverCornerRadius == appearanceBefore.bookshelfCoverCornerRadius)
        #expect(appearanceAfter.readerInterface == appearanceBefore.readerInterface)
        #expect(appearanceAfter.cardBackground == appearanceBefore.cardBackground)
        #expect(appearanceAfter.readerChromeIcons == appearanceBefore.readerChromeIcons)
        #expect(appearanceAfter == appearanceBefore)
        #expect(settings.currentReadingSettingsSnapshot() == readingBefore)
    }

    /// The second report, step for step: 默認 → import 春水漾 (隨主題切換) → import 凄美地
    /// (隨主題切換) → 默認. The reading setup has to be the one from before either import,
    /// not the last pack's.
    @Test(
        .enabled(if: FileManager.default.fileExists(atPath: chunshuiyangPath), "Needs ~/Downloads/山风 - 春水漾.qitheme"),
        .enabled(if: FileManager.default.fileExists(atPath: qimeidiPath), "Needs ~/Downloads/山风-凄美地.qitheme")
    )
    func twoPacksImportedToFollowTheirThemesLeaveNothingOnDefault() async throws {
        let first = URL(fileURLWithPath: Self.chunshuiyangPath)
        let second = URL(fileURLWithPath: Self.qimeidiPath)
        let settings = GlobalSettings.shared
        let fixture = Fixture(settings)
        defer { fixture.restore() }
        _ = ReaderConfig.shared  // as in the app, where a book has been opened

        let readingBefore = settings.currentReadingSettingsSnapshot()
        let appearanceBefore = settings.currentAppearanceExtrasSnapshot()

        for url in [first, second] {
            // The Open In route: the same service the alert's answer is handed to.
            let document = SharedCustomizationDocument(data: try Data(contentsOf: url), kind: .qiTheme)
            let plan = try await SharedCustomizationImportService.load(document)
            // A theme pack asks nothing: its reading setup is its theme's own.
            #expect(plan.prompt == nil)
            _ = try await SharedCustomizationImportService.apply(plan)
            let imported = try #require(settings.customAppearanceThemes.first { $0.id == settings.appearanceThemeID })
            fixture.imported.append(imported.id)
            #expect(imported.extras?.reading != nil)
        }

        settings.appearanceThemeID = GlobalSettings.defaultAppearanceThemeID
        let readingAfter = settings.currentReadingSettingsSnapshot()
        #expect(readingAfter.fontPostScript == readingBefore.fontPostScript)
        #expect(readingAfter.fontSize == readingBefore.fontSize)
        #expect(readingAfter.lineHeightMultiple == readingBefore.lineHeightMultiple)
        #expect(readingAfter.pageMarginH == readingBefore.pageMarginH)
        #expect(readingAfter.scrollMode == readingBefore.scrollMode)
        #expect(readingAfter.pageTurnStyle == readingBefore.pageTurnStyle)
        #expect(readingAfter.barLayout == readingBefore.barLayout)
        #expect(readingAfter.chapterTitleStyle == readingBefore.chapterTitleStyle)
        #expect(readingAfter.readerBackgroundID == readingBefore.readerBackgroundID)
        #expect(readingAfter.bindsAppearanceReaderTheme == readingBefore.bindsAppearanceReaderTheme)
        #expect(readingAfter.boundDarkReaderTheme == readingBefore.boundDarkReaderTheme)
        #expect(readingAfter.commentBubble == readingBefore.commentBubble)
        #expect(readingAfter == readingBefore)
        #expect(ReaderConfig.shared.fontSize == CGFloat(readingBefore.fontSize ?? 0))
        #expect(settings.currentAppearanceExtrasSnapshot() == appearanceBefore)
    }

    /// Back to 默認 on entry, and back to where the simulator was on exit — field by field
    /// for what these tests change, and the imported themes deleted so their artwork is
    /// reclaimed.
    @MainActor
    private final class Fixture {
        private let settings: GlobalSettings
        private let lightID: String
        private let darkID: String
        private let themes: [AppearanceCustomTheme]
        private let baseline: AppearanceThemeExtras?
        private let backgrounds: [String: AppearancePageBackgroundConfig]
        private let reading: AppearanceThemeReadingSettings
        private let savedReaderBackgrounds: [ReaderCustomBackground]
        private let stores = ReadingSettingsStoresSnapshot()
        var imported: [String] = []

        init(_ settings: GlobalSettings) {
            self.settings = settings
            lightID = settings.appearanceThemeID
            darkID = settings.appearanceDarkThemeID
            themes = settings.customAppearanceThemes
            baseline = settings.appearanceExtrasBaseline
            settings.appearanceThemeID = GlobalSettings.defaultAppearanceThemeID
            settings.appearanceDarkThemeID = GlobalSettings.defaultAppearanceThemeID
            settings.appearanceExtrasBaseline = nil
            backgrounds = settings.appearancePageBackgrounds
            reading = settings.currentReadingSettingsSnapshot()
            savedReaderBackgrounds = settings.readerCustomBackgrounds
        }

        func restore() {
            settings.appearanceThemeID = GlobalSettings.defaultAppearanceThemeID
            settings.appearanceDarkThemeID = GlobalSettings.defaultAppearanceThemeID
            for id in imported {
                settings.deleteCustomAppearanceTheme(id: id)
            }
            // A pack's reading picture became a saved background; the test's go, pictures
            // and all, and the list is as it was.
            for background in settings.readerCustomBackgrounds
            where !savedReaderBackgrounds.contains(where: { $0.id == background.id }) {
                settings.deleteReaderCustomBackground(id: background.id)
            }
            settings.readerCustomBackgrounds = savedReaderBackgrounds
            settings.appearanceExtrasBaseline = nil
            settings.customAppearanceThemes = themes
            settings.appearancePageBackgrounds = backgrounds
            try? settings.writeReadingSettings(reading, origin: .theme)
            // After the live values: writing those records them as edits.
            stores.restore()
            settings.appearanceExtrasBaseline = baseline
            settings.appearanceThemeID = lightID
            settings.appearanceDarkThemeID = darkID
        }
    }
}
