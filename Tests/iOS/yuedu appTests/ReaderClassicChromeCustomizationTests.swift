import Testing
import SwiftUI
import UIKit
@testable import yuedu_app

/// 外觀 → 閱讀界面 → 經典 → 自定義. The palette is the single place a colour falls
/// back to the reading theme, and the visibility list is the single place a tool
/// button can leave the bottom row — both are shared by the settings preview and
/// the reader itself, so a break here shows up as the two disagreeing.
@MainActor
@Suite("Reader classic chrome customization", .serialized)
struct ReaderClassicChromeCustomizationTests {

    // MARK: - Palette

    @Test("no override paints exactly what the reading theme paints")
    func paletteFollowsThemeWithoutOverrides() {
        let settings = GlobalSettings.shared
        settings.resetReaderClassicChrome()

        let theme = ReaderTheme.sepia
        let palette = ReaderClassicChromePalette(theme: theme, settings: settings)

        #expect(palette.topFill == theme.barColor)
        #expect(palette.topIcon == theme.textColor)
        #expect(palette.bottomFill == theme.barColor)
        #expect(palette.bottomIcon == theme.textColor)
        #expect(palette.bottomAccent == theme.accentColor)
        #expect(palette.circleFill == theme.barColor)
        // The circles alone soften the theme's body-text colour into chrome.
        #expect(palette.circleIcon == theme.textColor.opacity(0.9))
        #expect(palette.circleBorder == theme.textColor.opacity(0.35))

        settings.resetReaderClassicChrome()
    }

    @Test("每個色槽各自獨立，調一個不會動到別的")
    func eachSlotOverridesOnlyItself() {
        let settings = GlobalSettings.shared
        settings.resetReaderClassicChrome()
        defer { settings.resetReaderClassicChrome() }

        let theme = ReaderTheme.white
        settings.readerClassicTopBarFillHex = 0xFF0000
        settings.readerClassicBottomBarAccentHex = 0x00FF00

        let palette = ReaderClassicChromePalette(theme: theme, settings: settings)
        #expect(palette.topFill == Color(uiColor: AppearanceThemePreset.hex(0xFF0000)))
        #expect(palette.bottomAccent == Color(uiColor: AppearanceThemePreset.hex(0x00FF00)))
        // Untouched slots still follow the theme.
        #expect(palette.topIcon == theme.textColor)
        #expect(palette.bottomFill == theme.barColor)
        #expect(palette.circleFill == theme.barColor)
    }

    @Test("a hand-picked circle symbol colour is used exactly as picked")
    func pickedCircleIconIsNotFaded() {
        let settings = GlobalSettings.shared
        settings.resetReaderClassicChrome()
        defer { settings.resetReaderClassicChrome() }

        settings.readerClassicCircleIconHex = 0x123456
        let picked = Color(uiColor: AppearanceThemePreset.hex(0x123456))
        let palette = ReaderClassicChromePalette(theme: .night, settings: settings)

        #expect(palette.circleIcon == picked)
        #expect(palette.circleBorder == picked.opacity(0.35))
    }

    // MARK: - Bottom tool row visibility

    @Test("hiding a tool button removes it from the row")
    func hidingToolRemovesItFromTheRow() {
        let settings = GlobalSettings.shared
        settings.resetReaderClassicChrome()
        defer { settings.resetReaderClassicChrome() }

        #expect(settings.visibleReaderClassicToolItems == ReaderClassicToolItem.allCases)

        settings.setReaderClassicTool(.nightMode, visible: false)
        #expect(settings.isReaderClassicToolVisible(.nightMode) == false)
        #expect(settings.visibleReaderClassicToolItems.contains(.nightMode) == false)
        #expect(settings.visibleReaderClassicToolItems == [.tableOfContents, .bookmarks, .settings])

        settings.setReaderClassicTool(.nightMode, visible: true)
        #expect(settings.visibleReaderClassicToolItems == ReaderClassicToolItem.allCases)
    }

