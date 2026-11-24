import Testing
import Foundation
import SwiftUI
@testable import yuedu_app

/// 頁面背景 › 編輯範圍 lists the tab bar (FB-250: it still offered RSS 訂閱 and had no
/// 資源庫), and a background saved under the retired `rss` key keeps showing.
@Suite("Page background scopes")
struct AppearancePageBackgroundScopeTests {
    @Test("the default tab order gives 全局默認 then the drawn tabs")
    func defaultOrder() {
        let scopes = AppearancePageBackgroundScope.editorScopes(
            tabOrder: GlobalSettings.orderedRootTabs([])
        )
        #expect(scopes == [.global, .explore, .bookshelf, .library, .settings, .search])
    }

    @Test("a rearranged tab bar is followed, and rss is never listed")
    func customOrder() {
        let scopes = AppearancePageBackgroundScope.editorScopes(
            tabOrder: GlobalSettings.orderedRootTabs(["rss", "search", "library", "bookshelf", "settings", "explore"])
        )
        #expect(scopes == [.global, .search, .library, .bookshelf, .settings, .explore])
        #expect(!scopes.contains(.rss))
    }

    @Test("every drawn tab has a scope")
    func everyTabHasAScope() {
        for tab in RootTabItem.tabs {
            #expect(AppearancePageBackgroundScope(rawValue: tab.rawValue) != nil, "\(tab)")
        }
    }

    private func config(_ file: String) -> AppearancePageBackgroundConfig {
        var config = AppearancePageBackgroundConfig()
        config.lightPrimaryHex = 0x112233
        config.lightImageFileName = file
        return config
    }

    @Test("a saved rss background moves to 資源庫 with the same image")
    func rssMovesToLibrary() {
        let saved = ["rss": config("pagebg-rss.png"), "explore": config("pagebg-explore.png")]
        let migrated = AppearancePageBackgroundScope.migratingLegacyKeys(saved)
        #expect(migrated["rss"] == nil)
        #expect(migrated["library"] == saved["rss"])
        #expect(migrated["explore"] == saved["explore"])
        let slice = migrated[AppearancePageBackgroundScope.library.rawValue]?.slice(for: .light)
        #expect(slice?.imageFileName == "pagebg-rss.png")
        #expect(slice?.primaryHex == 0x112233)
    }

    @Test("a background already set on 資源庫 is kept over the legacy one")
    func libraryWins() {
        let saved = ["rss": config("pagebg-rss.png"), "library": config("pagebg-library.png")]
        #expect(AppearancePageBackgroundScope.migratingLegacyKeys(saved) == saved)
    }

    @Test("nothing to migrate leaves the dictionary as it was")
    func noLegacyKey() {
        let saved = ["global": config("pagebg-global.png")]
        #expect(AppearancePageBackgroundScope.migratingLegacyKeys(saved) == saved)
    }
}
