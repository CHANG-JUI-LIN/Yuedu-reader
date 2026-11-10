import Testing
import Foundation
// `Array.move(fromOffsets:toOffset:)`, the reference `CustomItemOrder.moved` must match.
import SwiftUI
@testable import yuedu_app

/// The order resolver behind 底部 Tab (#92) and the reader's 底部工具 (#36). What a saved
/// order means has to survive data from before ordering existed, from a newer build, and
/// from a theme pack.
@Suite("Custom item order")
struct CustomItemOrderTests {
    private let defaults = ["a", "b", "c", "d"]

    private func resolve(_ saved: [String], defaults: [String]? = nil) -> [String] {
        CustomItemOrder.resolve(saved, defaults: defaults ?? self.defaults, id: { $0 })
    }

    @Test("no saved order is the default order")
    func emptyIsDefault() {
        #expect(resolve([]) == defaults)
    }

    @Test("a full saved order is used as saved")
    func fullOrderIsKept() {
        #expect(resolve(["d", "b", "a", "c"]) == ["d", "b", "a", "c"])
    }

    @Test("unknown ids are dropped and a repeated id keeps its first place")
    func unknownAndDuplicateIDs() {
        #expect(resolve(["c", "zzz", "a", "c", "d", "b"]) == ["c", "a", "d", "b"])
    }

    @Test("an item added after the order was saved goes after its default predecessor")
    func newItemInMiddle() {
        // `c` is new: it follows `b`, wherever the reader put `b`.
        #expect(resolve(["d", "b", "a"]) == ["d", "b", "c", "a"])
    }

    @Test("a new first item goes first, a new last item goes after its predecessor")
    func newItemAtEnds() {
        #expect(resolve(["c", "b", "d"]) == ["a", "c", "b", "d"])
        #expect(resolve(["b", "a", "c"]) == ["b", "a", "c", "d"])
        #expect(resolve(["c", "a", "b"]) == ["c", "d", "a", "b"])
    }

    @Test("several new items keep their default order among themselves")
    func severalNewItems() {
        #expect(resolve(["d"]) == ["a", "b", "c", "d"])
        #expect(resolve(["b", "zzz"], defaults: ["a", "b", "c", "d"]) == ["a", "b", "c", "d"])
        #expect(resolve(["c", "a"]) == ["c", "d", "a", "b"])
    }

    @Test("the default order is stored as empty, any other as its ids")
    func storedForm() {
        #expect(CustomItemOrder.stored(defaults, defaults: defaults, id: { $0 }) == [])
        #expect(CustomItemOrder.stored(["b", "a", "c", "d"], defaults: defaults, id: { $0 }) == ["b", "a", "c", "d"])
    }

    @Test("onMove offsets land where List draws them")
    func movedMatchesOnMove() {
        var expected = defaults
        expected.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        #expect(CustomItemOrder.moved(defaults, fromOffsets: IndexSet(integer: 0), toOffset: 3) == expected)
        #expect(expected == ["b", "c", "a", "d"])

        expected = defaults
        expected.move(fromOffsets: IndexSet(integer: 3), toOffset: 0)
        #expect(CustomItemOrder.moved(defaults, fromOffsets: IndexSet(integer: 3), toOffset: 0) == expected)

        expected = defaults
        expected.move(fromOffsets: IndexSet([0, 2]), toOffset: 4)
        #expect(CustomItemOrder.moved(defaults, fromOffsets: IndexSet([0, 2]), toOffset: 4) == expected)
    }

    @Test("上移／下移 swap with the neighbour and stop at the ends")
    func shifted() {
        #expect(CustomItemOrder.shifted(defaults, at: 1, by: -1) == ["b", "a", "c", "d"])
        #expect(CustomItemOrder.shifted(defaults, at: 1, by: 1) == ["a", "c", "b", "d"])
        #expect(CustomItemOrder.shifted(defaults, at: 0, by: -1) == defaults)
        #expect(CustomItemOrder.shifted(defaults, at: 3, by: 1) == defaults)
    }

    // MARK: - Root tabs