    @Test("設置 can never be hidden — it is the only way back to reader settings")
    func settingsToolCannotBeHidden() {
        let settings = GlobalSettings.shared
        settings.resetReaderClassicChrome()
        defer { settings.resetReaderClassicChrome() }

        settings.setReaderClassicTool(.settings, visible: false)
        #expect(settings.isReaderClassicToolVisible(.settings))

        // Even a hand-edited store that omits it gets it back.
        #expect(
            GlobalSettings.sanitizedReaderClassicToolVisibleIDs(["bookmarks"])
                == ["bookmarks", "settings"]
        )
    }

    @Test("row order always follows allCases, never persistence order")
    func rowOrderIsStable() {
        #expect(
            GlobalSettings.sanitizedReaderClassicToolVisibleIDs(
                ["settings", "nightMode", "tableOfContents", "bookmarks"]
            ) == ReaderClassicToolItem.allCases.map(\.rawValue)
        )
        // Unknown ids (a tool dropped in a later version) are discarded.
        #expect(
            GlobalSettings.sanitizedReaderClassicToolVisibleIDs(["ghost", "bookmarks"])
                == ["bookmarks", "settings"]
        )
    }

    @Test("深色 is the only entry whose symbol tracks the reading theme")
    func nightModeSymbolTracksTheme() {
        #expect(ReaderClassicToolItem.nightMode.systemImage(isNight: false) == "moon")
        #expect(ReaderClassicToolItem.nightMode.systemImage(isNight: true) == "sun.min")
        for item in ReaderClassicToolItem.allCases where item != .nightMode {
            #expect(item.systemImage(isNight: false) == item.systemImage(isNight: true))
        }
    }

    // MARK: - Reset

    @Test("重設 clears every colour, restores every button, drops every imported icon")
    func resetClearsEverything() throws {
        let settings = GlobalSettings.shared
        settings.resetReaderClassicChrome()
        defer { settings.resetReaderClassicChrome() }

        settings.readerClassicTopBarFillHex = 0x111111
        settings.readerClassicBottomBarIconHex = 0x222222
        settings.readerClassicCircleFillHex = 0x333333
        settings.setReaderClassicTool(.bookmarks, visible: false)
        let asset = try settings.importReaderClassicToolIcon(
            data: try #require(Self.solidImage(.blue).pngData()),
            originalFileName: "test.png",
            item: .tableOfContents
        )
        let importedURL = try #require(settings.readerClassicToolIconURL(for: asset))
        #expect(FileManager.default.fileExists(atPath: importedURL.path))
        #expect(settings.hasReaderClassicChromeOverride)

        settings.resetReaderClassicChrome()

        #expect(settings.hasReaderClassicChromeOverride == false)
        #expect(settings.readerClassicTopBarFillHex == nil)
        #expect(settings.readerClassicBottomBarIconHex == nil)
        #expect(settings.readerClassicCircleFillHex == nil)
        #expect(settings.visibleReaderClassicToolItems == ReaderClassicToolItem.allCases)
        #expect(settings.readerClassicToolIcons.isEmpty)
        // The file goes too — a forgotten asset would leak into the container forever.
        #expect(FileManager.default.fileExists(atPath: importedURL.path) == false)
    }

    @Test("importing a second icon for one button replaces the first")
    func reimportReplacesPreviousAsset() throws {
        let settings = GlobalSettings.shared
        settings.resetReaderClassicChrome()
        defer { settings.resetReaderClassicChrome() }

        let first = try settings.importReaderClassicToolIcon(
            data: try #require(Self.solidImage(.red).pngData()),
            originalFileName: "first.png",
            item: .bookmarks
        )
        let firstURL = try #require(settings.readerClassicToolIconURL(for: first))
        let second = try settings.importReaderClassicToolIcon(
            data: try #require(Self.solidImage(.green).pngData()),
            originalFileName: "second.png",
            item: .bookmarks
        )

        #expect(settings.readerClassicToolIcons.count == 1)
        #expect(settings.readerClassicToolIcon(for: .bookmarks)?.fileName == second.fileName)
        #expect(FileManager.default.fileExists(atPath: firstURL.path) == false)
        #expect(settings.readerClassicToolIconImage(for: .bookmarks) != nil)
    }

    private static func solidImage(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }
}
