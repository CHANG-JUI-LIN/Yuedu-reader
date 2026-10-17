import Testing
import Foundation
@testable import yuedu_app

@Suite("Root tab customization")
struct RootTabCustomizationTests {
    @Test("settings tab is always restored")
    func settingsTabIsAlwaysRestored() {
        let ids = GlobalSettings.sanitizedRootTabVisibleIDs([
            RootTabItem.bookshelf.rawValue
        ])

        #expect(ids.contains(RootTabItem.bookshelf.rawValue))
        #expect(ids.contains(RootTabItem.settings.rawValue))
    }

    @Test("at least one content tab remains visible")
    func atLeastOneContentTabRemainsVisible() {
        // 資源庫 hidden too: a list naming none of it would show it (`libraryJoinsOldLists`).
        let ids = GlobalSettings.sanitizedRootTabVisibleIDs([
            RootTabItem.settings.rawValue,
            RootTabItem.library.hiddenMarker
        ])

        #expect(ids.contains(RootTabItem.bookshelf.rawValue))
        #expect(ids.contains(RootTabItem.settings.rawValue))
    }

    @Test("unknown tab ids are dropped and order is stable")
    func unknownTabIDsAreDroppedAndOrderIsStable() {
        let ids = GlobalSettings.sanitizedRootTabVisibleIDs([
            "unknown",
            RootTabItem.search.rawValue,
            RootTabItem.library.rawValue,
            RootTabItem.bookshelf.rawValue,
            RootTabItem.settings.rawValue
        ])

        #expect(ids == [
            RootTabItem.bookshelf.rawValue,
            RootTabItem.library.rawValue,
            RootTabItem.settings.rawValue,
            RootTabItem.search.rawValue
        ])
    }

    @Test("the tabs are 書架・探索・資源庫・設定・搜尋 (搜尋 last, 2026-10-16); RSS is no longer one (decision 30)")
    func tabOrder() {
        #expect(RootTabItem.tabs == [.bookshelf, .explore, .library, .settings, .search])
        #expect(GlobalSettings.defaultRootTabVisibleIDs == RootTabItem.tabs.map(\.rawValue))
    }

    @Test("A list saved with 搜尋 before 設定 is drawn in the current order")
    func oldOrderFollowsCurrentOrder() {
        let saved = GlobalSettings.sanitizedRootTabVisibleIDs(["bookshelf", "explore", "library", "search", "settings"])
        #expect(saved == ["bookshelf", "explore", "library", "settings", "search"])
    }

    @Test("A list saved before 資源庫 existed shows it; a shown or hidden RSS tab is dropped")
    func libraryJoinsOldLists() {
        let everything = GlobalSettings.sanitizedRootTabVisibleIDs(["bookshelf", "explore", "rss", "settings", "search"])
        #expect(everything == ["bookshelf", "explore", "library", "settings", "search"])
        let rssHidden = GlobalSettings.sanitizedRootTabVisibleIDs(["bookshelf", "explore", "settings", "search"])
        #expect(rssHidden == ["bookshelf", "explore", "library", "settings", "search"])
    }

    @Test("Hiding 資源庫 is kept: the list remembers it was hidden, not that it never existed")
    @MainActor
    func hidingLibrarySticks() {
        let ids = GlobalSettings.sanitizedRootTabVisibleIDs(
            GlobalSettings.updatedRootTabVisibleIDs(["bookshelf", "explore", "library", "search", "settings"],
                                             setting: .library, visible: false))
        #expect(!ids.contains("library"))
        #expect(GlobalSettings.sanitizedRootTabVisibleIDs(ids) == ids, "stable once hidden")
        let shown = GlobalSettings.sanitizedRootTabVisibleIDs(
            GlobalSettings.updatedRootTabVisibleIDs(ids, setting: .library, visible: true))
        #expect(shown.contains("library"))
    }

    @Test("A custom RSS tab icon stays stored: its tab still decodes")
    func rssIconAssetKept() {
        let asset = RootTabIconAsset(tabID: "rss", slotRawValue: "light", fileName: "rss.png",
                                     originalFileName: "rss.png", addedAt: Date())
        #expect(asset.tab == .rss)
        #expect(!RootTabItem.tabs.contains(.rss))
    }

    @Test("tab icon size is clamped")
    func tabIconSizeIsClamped() {
        #expect(RootTabIconRenderer.sanitizedIconSize(10) == 22)
        #expect(RootTabIconRenderer.sanitizedIconSize(28) == 28)
        #expect(RootTabIconRenderer.sanitizedIconSize(80) == 36)
    }

    @Test("zero tab icon size keeps Apple's system default")
    func zeroTabIconSizeKeepsSystemDefault() {
        #expect(GlobalSettings.sanitizedRootTabIconSize(0) == 0)
        #expect(GlobalSettings.sanitizedRootTabIconSize(-8) == 0)
        #expect(GlobalSettings.sanitizedRootTabIconSize(10) == 22)
    }
}
