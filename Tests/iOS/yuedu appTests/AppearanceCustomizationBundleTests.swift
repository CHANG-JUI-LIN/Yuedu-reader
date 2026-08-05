import Foundation
import SwiftUI
import Testing
import UIKit
@testable import yuedu_app

/// Export/import of the whole customised look. The point of the bundle is that
/// the images travel — a theme file alone left the tab icons, launch images and
/// reading background stranded on the device that made them.
@Suite("Appearance customization bundle", .serialized)
struct AppearanceCustomizationBundleTests {

    private func pngData(_ color: UIColor, side: CGFloat = 8) -> Data {
        let size = CGSize(width: side, height: side)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return image.pngData() ?? Data()
    }

    private func encoded(_ bundle: AppearanceCustomizationBundle) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(bundle)
    }

    @Test("a bundle carries every custom image, not just the theme colors")
    @MainActor
    func bundleCarriesEveryCustomImage() throws {
        let settings = GlobalSettings.shared
        let savedThemes = settings.customAppearanceThemes
        let savedBackgrounds = settings.appearancePageBackgrounds
        let savedIcons = settings.rootTabIconAssets
        let savedMode = settings.readerCustomBackgroundMode
        defer {
            settings.customAppearanceThemes = savedThemes
            settings.appearancePageBackgrounds = savedBackgrounds
            settings.rootTabIconAssets = savedIcons
            settings.readerCustomBackgroundMode = savedMode
        }

        try settings.importPageBackgroundImage(
            data: pngData(.red),
            scope: .global,
            appearance: .light
        )
        try settings.importRootTabIcon(
            data: pngData(.green),
            originalFileName: "icon.png",
            tab: RootTabItem.allCases[0],
            slot: RootTabIconSlot.allCases[0]
        )
        try settings.importLaunchImage(data: pngData(.blue), for: .light)

        let bundle = AppearanceCustomizationBundle(
            snapshot: settings.appearanceCustomizationSnapshot()
        )

        #expect(bundle.format == AppearanceCustomizationBundle.formatIdentifier)
        #expect(bundle.pageBackgrounds?[AppearancePageBackgroundScope.global.rawValue]?.lightImage != nil)
        #expect(bundle.tabIcons?.count == 1)
        #expect(bundle.tabIcons?.first?.originalFileName == "icon.png")
        #expect(bundle.launchImageLight != nil)
    }

    @Test("importing a bundle restores the tab icons and launch images")
    @MainActor
    func importRestoresImages() throws {
        let settings = GlobalSettings.shared
        let savedThemes = settings.customAppearanceThemes
        let savedBackgrounds = settings.appearancePageBackgrounds
        let savedIcons = settings.rootTabIconAssets
        defer {
            settings.customAppearanceThemes = savedThemes
            settings.appearancePageBackgrounds = savedBackgrounds
            settings.rootTabIconAssets = savedIcons
        }

        let tab = RootTabItem.allCases[0]
        let slot = RootTabIconSlot.allCases[0]
        try settings.importRootTabIcon(
            data: pngData(.green),
            originalFileName: "icon.png",
            tab: tab,
            slot: slot
        )
        try settings.importLaunchImage(data: pngData(.blue), for: .dark)
        let data = try encoded(
            AppearanceCustomizationBundle(snapshot: settings.appearanceCustomizationSnapshot())
        )

        // Wipe, then restore from the file alone.
        settings.deleteRootTabIcon(tab: tab, slot: slot)
        settings.clearLaunchImage(for: .dark)
        #expect(settings.rootTabIconAsset(for: tab, slot: slot) == nil)

        let summary = try settings.importAppearanceCustomization(from: data)

        #expect(summary.tabIcons == 1)
        #expect(summary.launchImages == 1)
        #expect(settings.rootTabIconAsset(for: tab, slot: slot) != nil)
        #expect(settings.launchImageFileName(for: .dark) != nil)
    }

    @Test("a plain theme file still imports as a theme")
    @MainActor
    func plainThemeFileStillImports() throws {
        let settings = GlobalSettings.shared
        let savedThemes = settings.customAppearanceThemes
        let savedID = settings.appearanceThemeID
        defer {
            settings.customAppearanceThemes = savedThemes
            settings.appearanceThemeID = savedID
        }

        let file = AppearanceThemeExportFile(
            customTheme: AppearanceCustomTheme(
                name: "Bundle Test Theme",
                backgroundHex: 0x112233,
                textHex: 0x445566,
                barHex: 0x778899,
                accentHex: 0xAABBCC,
                dialogueHex: 0xDDEEFF
            )
        )
        let data = try JSONEncoder().encode(file)

        let summary = try settings.importAppearanceCustomization(from: data)

        #expect(summary.themes == 1)
        #expect(summary.tabIcons == 0)
        #expect(settings.customAppearanceThemes.last?.name == "Bundle Test Theme")
    }

    @Test("an unrelated json is rejected instead of importing nothing quietly")
    @MainActor
    func unrelatedFileThrows() {
        let settings = GlobalSettings.shared
        let data = Data(#"{"hello":"world"}"#.utf8)

        #expect(throws: AppearanceThemeImportError.self) {
            try settings.importAppearanceCustomization(from: data)
        }
    }
}
