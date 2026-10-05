import Foundation
import SwiftUI
import Testing
import UIKit
@testable import yuedu_app

/// Saved reading backgrounds and 綁定閱讀主題 (2026-09-29): backgrounds of the user's own,
/// by name, choosable for dark mode as well as light, synced, and a theme pack's picture
/// kept in dark mode instead of 黑色. Which of the two modes the reader is in is its own
/// dark mode, not the device's appearance and not the tone of a background (2026-09-30).
@Suite("閱讀背景", .serialized)
@MainActor
struct ReaderBackgroundBindingTests {
    // MARK: - 綁定閱讀主題

    /// The report: 綁定閱讀主題 on, 淺色閱讀主題 left on 跟隨外觀主題, 深色閱讀主題 set to 棕色,
    /// a theme pack's reading picture worn — and dark mode did not turn 棕色. The picture
    /// came first and the binding was never read. Light keeps the pack's picture: that is
    /// what following the appearance theme means for a pack.
    @Test func theDarkPickIsWornWhileAPacksPictureIsToo() {
        let settings = GlobalSettings.shared
        let fixture = Fixture(settings)
        defer { fixture.restore() }

        let pack = settings.saveReaderCustomBackground(Self.picture("Pack"))
        _ = settings.wearReaderCustomBackground(pack, over: .white, deviceIsDark: false)
        settings.appearanceBindReaderTheme = true
        settings.setBoundReaderTheme(.followAppearanceTheme, for: .light)
        settings.setBoundReaderTheme(.reading(.sepia), for: .dark)

        let dark = settings.readerBackgroundResolution(mode: .dark, wornTheme: .white)
        #expect(dark.theme == .sepia)
        #expect(dark.customBackground == nil)
        #expect(!dark.paintsWithAppearanceTheme)

        let light = settings.readerBackgroundResolution(mode: .light, wornTheme: .white)
        #expect(light.customBackground?.id == pack.id)
        #expect(!light.paintsWithAppearanceTheme)

        // A theme with no reading picture of its own is painted with its palette.
        settings.readerCustomBackgroundID = nil
        #expect(settings.readerBackgroundResolution(mode: .light, wornTheme: .white).paintsWithAppearanceTheme)
    }

    /// What the user asked for: dark mode wears a background of their own, not 黑色.
    @Test func aSavedBackgroundCanBeEitherPick() {
        let settings = GlobalSettings.shared
        let fixture = Fixture(settings)
        defer { fixture.restore() }

        let night = settings.saveReaderCustomBackground(Self.color("深藍", 0x10203A))
        let day = settings.saveReaderCustomBackground(Self.color("米色", 0xF3EAD8))
        #expect(night.isDark)
        #expect(!day.isDark)
        settings.appearanceBindReaderTheme = true
        settings.setBoundReaderTheme(.custom(day.id), for: .light)
        settings.setBoundReaderTheme(.custom(night.id), for: .dark)

        let dark = settings.readerBackgroundResolution(mode: .dark, wornTheme: .white)
        #expect(dark.theme == .night)
        #expect(dark.customBackground?.id == night.id)

        let light = settings.readerBackgroundResolution(mode: .light, wornTheme: .night)
        #expect(light.theme != .night)
        #expect(light.customBackground?.id == day.id)

        // Both offered by 淺色閱讀主題 / 深色閱讀主題, by name.
        #expect(settings.boundReaderThemeOptions.suffix(2) == [.custom(night.id), .custom(day.id)])
        #expect(settings.title(for: .custom(night.id)) == "深藍")
    }

    @Test func aBoundPickSurvivesItsStorageRoundTrip() {
        let id = UUID()
        #expect(ReaderBoundTheme(storageValue: ReaderBoundTheme.custom(id).storageValue) == .custom(id))
        #expect(ReaderBoundTheme(storageValue: ReaderTheme.sepia.rawValue) == .reading(.sepia))
        #expect(ReaderBoundTheme(storageValue: "custom:not-a-uuid") == .followAppearanceTheme)
    }

    // MARK: - Worn from the reader

    /// A background made in the reader is the light mode's, dark or not; dark mode is 黑色
    /// and gets one of its own only through 深色閱讀主題. A dark one used to put the reader
    /// in dark mode and stay out of light mode (reported 2026-09-30).
    @Test func aSavedBackgroundIsTheLightModesWhateverItsTone() {
        let settings = GlobalSettings.shared
        let fixture = Fixture(settings)
        defer { fixture.restore() }

        // Made while the reader is in dark mode.
        settings.readerDarkMode = true
        let dark = settings.saveReaderCustomBackground(Self.color("深", 0x1B1B28))
        #expect(dark.isDark)
        let worn = settings.wearReaderCustomBackground(dark, over: .night, deviceIsDark: false)
        #expect(!settings.readerDarkMode)
        #expect(worn == .night, "a dark one sits on 黑色, for the chrome")
        let lightMode = settings.readerBackgroundResolution(mode: .light, wornTheme: worn)
        #expect(lightMode.customBackground?.id == dark.id)
        #expect(lightMode.theme == .night)
        let darkMode = settings.readerBackgroundResolution(mode: .dark, wornTheme: worn)
        #expect(darkMode.customBackground == nil)
        #expect(darkMode.theme == .night)

        let light = settings.saveReaderCustomBackground(Self.color("淺", 0xEFE6D2))
        #expect(settings.wearReaderCustomBackground(light, over: .night, deviceIsDark: false) != .night)
        #expect(settings.readerBackgroundResolution(mode: .light, wornTheme: .white).customBackground?.id == light.id)
        #expect(settings.readerBackgroundResolution(mode: .light, wornTheme: .white).theme == .white)
        #expect(settings.readerBackgroundResolution(mode: .dark, wornTheme: .white).customBackground == nil)
        #expect(settings.readerBackgroundResolution(mode: .dark, wornTheme: .white).theme == .night)

        // The palette still paints only the built-in of its own tone, which is why a
        // dark background sits on 黑色.
        AppearanceThemePreset.activeReaderTheme = settings.readerBackgroundPreset(for: dark)
        #expect(ReaderTheme.night.uiBackgroundColor.rgbHex == 0x1B1B28)
        #expect(ReaderTheme.white.uiBackgroundColor.rgbHex == 0xF4F5F7)
        AppearanceThemePreset.activeReaderTheme = settings.readerBackgroundPreset(for: light)
        #expect(ReaderTheme.white.uiBackgroundColor.rgbHex == 0xEFE6D2)
        #expect(ReaderTheme.night.uiBackgroundColor.rgbHex == 0x000000)
    }

    // MARK: - The reader's mode

