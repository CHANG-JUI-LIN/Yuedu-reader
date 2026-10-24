import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// A theme pack's toolbar icon file is named by the theme, by its pack original and,
/// while the theme is worn, by the live set. Replacing or removing the
/// icon while wearing the theme used to delete that file outright.
@Suite("Reader button icon ownership", .serialized)
@MainActor
struct ReaderChromeIconOwnershipTests {
    @Test func replacingAPackIconKeepsTheFileItsOriginalStillNeeds() throws {
        let settings = GlobalSettings.shared
        let fixture = Fixture(settings)
        defer { fixture.restore() }

        let packIcon = try Self.storeIcon(named: "rtb_settings.png")
        fixture.created.append(packIcon)
        var extras = AppearanceThemeExtras()
        extras.readerChromeIcons = [packIcon.itemID: packIcon.fileName]
        let pack = AppearanceCustomTheme(
            name: "Pack", backgroundHex: 0xFFFFFF, textHex: 0, barHex: 0xFFFFFF,
            accentHex: 0x123456, dialogueHex: 0, extras: extras, originalExtras: extras
        )
        settings.customAppearanceThemes.append(pack)
        settings.appearanceThemeID = pack.id
        #expect(settings.readerChromeIcon(for: ReaderChromeToolItem.settings)?.fileName == packIcon.fileName)

        let mine = try settings.importReaderChromeIcon(
            data: try Self.pngData(),
            originalFileName: "mine.png",
            item: ReaderChromeToolItem.settings
        )
        fixture.created.append(mine)
        #expect(FileManager.default.fileExists(atPath: try Self.path(of: packIcon)))
    }

    @Test func removingAnIconNothingElseNamesDeletesItsFile() throws {
        let settings = GlobalSettings.shared
        let fixture = Fixture(settings)
        defer { fixture.restore() }

        let icon = try settings.importReaderChromeIcon(
            data: try Self.pngData(),
            originalFileName: "only.png",
            item: ReaderChromeToolItem.listen
        )
        fixture.created.append(icon)
        #expect(FileManager.default.fileExists(atPath: try Self.path(of: icon)))

        settings.deleteReaderChromeIcon(for: ReaderChromeToolItem.listen)
        #expect(!FileManager.default.fileExists(atPath: try Self.path(of: icon)))
    }

    // MARK: - Helpers

    private static func storeIcon(named name: String) throws -> ReaderChromeIconAsset {
        try ReaderChromeIconStorage.shared.importIcon(
            data: try pngData(),
            originalFileName: name,
            itemID: ReaderChromeToolItem.settings.storageID
        )
    }

    private static func path(of asset: ReaderChromeIconAsset) throws -> String {
        try ReaderChromeIconStorage.shared.fileURL(for: asset).path
    }

    private static func pngData() throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format)
            .image { context in
                UIColor.systemTeal.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            }
        return try #require(image.pngData())
    }

    /// Puts the app on 默認 with no button icons, and back afterwards — field by field,
    /// and by plain assignment, which never deletes a file.
    @MainActor
    private final class Fixture {
        private let settings: GlobalSettings
        private let lightID: String
        private let darkID: String
        private let themes: [AppearanceCustomTheme]
        private let baseline: AppearanceThemeExtras?
        private let icons: [ReaderChromeIconAsset]
        /// Files a test made, removed at the end whatever the outcome.
        var created: [ReaderChromeIconAsset] = []

        init(_ settings: GlobalSettings) {
            self.settings = settings
            lightID = settings.appearanceThemeID
            darkID = settings.appearanceDarkThemeID
            themes = settings.customAppearanceThemes
            baseline = settings.appearanceExtrasBaseline
            icons = settings.readerChromeIcons
            settings.appearanceThemeID = GlobalSettings.defaultAppearanceThemeID
            settings.appearanceDarkThemeID = GlobalSettings.defaultAppearanceThemeID
            settings.appearanceExtrasBaseline = nil
            settings.readerChromeIcons = []
        }

        func restore() {
            settings.appearanceThemeID = GlobalSettings.defaultAppearanceThemeID
            settings.appearanceDarkThemeID = GlobalSettings.defaultAppearanceThemeID
            settings.appearanceExtrasBaseline = nil
            settings.customAppearanceThemes = themes
            settings.readerChromeIcons = icons
            settings.appearanceExtrasBaseline = baseline
            settings.appearanceThemeID = lightID
            settings.appearanceDarkThemeID = darkID
            let kept = Set(icons.map(\.fileName))
            for asset in created where !kept.contains(asset.fileName) {
                ReaderChromeIconStorage.shared.delete(asset)
            }
        }
    }
}
