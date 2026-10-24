import Testing
import SwiftUI
import UIKit
@testable import yuedu_app

/// 外觀 → 閱讀界面 → 自定義. The palette is the single place a colour falls back to
/// the reading theme, and the hidden-id set is the single place a button can leave
/// the chrome — both are shared by the settings preview and the reader itself, so a
/// break here shows up as the two disagreeing.
@MainActor
@Suite("Reader chrome customization", .serialized)
struct ReaderChromeCustomizationTests {

    // MARK: - Palette

    @Test("no override paints exactly what the reading theme paints")
    func paletteFollowsThemeWithoutOverrides() {
        let settings = GlobalSettings.shared
        Self.resetAll(settings)
        defer { Self.resetAll(settings) }

        let theme = ReaderTheme.sepia
        let palette = ReaderChromePalette(theme: theme, settings: settings)
        #expect(palette.topIcon == theme.textColor)
        #expect(palette.bottomFill == theme.barColor)
        #expect(palette.bottomIcon == theme.textColor)
        #expect(palette.bottomAccent == theme.accentColor)
        #expect(palette.panelFill == theme.barColor)
        #expect(palette.panelText == theme.textColor)
    }

    @Test("colours picked for 現代 before the redesign keep applying; 經典's are dropped")
    func storedModernColoursSurviveTheRedesign() {
        let settings = GlobalSettings.shared
        Self.resetAll(settings)
        defer { Self.resetAll(settings) }

        // What an earlier version (or a theme pack written by one) left in storage.
        settings.readerChromeColors = [
            "modern.bottomFill": 0x00FF00,
            "classic.bottomIcon": 0xFF0000,
        ]

        let palette = ReaderChromePalette(theme: .white, settings: settings)
        #expect(palette.bottomFill == Color(uiColor: AppearanceThemePreset.hex(0x00FF00)))
        #expect(palette.bottomIcon == ReaderTheme.white.textColor)
        #expect(settings.readerChromeColor(slot: .bottomFill) == 0x00FF00)
        #expect(settings.readerChromeColor(slot: .bottomIcon) == nil)
    }

    @Test("picking a colour stores it, nil hands the slot back to the theme")
    func setColourRoundTrips() {
        let settings = GlobalSettings.shared
        Self.resetAll(settings)
        defer { Self.resetAll(settings) }

        settings.setReaderChromeColor(0x123456, slot: .topIcon)
        #expect(settings.readerChromeColor(slot: .topIcon) == 0x123456)
        #expect(settings.hasReaderChromeOverride)

        settings.setReaderChromeColor(nil, slot: .topIcon)
        #expect(settings.readerChromeColor(slot: .topIcon) == nil)
        #expect(settings.readerChromeColors.isEmpty)
        #expect(settings.hasReaderChromeOverride == false)
    }

    @Test("色槽讀回來的值就是畫面上的值")
    func colorForSlotMatchesTheResolvedSurface() {
        let settings = GlobalSettings.shared
        Self.resetAll(settings)
        defer { Self.resetAll(settings) }

        settings.setReaderChromeColor(0xABCDEF, slot: .panelText)
        let palette = ReaderChromePalette(theme: .white, settings: settings)
        #expect(palette.color(for: .panelText) == palette.panelText)
        #expect(palette.color(for: .panelText) == Color(uiColor: AppearanceThemePreset.hex(0xABCDEF)))
        #expect(palette.color(for: .bottomAccent) == palette.bottomAccent)
    }

    // MARK: - Visibility

    @Test("hiding a tool button removes it from the row")
    func hidingToolRemovesItFromTheRow() {
        let settings = GlobalSettings.shared
        Self.resetAll(settings)
        defer { Self.resetAll(settings) }

        #expect(settings.visibleReaderChromeToolItems == ReaderChromeToolItem.allCases)

        settings.setReaderChromeItem(ReaderChromeToolItem.nightMode, visible: false)
        #expect(settings.isReaderChromeItemVisible(ReaderChromeToolItem.nightMode) == false)
        #expect(settings.visibleReaderChromeToolItems == [.tableOfContents, .listen, .settings])

        settings.setReaderChromeItem(ReaderChromeToolItem.nightMode, visible: true)
        #expect(settings.visibleReaderChromeToolItems == ReaderChromeToolItem.allCases)
    }

    @Test("a stored hidden id for the removed 書籤 tool leaves the row whole")
    func hiddenIDOfRemovedToolIsInert() {
        let settings = GlobalSettings.shared
        Self.resetAll(settings)
        defer { Self.resetAll(settings) }

        settings.readerChromeHiddenIDs = ["tool.bookmarks"]
        #expect(settings.visibleReaderChromeToolItems == ReaderChromeToolItem.allCases)
    }

    @Test("主題 can never be hidden — it is the only way back to reader settings")
    func settingsToolCannotBeHidden() {
        let settings = GlobalSettings.shared
        Self.resetAll(settings)
        defer { Self.resetAll(settings) }

        settings.setReaderChromeItem(ReaderChromeToolItem.settings, visible: false)
        #expect(settings.isReaderChromeItemVisible(ReaderChromeToolItem.settings))
        #expect(settings.readerChromeHiddenIDs.isEmpty)
    }

