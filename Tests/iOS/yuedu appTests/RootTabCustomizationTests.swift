import Testing
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
        let ids = GlobalSettings.sanitizedRootTabVisibleIDs([
            RootTabItem.settings.rawValue
        ])

        #expect(ids.contains(RootTabItem.bookshelf.rawValue))
        #expect(ids.contains(RootTabItem.settings.rawValue))
    }

    @Test("unknown tab ids are dropped and order is stable")
    func unknownTabIDsAreDroppedAndOrderIsStable() {
        let ids = GlobalSettings.sanitizedRootTabVisibleIDs([
            "unknown",
            RootTabItem.search.rawValue,
            RootTabItem.rss.rawValue,
            RootTabItem.bookshelf.rawValue,
            RootTabItem.settings.rawValue
        ])

        #expect(ids == [
            RootTabItem.bookshelf.rawValue,
            RootTabItem.rss.rawValue,
            RootTabItem.settings.rawValue,
            RootTabItem.search.rawValue
        ])
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
