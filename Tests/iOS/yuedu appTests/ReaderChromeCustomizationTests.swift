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

    // MARK: - Slots per interface

    @Test("each interface only exposes the surfaces it actually paints")
    func slotsAreScopedToTheInterface() {
        let classic = ReaderChromeSlot.slots(for: .classic)
        let modern = ReaderChromeSlot.slots(for: .modern)

        // 現代's navigation bar is system glass with the background hidden.
        #expect(classic.contains(.topFill))
        #expect(modern.contains(.topFill) == false)
        // Only 經典 floats circles over the page.
        #expect(classic.contains(.circleFill))
        #expect(modern.contains(.circleFill) == false)
        // Only 現代 has the book card behind the cover.
        #expect(modern.contains(.panelFill))
        #expect(classic.contains(.panelFill) == false)
        // Both bottom bars are ours to paint.
        for slot in [ReaderChromeSlot.bottomFill, .bottomIcon, .bottomAccent, .topIcon] {
            #expect(classic.contains(slot))
            #expect(modern.contains(slot))
        }
    }

    // MARK: - Palette

    @Test("no override paints exactly what the reading theme paints")
    func paletteFollowsThemeWithoutOverrides() {
        let settings = GlobalSettings.shared
        Self.resetAll(settings)
        defer { Self.resetAll(settings) }

        let theme = ReaderTheme.sepia
        for interface in ReaderChromeInterface.allCases {
            let palette = ReaderChromePalette(interface: interface, theme: theme, settings: settings)
            #expect(palette.topFill == theme.barColor)
            #expect(palette.topIcon == theme.textColor)
            #expect(palette.bottomFill == theme.barColor)
            #expect(palette.bottomIcon == theme.textColor)
            #expect(palette.bottomAccent == theme.accentColor)
            #expect(palette.panelFill == theme.barColor)
            #expect(palette.panelText == theme.textColor)
            #expect(palette.circleFill == theme.barColor)
            // The circles alone soften the theme's body-text colour into chrome.
            #expect(palette.circleIcon == theme.textColor.opacity(0.9))
            #expect(palette.circleBorder == theme.textColor.opacity(0.35))
        }
    }

    @Test("經典 and 現代 keep separate colours for the same slot")
    func coloursDoNotLeakBetweenInterfaces() {
        let settings = GlobalSettings.shared
        Self.resetAll(settings)
        defer { Self.resetAll(settings) }

        settings.setReaderChromeColor(0xFF0000, interface: .classic, slot: .bottomFill)
        settings.setReaderChromeColor(0x00FF00, interface: .modern, slot: .bottomFill)

        let classic = ReaderChromePalette(interface: .classic, theme: .white, settings: settings)
        let modern = ReaderChromePalette(interface: .modern, theme: .white, settings: settings)
        #expect(classic.bottomFill == Color(uiColor: AppearanceThemePreset.hex(0xFF0000)))
        #expect(modern.bottomFill == Color(uiColor: AppearanceThemePreset.hex(0x00FF00)))
    }

    @Test("a slot the interface does not expose is ignored even if stored")
    func inapplicableSlotIsIgnored() {
        let settings = GlobalSettings.shared
        Self.resetAll(settings)
        defer { Self.resetAll(settings) }

        // 現代 has no top fill; a stored value must not repaint its glass bar.
        settings.setReaderChromeColor(0xFF0000, interface: .modern, slot: .topFill)
        let modern = ReaderChromePalette(interface: .modern, theme: .white, settings: settings)
        #expect(modern.topFill == ReaderTheme.white.barColor)
    }

    @Test("a hand-picked circle symbol colour is used exactly as picked")
    func pickedCircleIconIsNotFaded() {
        let settings = GlobalSettings.shared
        Self.resetAll(settings)
        defer { Self.resetAll(settings) }

        settings.setReaderChromeColor(0x123456, interface: .classic, slot: .circleIcon)
        let picked = Color(uiColor: AppearanceThemePreset.hex(0x123456))
        let palette = ReaderChromePalette(interface: .classic, theme: .night, settings: settings)

        #expect(palette.circleIcon == picked)
        #expect(palette.circleBorder == picked.opacity(0.35))
    }

    @Test("色槽讀回來的值就是畫面上的值")
    func colorForSlotMatchesTheResolvedSurface() {
        let settings = GlobalSettings.shared
        Self.resetAll(settings)
        defer { Self.resetAll(settings) }

        settings.setReaderChromeColor(0xABCDEF, interface: .modern, slot: .panelText)
        let palette = ReaderChromePalette(interface: .modern, theme: .white, settings: settings)
        #expect(palette.color(for: .panelText) == palette.panelText)
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
        #expect(settings.visibleReaderChromeToolItems == [.tableOfContents, .bookmarks, .settings])

        settings.setReaderChromeItem(ReaderChromeToolItem.nightMode, visible: true)
        #expect(settings.visibleReaderChromeToolItems == ReaderChromeToolItem.allCases)
    }

    @Test("設置 can never be hidden — it is the only way back to reader settings")
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
            ReaderSecondaryAction(id: .playback, icon: "headphones", label: "聽書", action: {}),
            ReaderSecondaryAction(id: .refresh, icon: "arrow.clockwise", label: "刷新", action: {}),
        ]
        #expect(settings.visibleReaderSecondaryActions(actions).count == 2)

        settings.setReaderChromeItem(ReaderChromeActionItem.refresh, visible: false)
        let visible = settings.visibleReaderSecondaryActions(actions)
        #expect(visible.map(\.id) == [.playback])
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

    @Test("every secondary action id maps to a customizable item")
    func everySecondaryActionIsCustomizable() {
        #expect(ReaderChromeActionItem(.playback) == .playback)
        #expect(ReaderChromeActionItem(.download) == .download)
        #expect(ReaderChromeActionItem(.changeSource) == .changeSource)
        #expect(ReaderChromeActionItem(.refresh) == .refresh)
    }

    // MARK: - Icons & reset

    @Test("重設 clears this interface's colours, restores every button, drops every icon")
    func resetClearsEverything() throws {
        let settings = GlobalSettings.shared
        Self.resetAll(settings)
        defer { Self.resetAll(settings) }

        settings.setReaderChromeColor(0x111111, interface: .classic, slot: .topFill)
        settings.setReaderChromeColor(0x222222, interface: .modern, slot: .panelFill)
        settings.setReaderChromeItem(ReaderChromeToolItem.bookmarks, visible: false)
        let asset = try settings.importReaderChromeIcon(
            data: try #require(Self.solidImage(.blue).pngData()),
            originalFileName: "test.png",
            item: ReaderChromeToolItem.tableOfContents
        )
        let importedURL = try #require(settings.readerChromeIconURL(for: asset))
        #expect(FileManager.default.fileExists(atPath: importedURL.path))
        #expect(settings.hasReaderChromeOverride(interface: .classic))

        settings.resetReaderChrome(interface: .classic)

        #expect(settings.hasReaderChromeOverride(interface: .classic) == false)
        #expect(settings.readerChromeColor(interface: .classic, slot: .topFill) == nil)
        #expect(settings.visibleReaderChromeToolItems == ReaderChromeToolItem.allCases)
        #expect(settings.readerChromeIcons.isEmpty)
        // The file goes too — a forgotten asset would leak into the container forever.
        #expect(FileManager.default.fileExists(atPath: importedURL.path) == false)
        // The other interface's colours are not this button's business.
        #expect(settings.readerChromeColor(interface: .modern, slot: .panelFill) == 0x222222)
    }

    @Test("importing a second icon for one button replaces the first")
    func reimportReplacesPreviousAsset() throws {
        let settings = GlobalSettings.shared
        Self.resetAll(settings)
        defer { Self.resetAll(settings) }

        let first = try settings.importReaderChromeIcon(
            data: try #require(Self.solidImage(.red).pngData()),
            originalFileName: "first.png",
            item: ReaderChromeActionItem.playback
        )
        let firstURL = try #require(settings.readerChromeIconURL(for: first))
        let second = try settings.importReaderChromeIcon(
            data: try #require(Self.solidImage(.green).pngData()),
            originalFileName: "second.png",
            item: ReaderChromeActionItem.playback
        )

        #expect(settings.readerChromeIcons.count == 1)
        #expect(settings.readerChromeIcon(for: ReaderChromeActionItem.playback)?.fileName == second.fileName)
        #expect(FileManager.default.fileExists(atPath: firstURL.path) == false)
        #expect(settings.readerChromeIconImage(for: ReaderChromeActionItem.playback) != nil)
    }

    // MARK: - Helpers

    private static func resetAll(_ settings: GlobalSettings) {
        for interface in ReaderChromeInterface.allCases {
            settings.resetReaderChrome(interface: interface)
        }
    }

    private static func solidImage(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }
}