    @Test("hiding an action drops it from the live book-action list")
    func hidingActionFiltersTheLiveList() {
        let settings = GlobalSettings.shared
        Self.resetAll(settings)
        defer { Self.resetAll(settings) }

        let actions = [
            ReaderSecondaryAction(id: .download, icon: "arrow.down.circle", label: "下載", action: {}),
            ReaderSecondaryAction(id: .refresh, icon: "arrow.clockwise", label: "刷新", action: {}),
            ReaderSecondaryAction(id: .sourceLogin, icon: "person.crop.circle", label: "來源配置登入", action: {}),
        ]
        #expect(settings.visibleReaderSecondaryActions(actions).count == 3)

        settings.setReaderChromeItem(ReaderChromeActionItem.refresh, visible: false)
        let visible = settings.visibleReaderSecondaryActions(actions)
        // 來源配置登入 is not a customization item, so nothing here can hide it.
        #expect(visible.map(\.id) == [.download, .sourceLogin])
    }

    @Test("tools and actions never collide in the shared icon store")
    func storageIDsAreNamespaced() {
        let toolIDs = Set(ReaderChromeToolItem.allCases.map(\.storageID))
        let actionIDs = Set(ReaderChromeActionItem.allCases.map(\.storageID))
        #expect(toolIDs.isDisjoint(with: actionIDs))
        #expect(ReaderChromeToolItem.settings.storageID == "tool.settings")
        #expect(ReaderChromeActionItem.refresh.storageID == "action.refresh")
    }

    @Test("深色 is the only entry whose symbol tracks the reading theme")
    func nightModeSymbolTracksTheme() {
        #expect(ReaderChromeToolItem.nightMode.systemImage(isNight: false) == "moon")
        #expect(ReaderChromeToolItem.nightMode.systemImage(isNight: true) == "sun.min")
        for item in ReaderChromeToolItem.allCases where item != .nightMode {
            #expect(item.systemImage(isNight: false) == item.systemImage(isNight: true))
        }
    }

    @Test("every secondary action id but the source's own maps to a customizable item")
    func everySecondaryActionIsCustomizable() {
        #expect(ReaderChromeActionItem(.download) == .download)
        #expect(ReaderChromeActionItem(.changeSource) == .changeSource)
        #expect(ReaderChromeActionItem(.refresh) == .refresh)
        #expect(ReaderChromeActionItem(.aiAssistant) == .aiAssistant)
        #expect(ReaderChromeActionItem(.translation) == .translation)
        #expect(ReaderChromeActionItem(.openWebPage) == .openWebPage)
        #expect(ReaderChromeActionItem(.sourceCustomButton) == nil)
        #expect(ReaderChromeActionItem(.sourceLogin) == nil)
    }

    @Test("only the AI actions sit in 更多; the rest are the book card's")
    func aiActionsAreInMoreMenu() {
        #expect(ReaderChromeActionItem.allCases.filter(\.isInMoreMenu) == [.aiAssistant, .translation])
    }

    // MARK: - Icons & reset

    @Test("重設 clears every colour, restores every button, drops every icon")
    func resetClearsEverything() throws {
        let settings = GlobalSettings.shared
        Self.resetAll(settings)
        defer { Self.resetAll(settings) }

        settings.setReaderChromeColor(0x111111, slot: .topIcon)
        settings.setReaderChromeColor(0x222222, slot: .panelFill)
        settings.setReaderChromeItem(ReaderChromeToolItem.listen, visible: false)
        let asset = try settings.importReaderChromeIcon(
            data: try #require(Self.solidImage(.blue).pngData()),
            originalFileName: "test.png",
            item: ReaderChromeToolItem.tableOfContents
        )
        let importedURL = try #require(settings.readerChromeIconURL(for: asset))
        #expect(FileManager.default.fileExists(atPath: importedURL.path))
        #expect(settings.hasReaderChromeOverride)

        settings.resetReaderChrome()

        #expect(settings.hasReaderChromeOverride == false)
        #expect(settings.readerChromeColors.isEmpty)
        #expect(settings.visibleReaderChromeToolItems == ReaderChromeToolItem.allCases)
        #expect(settings.readerChromeIcons.isEmpty)
        // The file goes too — a forgotten asset would leak into the container forever.
        #expect(FileManager.default.fileExists(atPath: importedURL.path) == false)
    }

    @Test("importing a second icon for one button replaces the first")
    func reimportReplacesPreviousAsset() throws {
        let settings = GlobalSettings.shared
        Self.resetAll(settings)
        defer { Self.resetAll(settings) }

        let first = try settings.importReaderChromeIcon(
            data: try #require(Self.solidImage(.red).pngData()),
            originalFileName: "first.png",
            item: ReaderChromeActionItem.download
        )
        let firstURL = try #require(settings.readerChromeIconURL(for: first))
        let second = try settings.importReaderChromeIcon(
            data: try #require(Self.solidImage(.green).pngData()),
            originalFileName: "second.png",
            item: ReaderChromeActionItem.download
        )

        #expect(settings.readerChromeIcons.count == 1)
        #expect(settings.readerChromeIcon(for: ReaderChromeActionItem.download)?.fileName == second.fileName)
        #expect(FileManager.default.fileExists(atPath: firstURL.path) == false)
        #expect(settings.readerChromeIconImage(for: ReaderChromeActionItem.download) != nil)
    }

    // MARK: - Helpers

    private static func resetAll(_ settings: GlobalSettings) {
        settings.resetReaderChrome()
    }

    private static func solidImage(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }
}