    @Test("with no saved order the tab bar is drawn exactly as before ordering existed")
    func rootTabsWithoutOrderMatchOldBehaviour() {
        let lists: [[String]] = [
            GlobalSettings.defaultRootTabVisibleIDs,
            // A list saved before 探索 moved first (2026-10-25), in its old order.
            ["bookshelf", "explore", "search", "settings"],
            ["settings", RootTabItem.library.hiddenMarker, "bookshelf"],
            ["rss", "bookshelf", "settings"],
        ]
        for list in lists {
            let old = GlobalSettings.sanitizedRootTabVisibleIDs(list).compactMap(RootTabItem.init(rawValue:))
            #expect(GlobalSettings.visibleRootTabs(visibleIDs: list, orderIDs: []) == old)
        }
        #expect(GlobalSettings.orderedRootTabs([]) == RootTabItem.tabs)
    }

    @Test("a saved tab order applies to the visible tabs and keeps hidden ones in place")
    func rootTabOrderFiltersHidden() {
        let order = ["search", "settings", "library", "bookshelf", "explore"]
        let visible = ["explore", "bookshelf", "settings", "search", RootTabItem.library.hiddenMarker]
        #expect(GlobalSettings.visibleRootTabs(visibleIDs: visible, orderIDs: order) == [.search, .settings, .bookshelf, .explore])
        #expect(GlobalSettings.orderedRootTabs(order) == [.search, .settings, .library, .bookshelf, .explore])
        // RSS is not a tab any more, so an order naming it drops it rather than drawing it.
        #expect(GlobalSettings.orderedRootTabs(["rss", "search", "explore", "bookshelf", "library", "settings"])
            == [.search, .explore, .bookshelf, .library, .settings])
    }

    // MARK: - Theme data

    @Test("theme extras saved before ordering decode with no order and stay empty")
    func oldExtrasDecodeUnchanged() throws {
        let json = #"{"visibleTabIDs":["bookshelf","settings"],"readerChromeHiddenIDs":["tool.listen"],"tabIconSize":26}"#
        let extras = try JSONDecoder().decode(AppearanceThemeExtras.self, from: Data(json.utf8))
        #expect(extras.tabOrderIDs == nil)
        #expect(extras.readerChromeToolOrderIDs == nil)
        #expect(extras.visibleTabIDs == ["bookshelf", "settings"])
        #expect(extras.readerChromeHiddenIDs == ["tool.listen"])
        #expect(extras.tabIconSize == 26)

        #expect(try JSONDecoder().decode(AppearanceThemeExtras.self, from: Data("{}".utf8)).isEmpty)
    }

    @Test("a theme that only carries an order is not empty, and the order round-trips")
    func orderOnlyThemeIsNotEmpty() throws {
        var extras = AppearanceThemeExtras()
        extras.tabOrderIDs = ["search", "explore"]
        #expect(!extras.isEmpty)
        var tools = AppearanceThemeExtras()
        tools.readerChromeToolOrderIDs = ["tool.listen"]
        #expect(!tools.isEmpty)

        let decoded = try JSONDecoder().decode(AppearanceThemeExtras.self, from: JSONEncoder().encode(extras))
        #expect(decoded.tabOrderIDs == ["search", "explore"])
    }
}

/// The live settings: what a move stores, that it persists, and that the bar and the
/// reader's tools are drawn in it.
@MainActor
@Suite("Custom item order settings", .serialized)
struct CustomItemOrderSettingsTests {
    private struct Saved {
        let tabOrder: [String]
        let tabVisible: [String]
        let toolOrder: [String]
        let toolHidden: [String]

        @MainActor init(_ settings: GlobalSettings) {
            tabOrder = settings.rootTabOrderIDs
            tabVisible = settings.rootTabVisibleIDs
            toolOrder = settings.readerChromeToolOrderIDs
            toolHidden = settings.readerChromeHiddenIDs
        }

        @MainActor func restore(_ settings: GlobalSettings) {
            settings.rootTabOrderIDs = tabOrder
            settings.rootTabVisibleIDs = tabVisible
            settings.readerChromeToolOrderIDs = toolOrder
            settings.readerChromeHiddenIDs = toolHidden
        }
    }

    @Test("moving a tab stores the order, persists it and reorders the bar")
    func moveRootTabPersists() {
        let settings = GlobalSettings.shared
        let saved = Saved(settings)
        defer { saved.restore(settings) }
        settings.rootTabOrderIDs = []
        settings.rootTabVisibleIDs = GlobalSettings.defaultRootTabVisibleIDs

        // 搜尋 (last) dragged to the top.
        settings.moveRootTabs(fromOffsets: IndexSet(integer: 4), toOffset: 0)
        #expect(settings.visibleRootTabs == [.search, .explore, .bookshelf, .library, .settings])
        #expect(UserDefaults.standard.stringArray(forKey: GlobalSettings.rootTabOrderIDsKey)
            == ["search", "explore", "bookshelf", "library", "settings"])
        // Which tabs show is untouched, and still saved in the canonical order.
        #expect(settings.rootTabVisibleIDs == GlobalSettings.defaultRootTabVisibleIDs)