    /// 綁定閱讀主題's picks are worn by the reader's own dark mode — its 深色／白天 button —
    /// not by the device's appearance, against which the button could do nothing
    /// (reported 2026-09-30).
    @Test func theReadersModeWearsTheBoundPickNotTheDevices() {
        let settings = GlobalSettings.shared
        let fixture = Fixture(settings)
        defer { fixture.restore() }

        settings.appearanceBindReaderTheme = true
        settings.setBoundReaderTheme(.reading(.green), for: .light)
        settings.setBoundReaderTheme(.reading(.sepia), for: .dark)
        settings.readerDarkMode = false

        // 深色, on a device in light appearance.
        settings.setReaderDarkMode(true, deviceIsDark: false)
        #expect(settings.readerMode == .dark)
        #expect(settings.readerBackgroundResolution(mode: settings.readerMode, wornTheme: .green).theme == .sepia)
        // The device turning dark and light again moves nothing: nothing follows it.
        settings.alignReaderDarkMode(deviceIsDark: true, in: .active)
        settings.alignReaderDarkMode(deviceIsDark: false, in: .active)
        #expect(settings.readerDarkMode)
        // 白天.
        settings.setReaderDarkMode(false, deviceIsDark: false)
        #expect(settings.readerBackgroundResolution(mode: settings.readerMode, wornTheme: .sepia).theme == .green)
    }

    /// 跟隨裝置深淺色 shows under 綁定閱讀主題, off to start with. On, the reader takes the
    /// device's appearance; set against it by hand the switch goes back off, since the
    /// two cannot both hold — and stays where the user left it after that.
    @Test func followingTheDeviceEndsWhenTheModeIsSetAgainstIt() {
        let settings = GlobalSettings.shared
        let fixture = Fixture(settings)
        defer { fixture.restore() }

        settings.appearanceBindReaderTheme = false
        settings.readerFollowSystemTheme = true
        settings.appearanceBindReaderTheme = true
        #expect(!settings.readerFollowSystemTheme, "off to start with")

        settings.readerDarkMode = true
        settings.setReaderFollowsDevice(true, deviceIsDark: false)
        #expect(settings.readerFollowSystemTheme)
        #expect(!settings.readerDarkMode)
        settings.alignReaderDarkMode(deviceIsDark: true, in: .active)
        #expect(settings.readerDarkMode)

        // By hand, the way the device already is: nothing to give up.
        settings.setReaderDarkMode(true, deviceIsDark: true)
        #expect(settings.readerFollowSystemTheme)
        // Against it.
        settings.setReaderDarkMode(false, deviceIsDark: true)
        #expect(!settings.readerFollowSystemTheme)
        #expect(!settings.readerDarkMode)
        settings.alignReaderDarkMode(deviceIsDark: true, in: .active)
        #expect(!settings.readerDarkMode)
        // Back to the device's by hand: the switch is the user's to turn on again.
        settings.setReaderDarkMode(true, deviceIsDark: true)
        #expect(!settings.readerFollowSystemTheme)
    }

    /// Without 綁定閱讀主題 no switch shows: the reader follows the device by itself, and a
    /// mode set against the device holds until the device comes round to it.
    @Test func withoutTheBindingTheReaderFollowsTheDeviceByItself() {
        let settings = GlobalSettings.shared
        let fixture = Fixture(settings)
        defer { fixture.restore() }

        settings.appearanceBindReaderTheme = false
        settings.readerCustomBackgroundID = nil
        settings.readerFollowSystemTheme = true
        settings.readerDarkMode = false

        settings.alignReaderDarkMode(deviceIsDark: true, in: .active)
        #expect(settings.readerDarkMode)
        #expect(settings.readerBackgroundResolution(mode: settings.readerMode, wornTheme: .white).theme == .night)

        // 白天 by hand while the device is dark: held.
        settings.setReaderDarkMode(false, deviceIsDark: true)
        #expect(!settings.readerFollowSystemTheme)
        settings.alignReaderDarkMode(deviceIsDark: true, in: .active)
        #expect(!settings.readerDarkMode)
        // The device comes round to it, and is followed from there.
        settings.alignReaderDarkMode(deviceIsDark: false, in: .active)
        #expect(settings.readerFollowSystemTheme)
        settings.alignReaderDarkMode(deviceIsDark: true, in: .active)
        #expect(settings.readerDarkMode)

        // Set against the device and back by hand, it follows again at once.
        settings.setReaderDarkMode(false, deviceIsDark: true)
        settings.setReaderDarkMode(true, deviceIsDark: true)
        #expect(settings.readerFollowSystemTheme)
    }

    /// The report (2026-10-04): with 主題切換 › 跟隨系統 on, a reader set to 白天 on a dark
    /// device came back in 深色 after every trip out of the app. In the background UIKit
    /// draws the app-switcher snapshots in both appearances — light, then dark again — and
    /// SwiftUI hands each to the reader (iOS 27 simulator log, 2026-10-05). Neither is the
    /// device changing its appearance.
    @Test func leavingTheAppKeepsAModeSetAgainstTheDevice() {
        let settings = GlobalSettings.shared
        let fixture = Fixture(settings)
        defer { fixture.restore() }

        settings.appearanceBindReaderTheme = false
        settings.readerCustomBackgroundID = nil
        settings.readerFollowSystemTheme = true
        settings.readerDarkMode = false
        settings.alignReaderDarkMode(deviceIsDark: true, in: .active)
        #expect(settings.readerDarkMode)
        // 白天 by hand on the dark device.
        settings.setReaderDarkMode(false, deviceIsDark: true)
        #expect(!settings.readerFollowSystemTheme)

        // Out of the app: the light snapshot, then the dark one.
        settings.alignReaderDarkMode(deviceIsDark: false, in: .background)
        settings.alignReaderDarkMode(deviceIsDark: true, in: .background)
        // Back, to the same dark device.
        settings.alignReaderDarkMode(deviceIsDark: true, in: .inactive)
        settings.alignReaderDarkMode(deviceIsDark: true, in: .active)
        #expect(!settings.readerDarkMode)
        #expect(!settings.readerFollowSystemTheme)

        // The device does turn light while the app is away: taken up as the scene comes
        // back, and followed from there.
        settings.alignReaderDarkMode(deviceIsDark: false, in: .background)
        settings.alignReaderDarkMode(deviceIsDark: false, in: .inactive)
        #expect(settings.readerFollowSystemTheme)
        settings.alignReaderDarkMode(deviceIsDark: true, in: .active)
        #expect(settings.readerDarkMode)
    }

    /// 外觀主題's preview of its other slot flips the whole window (2026-10-05). A reader
    /// left open under another tab is not to take it for the device turning: a mode set
    /// against the device would come back as following once the preview ended.
    @Test func aPreviewOfTheOtherSlotIsNotTheDeviceTurning() {
        let settings = GlobalSettings.shared
        let fixture = Fixture(settings)
        let preview = settings.appearanceSlotPreview
        defer {
            settings.appearanceSlotPreview = preview
            fixture.restore()
        }

        settings.appearanceBindReaderTheme = false
        settings.readerCustomBackgroundID = nil
        settings.readerFollowSystemTheme = true
        settings.readerDarkMode = false
        settings.alignReaderDarkMode(deviceIsDark: true, in: .active)
        // 白天 by hand in the dark app.
        settings.setReaderDarkMode(false, deviceIsDark: true)
        #expect(!settings.readerFollowSystemTheme)

        // 外觀主題 previews 淺色, then the preview ends and the app is dark again.
        settings.appearanceSlotPreview = .light
        settings.alignReaderDarkMode(deviceIsDark: false, in: .active)
        settings.appearanceSlotPreview = nil
        settings.alignReaderDarkMode(deviceIsDark: true, in: .active)
        #expect(!settings.readerDarkMode)
        #expect(!settings.readerFollowSystemTheme)
    }

    /// What the reader lets go of or takes up again by itself is not a setting made here:
    /// noted, every device would hand its own state to the others.
    @Test func whatTheReaderFollowsByItselfIsNotNoted() {
        let settings = GlobalSettings.shared
        let fixture = Fixture(settings)
        defer { fixture.restore() }

        settings.appearanceBindReaderTheme = false
        settings.readerFollowSystemTheme = true
        settings.readerDarkMode = false
        settings.readingSettingSyncRecords = []

        settings.setReaderDarkMode(true, deviceIsDark: false)
        #expect(!settings.readerFollowSystemTheme)
        settings.alignReaderDarkMode(deviceIsDark: true, in: .active)
        #expect(settings.readerFollowSystemTheme)
        #expect(Self.backgroundRecord(settings) == nil)
    }

    /// The reading setup is worn again whenever the appearance changes. That must take back
    /// neither what the reader took up by itself nor the mode it is in — on the simulator
    /// the reader stopped following the device at the first change of appearance, the
    /// stored setup still saying it did not (2026-09-30).
    @Test func wearingTheSetupAgainKeepsTheModeAndWhatItFollows() {
        let settings = GlobalSettings.shared
        let fixture = Fixture(settings)
        defer { fixture.restore() }

        settings.appearanceBindReaderTheme = false
        settings.readerCustomBackgroundID = nil
        settings.readerFollowSystemTheme = true
        settings.readerDarkMode = false
        ReaderConfig.shared.theme = .white

        // 深色 by hand on a device in light appearance, the reader putting 黑色 in place.
        settings.setReaderDarkMode(true, deviceIsDark: false)
        ReaderConfig.shared.theme = .night
        settings.synchronizeReadingSettings()
        #expect(settings.readerDarkMode)
        #expect(!settings.readerFollowSystemTheme)

        // The device comes round to it, and the setup is worn again.
        settings.alignReaderDarkMode(deviceIsDark: true, in: .active)
        settings.synchronizeReadingSettings()
        #expect(settings.readerFollowSystemTheme)
        #expect(settings.readerDarkMode)

        // Back to light: followed, and still followed after the setup is worn again.
        settings.alignReaderDarkMode(deviceIsDark: false, in: .active)
        ReaderConfig.shared.theme = .white
        settings.synchronizeReadingSettings()
        #expect(!settings.readerDarkMode)
        #expect(settings.readerFollowSystemTheme)

        // A dark saved background worn in light mode sits on 黑色; dark mode set by hand
        // leaves 黑色 in place, and wearing the setup again must not read that as light mode.
        let dark = settings.saveReaderCustomBackground(Self.color("深", 0x1B1B28))
        ReaderConfig.shared.theme = settings.wearReaderCustomBackground(dark, over: .white, deviceIsDark: false)
        settings.setReaderDarkMode(true, deviceIsDark: false)
        settings.synchronizeReadingSettings()
        #expect(settings.readerDarkMode)
    }

    /// A reader updated to this keeps what is on its screen: the mode starts from what it
    /// used to be read off, and only a reader never given a background follows the device
    /// from the start.
    @Test func aReaderWithNoModeStoredStartsFromWhatIsOnScreen() {
        #expect(GlobalSettings.startingReaderDarkMode(stored: nil, theme: .night, wornBackgroundIsDark: false, binds: false))
        #expect(!GlobalSettings.startingReaderDarkMode(stored: nil, theme: .night, wornBackgroundIsDark: true, binds: false),
                "黑色 under a dark saved background is the light mode")
        #expect(!GlobalSettings.startingReaderDarkMode(stored: nil, theme: .sepia, wornBackgroundIsDark: false, binds: false))
        #expect(GlobalSettings.startingReaderDarkMode(stored: nil, theme: .night, wornBackgroundIsDark: true, binds: true))
        #expect(!GlobalSettings.startingReaderDarkMode(stored: false, theme: .night, wornBackgroundIsDark: false, binds: false))