        // Hidden tabs keep their place: hide 書架, show it again, it is back after 探索.
        settings.setRootTab(.bookshelf, visible: false)
        #expect(settings.visibleRootTabs == [.search, .explore, .library, .settings])
        settings.setRootTab(.bookshelf, visible: true)
        #expect(settings.visibleRootTabs == [.search, .explore, .bookshelf, .library, .settings])
        #expect(settings.fallbackRootTab(for: .bookshelf) == .bookshelf)

        // Moving it back by VoiceOver's 下移 to the default stores no order at all.
        for _ in 0..<4 { settings.moveRootTab(.search, by: 1) }
        #expect(settings.rootTabOrderIDs.isEmpty)
        #expect(UserDefaults.standard.stringArray(forKey: GlobalSettings.rootTabOrderIDsKey) == [])
        #expect(settings.visibleRootTabs == RootTabItem.tabs)
    }

    @Test("the reader's tools draw in the saved order and keep a hidden tool's place")
    func readerToolOrder() {
        let settings = GlobalSettings.shared
        let saved = Saved(settings)
        defer { saved.restore(settings) }
        settings.readerChromeToolOrderIDs = []
        settings.readerChromeHiddenIDs = []
        #expect(settings.visibleReaderChromeToolItems == ReaderChromeToolItem.allCases)

        // #36: 聽書 to the front.
        settings.moveReaderChromeTool(.listen, by: -1)
        settings.moveReaderChromeTool(.listen, by: -1)
        #expect(settings.visibleReaderChromeToolItems == [.listen, .tableOfContents, .nightMode, .settings])
        #expect(UserDefaults.standard.stringArray(forKey: GlobalSettings.readerChromeToolOrderIDsKey)
            == ["tool.listen", "tool.tableOfContents", "tool.nightMode", "tool.settings"])
        #expect(settings.hasReaderChromeOverride)

        settings.setReaderChromeItem(ReaderChromeToolItem.tableOfContents, visible: false)
        #expect(settings.visibleReaderChromeToolItems == [.listen, .nightMode, .settings])
        settings.setReaderChromeItem(ReaderChromeToolItem.tableOfContents, visible: true)
        #expect(settings.visibleReaderChromeToolItems == [.listen, .tableOfContents, .nightMode, .settings])

        // A drag: 主題 (last) above 深色.
        settings.moveReaderChromeTools(fromOffsets: IndexSet(integer: 3), toOffset: 2)
        #expect(settings.orderedReaderChromeToolItems == [.listen, .tableOfContents, .settings, .nightMode])

        settings.resetReaderChrome()
        #expect(settings.readerChromeToolOrderIDs.isEmpty)
        #expect(settings.visibleReaderChromeToolItems == ReaderChromeToolItem.allCases)
    }

    @Test("an order saved by a build with a tool this one lacks, or lacking one it has, still draws every tool")
    func readerToolOrderFromAnotherBuild() {
        let settings = GlobalSettings.shared
        let saved = Saved(settings)
        defer { saved.restore(settings) }
        settings.readerChromeHiddenIDs = []

        settings.readerChromeToolOrderIDs = ["tool.bookmarks", "tool.settings", "tool.tableOfContents"]
        #expect(settings.orderedReaderChromeToolItems == [.settings, .tableOfContents, .nightMode, .listen])
    }

    @Test("the theme snapshot carries both orders")
    func snapshotCarriesOrder() {
        let settings = GlobalSettings.shared
        let saved = Saved(settings)
        defer { saved.restore(settings) }

        settings.rootTabOrderIDs = ["search", "explore", "bookshelf", "library", "settings"]
        settings.readerChromeToolOrderIDs = ["tool.listen", "tool.tableOfContents", "tool.nightMode", "tool.settings"]
        let snapshot = settings.currentAppearanceExtrasSnapshot()
        #expect(snapshot.tabOrderIDs == settings.rootTabOrderIDs)
        #expect(snapshot.readerChromeToolOrderIDs == settings.readerChromeToolOrderIDs)
    }
}