        #expect(GlobalSettings.startingReaderFollowsDevice(stored: nil, hasPickedBackground: false))
        #expect(!GlobalSettings.startingReaderFollowsDevice(stored: nil, hasPickedBackground: true))
        #expect(GlobalSettings.startingReaderFollowsDevice(stored: true, hasPickedBackground: true))
    }

    /// A built-in background arriving in place of the one in use — a theme's reading
    /// setup, another device's — says which mode that reader was in: 黑色 is dark mode,
    /// unless a dark saved background sits on it.
    @Test func aBuiltInBackgroundArrivingSetsTheMode() throws {
        let settings = GlobalSettings.shared
        let fixture = Fixture(settings)
        defer { fixture.restore() }
        settings.appearanceBindReaderTheme = false
        settings.readerCustomBackgroundID = nil
        settings.readerDarkMode = false
        ReaderTheme.white.persist()

        var setup = AppearanceThemeReadingSettings()
        setup.readerTheme = ReaderTheme.night.rawValue
        setup.readerBackgroundID = ""
        try settings.writeReadingSettings(setup, origin: .theme)
        #expect(settings.readerDarkMode)

        setup.readerTheme = ReaderTheme.green.rawValue
        try settings.writeReadingSettings(setup, origin: .theme)
        #expect(!settings.readerDarkMode)

        let dark = settings.saveReaderCustomBackground(Self.color("深", 0x1B1B28))
        setup.readerTheme = ReaderTheme.night.rawValue
        setup.readerBackgroundID = dark.id.uuidString
        try settings.writeReadingSettings(setup, origin: .theme)
        #expect(!settings.readerDarkMode, "黑色 is what the dark saved background sits on")
    }

    /// Its text colour is its own, not the 文字顏色 set for the built-in under it.
    @Test func aSavedBackgroundsTextColorIsItsOwn() {
        let settings = GlobalSettings.shared
        let fixture = Fixture(settings)
        defer { fixture.restore() }

        settings.setReaderTextColorOverride(0x0000FF, for: .white)
        var background = Self.color("紙", 0xF7F1E3)
        background.textColorHex = 0x5A3E2B
        let saved = settings.saveReaderCustomBackground(background)
        AppearanceThemePreset.activeReaderTheme = settings.readerBackgroundPreset(for: saved)
        #expect(ReaderTheme.white.uiTextColor.rgbHex == 0x5A3E2B)

        settings.setReaderCustomBackgroundTextColor(nil, id: saved.id)
        #expect(settings.readerCustomBackground(id: saved.id)?.resolvedTextColorHex == ReaderCustomBackground.darkTextHex)
    }

    // MARK: - The list

    @Test func eachSavedBackgroundKeepsItsOwnName() throws {
        let settings = GlobalSettings.shared
        let fixture = Fixture(settings)
        defer { fixture.restore() }
        settings.readerCustomBackgrounds = []

        let base = localized("自訂背景")
        let first = settings.saveReaderCustomBackground(Self.color(
            ReaderCustomBackgroundLibrary.unusedName(base: base, among: settings.readerCustomBackgrounds),
            0xFFFFFF
        ))
        let second = settings.saveReaderCustomBackground(Self.color(
            ReaderCustomBackgroundLibrary.unusedName(base: base, among: settings.readerCustomBackgrounds),
            0xEEEEEE
        ))
        #expect(first.name == base)
        #expect(second.name == "\(base) 2")
        #expect(settings.readerCustomBackgrounds.map(\.id) == [first.id, second.id])

        var renamed = first
        renamed.name = "晨光"
        let stored = settings.saveReaderCustomBackground(renamed)
        #expect(settings.readerCustomBackgrounds.count == 2)
        #expect(settings.readerCustomBackground(id: first.id)?.name == "晨光")
        // Every save is an edit iCloud has to see.
        #expect(try #require(stored.updatedAt) >= (first.updatedAt ?? .distantPast))
    }

    @Test func deletingABackgroundTakesItOffTheReaderAndBothPicks() {
        let settings = GlobalSettings.shared
        let fixture = Fixture(settings)
        defer { fixture.restore() }

        let background = settings.saveReaderCustomBackground(Self.color("暫時", 0x223344))
        _ = settings.wearReaderCustomBackground(background, over: .white, deviceIsDark: false)
        settings.setBoundReaderTheme(.custom(background.id), for: .light)
        settings.setBoundReaderTheme(.custom(background.id), for: .dark)

        settings.deleteReaderCustomBackground(id: background.id)
        #expect(settings.readerCustomBackground(id: background.id) == nil)
        #expect(settings.readerCustomBackgroundID == nil)
        #expect(settings.boundReaderTheme(for: .light) == .followAppearanceTheme)
        #expect(settings.boundReaderTheme(for: .dark) == .reading(.night))
    }

    /// A theme's stored pick of a background deleted since reads as the pick's start, so
    /// the picker never lands on nothing.
    @Test func aStoredPickOfADeletedBackgroundReadsAsTheStart() throws {
        let settings = GlobalSettings.shared
        let fixture = Fixture(settings)
        defer { fixture.restore() }

        var reading = AppearanceThemeReadingSettings()
        reading.boundDarkReaderTheme = ReaderBoundTheme.custom(UUID()).storageValue
        reading.readerBackgroundID = UUID().uuidString
        try settings.writeReadingSettings(reading, origin: .theme)
        #expect(settings.boundReaderTheme(for: .dark) == .reading(.night))
        #expect(settings.readerCustomBackgroundID == nil)
    }

    /// iCloud's merged list replaces this device's; a background deleted elsewhere leaves
    /// the reader and the picks like a local delete does.
    @Test func aSyncedDeletionLeavesNoReferenceBehind() {
        let settings = GlobalSettings.shared
        let fixture = Fixture(settings)
        defer { fixture.restore() }

        let kept = settings.saveReaderCustomBackground(Self.color("留", 0xFAFAFA))
        let gone = settings.saveReaderCustomBackground(Self.color("走", 0x101010))
        _ = settings.wearReaderCustomBackground(gone, over: .white, deviceIsDark: false)
        settings.setBoundReaderTheme(.custom(gone.id), for: .dark)

        settings.applyReaderCustomBackgroundsSync(settings.readerCustomBackgrounds.filter { $0.id != gone.id })
        #expect(settings.readerCustomBackgrounds.map(\.id).contains(kept.id))
        #expect(settings.readerCustomBackground(id: gone.id) == nil)
        #expect(settings.readerCustomBackgroundID == nil)
        #expect(settings.boundReaderTheme(for: .dark) == .reading(.night))
    }

    @Test func thePicturesASyncCarriesAreTheOnesTheListShows() {
        let one = Self.picture("一")
        var two = Self.picture("二")
        two.imageFileName = one.imageFileName
        let payloads = ICloudSyncManager.readerBackgroundPicturePayloads(
            [one, two, Self.color("色", 0xABCDEF)]
        )
        #expect(payloads.count == 1)
        #expect(payloads.first?.recordName.hasPrefix("readerbg_") == true)
        #expect(payloads.first?.localURL.lastPathComponent == one.imageFileName)
    }

    // MARK: - Theme packs

    /// A pack's reading picture is a saved background named after the pack, and both
    /// picks under 綁定閱讀主題 are on it — dark mode keeps the pack, not 黑色.
    @Test func aPacksPictureIsKeptInDarkMode() async throws {
        let settings = GlobalSettings.shared
        let fixture = Fixture(settings)
        defer { fixture.restore() }

        var pack = QiThemeImport(
            name: "Picture Pack",
            themeFile: AppearanceThemeExportFile(customTheme: AppearanceCustomTheme(
                name: "Picture Pack", backgroundHex: 0xFFFFFF, textHex: 0, barHex: 0xFFFFFF,
                accentHex: 0x123456, dialogueHex: 0
            ))
        )
        pack.readerBackground = QiThemeImport.ImageFile(data: Self.png(.init(white: 0.95, alpha: 1)), fileName: "bg.png")
        let outcome = try await QiThemeImportService.apply(pack)
        let theme = try #require(outcome.theme)
        fixture.importedThemes.append(theme.id)

        let saved = try #require(settings.readerCustomBackgrounds.first { $0.name == "Picture Pack" })
        fixture.savedBackgrounds.append(saved.id)
        #expect(saved.isImage)
        #expect(theme.extras?.reading?.readerBackgroundID == saved.id.uuidString)
        #expect(settings.appearanceBindReaderTheme)
        #expect(settings.boundReaderTheme(for: .dark) == .custom(saved.id))

        let dark = settings.readerBackgroundResolution(mode: .dark, wornTheme: .night)
        #expect(dark.customBackground?.id == saved.id)
    }

    /// A pack's light page picture shows in dark mode too, dimmed, when it has none for
    /// dark — the page no longer drops to plain black.
    @Test func aPacksLightPagePictureIsReusedInDarkMode() throws {
        let settings = GlobalSettings.shared
        let fixture = Fixture(settings)
        defer { fixture.restore() }

        var file = AppearanceThemeExportFile(customTheme: AppearanceCustomTheme(
            name: "Page Pack", backgroundHex: 0xFFFFFF, textHex: 0, barHex: 0xFFFFFF,
            accentHex: 0x123456, dialogueHex: 0
        ))
        file.pageBackgrounds = [AppearancePageBackgroundScope.global.rawValue: .init(
            lightImage: .init(fileExtension: "png", base64: Self.png(.orange).base64EncodedString())
        )]
        _ = try settings.importAppearanceCustomization(from: JSONEncoder().encode(file))
        let theme = try #require(settings.customAppearanceThemes.first { $0.name == "Page Pack" })
        fixture.importedThemes.append(theme.id)

        let config = try #require(theme.extras?.pageBackgrounds?[AppearancePageBackgroundScope.global.rawValue])
        #expect(config.lightImageFileName != nil)
        #expect(config.darkImageFileName == config.lightImageFileName)
        #expect(config.darkImageOpacity == AppearancePageBackgroundConfig.reusedDarkImageOpacity)
        // The one the user reset to also has it.
        #expect(theme.originalExtras?.pageBackgrounds?[AppearancePageBackgroundScope.global.rawValue]?
            .darkImageFileName == config.lightImageFileName)
    }

    // MARK: - Migration

    /// The old single custom background, and every stored setup that named one, become
    /// saved backgrounds; a pack's picture is bound to both appearances; a pack's light
    /// page picture is reused in dark mode. Once.
    @Test func theOldCustomBackgroundsBecomeSavedOnes() throws {
        let suite = "reader-background-migration-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        // The live slot: a colour, worn, with 白色's text colour set.
        defaults.set(ReaderCustomBackgroundMode.color.rawValue, forKey: ReaderBackgroundMigration.legacyModeKey)
        defaults.set(0x10203A, forKey: ReaderBackgroundMigration.legacyColorKey)
        defaults.set(ReaderTheme.white.rawValue, forKey: "yd_reader_theme")
        defaults.set([ReaderTheme.white.rawValue: 0xEEEEEE], forKey: "yd_reader_text_color_overrides")

        // Two packs showing the same picture; the second has its binding set by hand.
        func pack(_ name: String, binds: Bool?) -> AppearanceCustomTheme {
            var reading = AppearanceThemeReadingSettings()
            reading.customBackground = .init(mode: ReaderCustomBackgroundMode.image.rawValue, colorHex: nil, imageFileName: "pack.jpg")
            reading.bindsAppearanceReaderTheme = binds
            var extras = AppearanceThemeExtras()
            extras.reading = reading
            extras.pageBackgrounds = [AppearancePageBackgroundScope.global.rawValue: AppearancePageBackgroundConfig(
                lightPrimaryHex: nil, lightSecondaryHex: nil, darkPrimaryHex: nil, darkSecondaryHex: nil,
                lightImageFileName: "page.jpg"
            )]
            return AppearanceCustomTheme(name: name, backgroundHex: 0xFFFFFF, textHex: 0, barHex: 0xFFFFFF,
                                         accentHex: 0, dialogueHex: 0, extras: extras, originalExtras: extras)
        }
        let themes = [pack("甲", binds: false), pack("乙", binds: true)]
        defaults.set(try JSONEncoder().encode(themes), forKey: GlobalSettings.customAppearanceThemesKey)

        ReaderBackgroundMigration.runIfNeeded(defaults: defaults, now: Date()) { fileName in
            ReaderBackgroundPicture(fileName: fileName, averageColorHex: 0xE0D8C8, isDark: false)
        }

        let saved = GlobalSettings.loadReaderCustomBackgrounds(defaults: defaults)
        #expect(saved.count == 2)
        let color = try #require(saved.first { !$0.isImage })
        #expect(color.colorHex == 0x10203A)
        #expect(color.isDark)
        #expect(color.textColorHex == 0xEEEEEE)
        #expect(defaults.string(forKey: GlobalSettings.readerCustomBackgroundIDKey) == color.id.uuidString)
        #expect(defaults.object(forKey: ReaderBackgroundMigration.legacyModeKey) == nil)

        let picture = try #require(saved.first { $0.isImage })
        #expect(picture.name == "甲")
        let migrated = try JSONDecoder().decode(
            [AppearanceCustomTheme].self,
            from: try #require(defaults.data(forKey: GlobalSettings.customAppearanceThemesKey))
        )
        let first = try #require(migrated.first?.extras?.reading)
        #expect(first.customBackground == nil)
        #expect(first.readerBackgroundID == picture.id.uuidString)
        #expect(first.bindsAppearanceReaderTheme == true)
        #expect(first.boundDarkReaderTheme == ReaderBoundTheme.custom(picture.id).storageValue)
        #expect(migrated.first?.originalExtras?.reading?.readerBackgroundID == picture.id.uuidString)
        // Set up by hand already: left alone apart from the id.
        let second = try #require(migrated.last?.extras?.reading)
        #expect(second.readerBackgroundID == picture.id.uuidString)
        #expect(second.boundDarkReaderTheme == nil)
        // Page pictures.
        let page = try #require(migrated.first?.extras?.pageBackgrounds?[AppearancePageBackgroundScope.global.rawValue])
        #expect(page.darkImageFileName == "page.jpg")
        #expect(page.darkImageOpacity == AppearancePageBackgroundConfig.reusedDarkImageOpacity)

        // Once: a picture the user later takes off dark mode stays off.
        var edited = migrated
        edited[0].extras?.pageBackgrounds?[AppearancePageBackgroundScope.global.rawValue]?.darkImageFileName = nil
        defaults.set(try JSONEncoder().encode(edited), forKey: GlobalSettings.customAppearanceThemesKey)
        ReaderBackgroundMigration.runIfNeeded(defaults: defaults, now: Date()) { _ in nil }
        let again = try JSONDecoder().decode(
            [AppearanceCustomTheme].self,
            from: try #require(defaults.data(forKey: GlobalSettings.customAppearanceThemesKey))
        )
        #expect(again.first?.extras?.pageBackgrounds?[AppearancePageBackgroundScope.global.rawValue]?.darkImageFileName == nil)
        #expect(GlobalSettings.loadReaderCustomBackgrounds(defaults: defaults).count == 2)
    }

    /// The report: the pack's background showed as 自訂背景, not the pack's name. The old
    /// applier put a pack's reading picture into the reader's one custom slot, so the slot
    /// and the pack named the same file; the slot was migrated first, and the pack joined
    /// the background it had made under the slot's name.
    @Test func aPacksPictureWornInTheReaderIsNamedAfterThePack() throws {
        let suite = "reader-background-names-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        // What applying the pack left behind: the reader wearing its picture…
        defaults.set(ReaderCustomBackgroundMode.image.rawValue, forKey: ReaderBackgroundMigration.legacyModeKey)
        defaults.set("pack.jpg", forKey: ReaderBackgroundMigration.legacyImageKey)
        // …and the pack's own setup naming the same file.
        var reading = AppearanceThemeReadingSettings()
        reading.customBackground = .init(mode: ReaderCustomBackgroundMode.image.rawValue, colorHex: nil, imageFileName: "pack.jpg")
        var extras = AppearanceThemeExtras()
        extras.reading = reading
        let pack = AppearanceCustomTheme(name: "山风-凄美地", backgroundHex: 0xFFFFFF, textHex: 0, barHex: 0xFFFFFF,
                                         accentHex: 0, dialogueHex: 0, extras: extras, originalExtras: extras)
        defaults.set(try JSONEncoder().encode([pack]), forKey: GlobalSettings.customAppearanceThemesKey)

        ReaderBackgroundMigration.runIfNeeded(defaults: defaults, now: Date()) { fileName in
            ReaderBackgroundPicture(fileName: fileName, averageColorHex: 0xE0D8C8, isDark: false)
        }

        let saved = GlobalSettings.loadReaderCustomBackgrounds(defaults: defaults)
        #expect(saved.map(\.name) == ["山风-凄美地"])
        #expect(defaults.string(forKey: GlobalSettings.readerCustomBackgroundIDKey) == saved.first?.id.uuidString)
    }

    /// A device that migrated the old way keeps the pack's background as 自訂背景 until
    /// this runs: once, and only on a pack's own background (the one its original setup
    /// names) still called by the name the migration gave it.
    @Test func aPacksBackgroundLeftWithTheDefaultNameIsRenamedOnce() throws {
        let suite = "reader-background-renames-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: ReaderBackgroundMigration.savedBackgroundsDoneKey)
        defaults.set(true, forKey: ReaderBackgroundMigration.packDarkPagesDoneKey)

        let base = localized("自訂背景")
        let packs = ReaderCustomBackground(name: base, colorHex: 0xE0D8C8, imageFileName: "pack.jpg", isDark: false)
        // Made in the editor under its default name and worn under the pack: the user's own.
        let usersOwn = ReaderCustomBackground(name: "\(base) 2", colorHex: 0x203040, isDark: true)
        let named = ReaderCustomBackground(name: "晚霞", colorHex: 0xE0C0A0, imageFileName: "other.jpg", isDark: false)
        GlobalSettings.saveReaderCustomBackgrounds([packs, usersOwn, named], defaults: defaults)

        func theme(_ name: String, original: ReaderCustomBackground, worn: ReaderCustomBackground) -> AppearanceCustomTheme {
            var originalExtras = AppearanceThemeExtras()
            originalExtras.reading = AppearanceThemeReadingSettings()
            originalExtras.reading?.readerBackgroundID = original.id.uuidString
            var extras = AppearanceThemeExtras()
            extras.reading = AppearanceThemeReadingSettings()
            extras.reading?.readerBackgroundID = worn.id.uuidString
            return AppearanceCustomTheme(name: name, backgroundHex: 0xFFFFFF, textHex: 0, barHex: 0xFFFFFF,
                                         accentHex: 0, dialogueHex: 0, extras: extras, originalExtras: originalExtras)
        }
        let themes = [
            theme("山风-凄美地", original: packs, worn: usersOwn),
            theme("晚霞包", original: named, worn: named),
        ]
        defaults.set(try JSONEncoder().encode(themes), forKey: GlobalSettings.customAppearanceThemesKey)

        ReaderBackgroundMigration.runIfNeeded(defaults: defaults, now: Date()) { _ in nil }

        let saved = GlobalSettings.loadReaderCustomBackgrounds(defaults: defaults)
        #expect(saved.map(\.name) == ["山风-凄美地", "\(base) 2", "晚霞"])
        // An edit like any other, so iCloud carries the new name to the other devices.
        #expect(saved.first?.updatedAt != nil)
        #expect(saved.dropFirst().allSatisfy { $0.updatedAt == nil })

        // Once: a name the user puts back afterwards stays.
        var renamedBack = saved
        renamedBack[0].name = base
        GlobalSettings.saveReaderCustomBackgrounds(renamedBack, defaults: defaults)
        ReaderBackgroundMigration.runIfNeeded(defaults: defaults, now: Date()) { _ in nil }
        #expect(GlobalSettings.loadReaderCustomBackgrounds(defaults: defaults).first?.name == base)
    }

    // MARK: - 重置為默認 and 匯出全部自訂

    /// 重置為默認 puts everything 外觀主題 sets back, keeps the themes, leaves reading alone.
    @Test func resettingTheAppearanceKeepsThemesAndReading() throws {
        let settings = GlobalSettings.shared
        let fixture = Fixture(settings)
        defer { fixture.restore() }

        let theme = AppearanceCustomTheme(name: "Kept", backgroundHex: 0xFFFFFF, textHex: 0, barHex: 0xFFFFFF,
                                          accentHex: 0x123456, dialogueHex: 0)
        settings.customAppearanceThemes.append(theme)
        fixture.importedThemes.append(theme.id)
        settings.appearanceThemeID = theme.id
        settings.interfaceGlowIntensity = 0.9
        settings.rootTabHidesLabels = true
        settings.launchImageEnabled = true
        settings.appearanceReaderInterface = .modern
        var edited = AppearanceThemePreset.classic.customCopy(name: "默認")
        edited.accentHex = 0x00AA00
        settings.appearanceBuiltInThemeColors = [AppearanceThemePreset.classicID: edited]
        let fontSize = settings.readerFontSize

        settings.resetAppearanceToDefault()
        #expect(settings.appearanceBuiltInThemeColors.isEmpty)
        #expect(settings.appearanceThemeID == GlobalSettings.defaultAppearanceThemeID)
        #expect(settings.appearanceDarkThemeID == GlobalSettings.defaultAppearanceThemeID)
        #expect(settings.interfaceGlowIntensity == GlobalSettings.defaultInterfaceGlowIntensity)
        #expect(!settings.rootTabHidesLabels)
        #expect(!settings.launchImageEnabled)
        #expect(settings.appearanceReaderInterface == .classic)
        #expect(settings.appearancePageBackgrounds.isEmpty)
        #expect(settings.customAppearanceThemes.contains { $0.id == theme.id })
        #expect(settings.readerFontSize == fontSize)
    }

    @Test func aBundleCarriesEverySavedBackground() throws {
        let settings = GlobalSettings.shared
        let fixture = Fixture(settings)
        defer { fixture.restore() }
        // Only this test's own: a bundle of the device's list would re-import its pictures
        // under new names, and the list the fixture puts back would name the old ones.
        settings.readerCustomBackgrounds = []

        let picture = try settings.importReaderBackgroundPicture(data: Self.png(.brown))
        let withPicture = settings.saveReaderCustomBackground(ReaderCustomBackground(
            name: "照片", colorHex: picture.averageColorHex, imageFileName: picture.fileName, isDark: picture.isDark
        ))
        let plain = settings.saveReaderCustomBackground(Self.color("素色", 0xDDE8D8))
        _ = settings.wearReaderCustomBackground(plain, over: .white, deviceIsDark: false)

        let bundle = AppearanceCustomizationBundle(snapshot: settings.appearanceCustomizationSnapshot())
        let carried = try #require(bundle.savedReaderBackgrounds)
        #expect(carried.first { $0.id == withPicture.id }?.image != nil)
        #expect(bundle.wornReaderBackgroundID == plain.id)
        // What an older build reads: the worn one.
        #expect(bundle.readerBackground?.mode == ReaderCustomBackgroundMode.color.rawValue)

        settings.deleteReaderCustomBackground(id: withPicture.id)
        settings.deleteReaderCustomBackground(id: plain.id)
        var summary = AppearanceImportSummary()
        let worn = settings.restoreReaderBackgrounds(from: bundle, into: &summary)
        #expect(worn == plain.id)
        #expect(summary.restoredReaderBackground)
        let restored = try #require(settings.readerCustomBackground(id: withPicture.id))
        #expect(restored.name == "照片")
        let restoredURL = try #require(settings.readerBackgroundImageURL(for: restored))
        #expect(FileManager.default.fileExists(atPath: restoredURL.path))
    }

    // MARK: - 穿哪個背景, across devices

    /// A background picked here is this device's latest setting of the 閱讀背景 row,
    /// snapshotted with its time — with the built-in background it sits on, when the mode
    /// it is worn in is held against the device. The reader setting the built-in
    /// background for the device's appearance by itself is not, and neither is wearing a
    /// theme's own setup.
    @Test func pickingABackgroundIsNotedAndFollowingTheSystemIsNot() throws {
        let settings = GlobalSettings.shared
        let fixture = Fixture(settings)
        defer { fixture.restore() }
        let saved = settings.saveReaderCustomBackground(Self.color("夜色", 0x102030))
        fixture.savedBackgrounds.append(saved.id)
        ReaderConfig.shared.theme = .white
        settings.readingSettingSyncRecords = []

        // A saved tile in the reader, as ReaderQuickThemePanelView wears it, on a device
        // in dark appearance: the light mode that wears it is held against the device.
        ReaderConfig.shared.theme = settings.wearReaderCustomBackground(
            saved, over: ReaderConfig.shared.theme, deviceIsDark: true
        )
        let picked = try #require(Self.backgroundRecord(settings))
        #expect(picked.values.readerBackgroundID == saved.id.uuidString)
        #expect(picked.values.readerTheme == ReaderTheme.night.rawValue)
        #expect(picked.values.followsSystemTheme == false)
        #expect(picked.values.bindsAppearanceReaderTheme == false)
        #expect(picked.values.fontSize == nil)

        // 跟隨裝置深淺色: turning it on is a setting; the reader then turning 白色 is not.
        settings.readerFollowSystemTheme = true
        let following = try #require(Self.backgroundRecord(settings))
        #expect(following.values.followsSystemTheme == true)
        #expect(following.values.readerTheme == nil)
        ReaderConfig.shared.theme = .white
        #expect(Self.backgroundRecord(settings) == following)

        // Wearing a theme's own setup.
        var themes = AppearanceThemeReadingSettings()
        themes.readerTheme = ReaderTheme.sepia.rawValue
        themes.followsSystemTheme = false
        let wasApplying = settings.isApplyingAppearanceExtras
        settings.isApplyingAppearanceExtras = true
        try settings.writeReadingSettings(themes, origin: .theme)
        settings.isApplyingAppearanceExtras = wasApplying
        #expect(Self.backgroundRecord(settings) == following)
    }

    /// A background from another device is worn — recorded where the background comes
    /// from, so wearing the setup again keeps it — and stays that device's: nothing here
    /// notes it again, which would make both devices claim the newest on every sync.
    @Test func aBackgroundFromAnotherDeviceIsWornWithoutBecomingThisOnes() throws {
        let settings = GlobalSettings.shared
        let fixture = Fixture(settings)
        defer { fixture.restore() }
        let saved = settings.saveReaderCustomBackground(Self.color("晨光", 0xF0E8D8))
        fixture.savedBackgrounds.append(saved.id)
        settings.appearanceBindReaderTheme = true
        settings.readingSettingSyncRecords = []

        var values = AppearanceThemeReadingSettings()
        values.readerTheme = ReaderTheme.sepia.rawValue
        values.readerBackgroundID = saved.id.uuidString
        values.followsSystemTheme = false
        values.bindsAppearanceReaderTheme = false
        values.boundLightReaderTheme = ReaderBoundTheme.followAppearanceTheme.storageValue
        values.boundDarkReaderTheme = ReaderBoundTheme.reading(.night).storageValue
        let record = ReadingSettingSyncRecord(
            item: ReadingSettingsScopeItem.background.rawValue,
            values: values,
            editedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        settings.applyReadingSettingsSync([record])

        #expect(settings.readingSettingSyncRecords == [record])
        #expect(!settings.appearanceBindReaderTheme)
        #expect(settings.readerCustomBackgroundID == saved.id)
        #expect(ReaderTheme.loadPersisted() == .sepia)
        let resolution = settings.readerBackgroundResolution(mode: .light, wornTheme: ReaderTheme.loadPersisted())
        #expect(resolution.customBackground?.id == saved.id)

        settings.synchronizeReadingSettings()
        #expect(settings.readerCustomBackgroundID == saved.id)
        #expect(ReaderTheme.loadPersisted() == .sepia)
    }

    /// A background deleted on another device comes off the reader here when the list
    /// syncs — the sync's doing, so the other device's setting still wins the next merge.
    @Test func aSyncedDeletionIsNotASettingMadeHere() throws {
        let settings = GlobalSettings.shared
        let fixture = Fixture(settings)
        defer { fixture.restore() }
        let saved = settings.saveReaderCustomBackground(Self.color("暮色", 0x302010))
        fixture.savedBackgrounds.append(saved.id)
        ReaderConfig.shared.theme = settings.wearReaderCustomBackground(
            saved, over: ReaderConfig.shared.theme, deviceIsDark: false
        )
        let before = try #require(Self.backgroundRecord(settings))

        settings.applyReaderCustomBackgroundsSync(settings.readerCustomBackgrounds.filter { $0.id != saved.id })

        #expect(settings.readerCustomBackgroundID == nil)
        #expect(Self.backgroundRecord(settings) == before)
    }

    private static func backgroundRecord(_ settings: GlobalSettings) -> ReadingSettingSyncRecord? {
        settings.readingSettingSyncRecords.first { $0.item == ReadingSettingsScopeItem.background.rawValue }
    }

    // MARK: - Helpers

    private static func color(_ name: String, _ hex: UInt32) -> ReaderCustomBackground {
        ReaderCustomBackground(name: name, colorHex: hex, isDark: ReaderBackgroundTone.isDark(rgbHex: hex))
    }

    private static func picture(_ name: String) -> ReaderCustomBackground {
        ReaderCustomBackground(
            name: name,
            colorHex: 0xE6E0D4,
            imageFileName: "reader-background-\(UUID().uuidString).jpg",
            isDark: false
        )
    }

    private static func png(_ color: UIColor) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    /// Puts back every setting these tests touch, field by field.
    @MainActor
    private final class Fixture {
        private let settings: GlobalSettings
        private let backgrounds: [ReaderCustomBackground]
        private let worn: UUID?
        private let binds: Bool
        private let followsSystem: Bool
        private let darkMode: Bool
        private let light: String
        private let dark: String
        private let overrides: [String: UInt32]
        private let lightID: String
        private let darkID: String
        private let separateDark: Bool
        private let themes: [AppearanceCustomTheme]
        private let baseline: AppearanceThemeExtras?
        private let pageBackgrounds: [String: AppearancePageBackgroundConfig]
        private let glow: Double
        private let hidesLabels: Bool
        private let launchEnabled: Bool
        private let interface: AppearanceReaderInterface
        private let followsSystemAppearance: Bool
        private let cardBackground: AppearanceCardBackground?
        private let tabIcons: [RootTabIconAsset]
        private let tabIconSize: Double
        private let visibleTabs: [String]
        private let globalFont: String?
        private let frostedGlass: Bool
        private let glassTransparency: Double
        private let glassCards: Bool
        private let chromeColors: [String: UInt32]
        private let chromeHidden: [String]
        private let chromeIcons: [ReaderChromeIconAsset]
        private let launchLight: String?
        private let launchDark: String?
        private let preset: AppearanceThemePreset?
        private let readerTheme: ReaderTheme
        private let lastLightTheme: ReaderTheme
        private let builtInColors: [String: AppearanceCustomTheme]
        private let reading: AppearanceThemeReadingSettings
        private let stores = ReadingSettingsStoresSnapshot()
        var importedThemes: [String] = []
        var savedBackgrounds: [UUID] = []

        init(_ settings: GlobalSettings) {
            self.settings = settings
            backgrounds = settings.readerCustomBackgrounds
            worn = settings.readerCustomBackgroundID
            binds = settings.appearanceBindReaderTheme
            followsSystem = settings.readerFollowSystemTheme
            darkMode = settings.readerDarkMode
            light = settings.appearanceBoundLightReaderTheme
            dark = settings.appearanceBoundDarkReaderTheme
            overrides = settings.readerTextColorOverrides
            lightID = settings.appearanceThemeID
            darkID = settings.appearanceDarkThemeID
            separateDark = settings.appearanceUsesSeparateDarkTheme
            themes = settings.customAppearanceThemes
            baseline = settings.appearanceExtrasBaseline
            pageBackgrounds = settings.appearancePageBackgrounds
            glow = settings.interfaceGlowIntensity
            hidesLabels = settings.rootTabHidesLabels
            launchEnabled = settings.launchImageEnabled
            interface = settings.appearanceReaderInterface
            followsSystemAppearance = settings.appearanceFollowsSystem
            cardBackground = settings.appearanceCardBackground
            tabIcons = settings.rootTabIconAssets
            tabIconSize = settings.rootTabIconSize
            visibleTabs = settings.rootTabVisibleIDs
            globalFont = settings.selectedGlobalFontPostScript
            frostedGlass = settings.interfaceFrostedGlass
            glassTransparency = settings.interfaceGlassTransparency
            glassCards = settings.interfaceGlassCards
            chromeColors = settings.readerChromeColors
            chromeHidden = settings.readerChromeHiddenIDs
            chromeIcons = settings.readerChromeIcons
            launchLight = settings.launchImageLightFileName
            launchDark = settings.launchImageDarkFileName
            preset = AppearanceThemePreset.activeReaderTheme
            readerTheme = ReaderTheme.loadPersisted()
            lastLightTheme = ReaderTheme.lastLightTheme
            builtInColors = settings.appearanceBuiltInThemeColors
            reading = settings.currentReadingSettingsSnapshot()
        }

        func restore() {
            settings.appearanceThemeID = GlobalSettings.defaultAppearanceThemeID
            settings.appearanceDarkThemeID = GlobalSettings.defaultAppearanceThemeID
            for id in importedThemes {
                settings.deleteCustomAppearanceTheme(id: id)
            }
            for id in savedBackgrounds {
                settings.deleteReaderCustomBackground(id: id)
            }
            // Pictures saved by a test and not in the list it started with go with it.
            for background in settings.readerCustomBackgrounds where !backgrounds.contains(where: { $0.id == background.id }) {
                settings.deleteReaderCustomBackground(id: background.id)
            }
            settings.readerCustomBackgrounds = backgrounds
            settings.appearanceExtrasBaseline = nil
            settings.customAppearanceThemes = themes
            settings.appearancePageBackgrounds = pageBackgrounds
            settings.interfaceGlowIntensity = glow
            settings.rootTabHidesLabels = hidesLabels
            settings.launchImageEnabled = launchEnabled
            settings.appearanceReaderInterface = interface
            settings.appearanceFollowsSystem = followsSystemAppearance
            settings.appearanceCardBackground = cardBackground
            settings.rootTabIconAssets = tabIcons
            settings.rootTabIconSize = tabIconSize
            settings.rootTabVisibleIDs = visibleTabs
            settings.selectedGlobalFontPostScript = globalFont
            settings.interfaceFrostedGlass = frostedGlass
            settings.interfaceGlassTransparency = glassTransparency
            settings.interfaceGlassCards = glassCards
            settings.readerChromeColors = chromeColors
            settings.readerChromeHiddenIDs = chromeHidden
            settings.readerChromeIcons = chromeIcons
            settings.launchImageLightFileName = launchLight
            settings.launchImageDarkFileName = launchDark
            settings.appearanceBuiltInThemeColors = builtInColors
            // The light one first: persisting a light background makes it the last light
            // one, which a test that wore another would otherwise leave behind.
            lastLightTheme.persist()
            readerTheme.persist()
            try? settings.writeReadingSettings(reading, origin: .theme)
            settings.readerCustomBackgroundID = worn
            settings.appearanceBindReaderTheme = binds
            settings.readerFollowSystemTheme = followsSystem
            settings.readerDarkMode = darkMode
            settings.appearanceBoundLightReaderTheme = light
            settings.appearanceBoundDarkReaderTheme = dark
            settings.readerTextColorOverrides = overrides
            // After the live values: writing those records them as edits.
            stores.restore()
            settings.appearanceExtrasBaseline = baseline
            settings.appearanceUsesSeparateDarkTheme = separateDark
            settings.appearanceThemeID = lightID
            settings.appearanceDarkThemeID = darkID
            AppearanceThemePreset.activeReaderTheme = preset
            ReaderConfig.shared.syncFromGlobalSettings()
        }
    }
}
