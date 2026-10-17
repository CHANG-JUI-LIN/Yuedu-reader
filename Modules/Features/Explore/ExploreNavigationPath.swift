import Foundation
import SwiftUI

enum ExploreNavigationRoute: Hashable {
    /// One explore source's discover page.
    case source(sourceURL: String)
    case book(OnlineBook)
    /// A category of any source — from its source's page or a section of the home.
    case sourceCategory(ExploreCategoryReference)
    /// Legado's 搜索 on a source: the search page scoped to that source alone.
    case searchInSource(sourceURL: String)
    /// 書源管理, pushed on every version.
    case sourceManager
    /// 聚合設定, from 探索's ••• (偏好閱讀語言, 參與聚合的來源; Phase 5 plan, decision 36).
    case aggregationSettings
    /// RSS 訂閱, pushed: 資源庫's row and 訂閱的最新文章's 查看全部 (decision 30).
    case subscriptions
    /// A public library's own page (decision 35), opened from 資源庫 (5h).
    case library(SourceInstanceKey)
    /// 資源庫's sources with a discover page: one group's, or all of them (decision 31).
    case sources(group: String?)
    /// An installed module's page (Phase 6e), by its id: the page reads the installed list, so
    /// an update or a removal shows at once.
    case module(id: String)
    /// A module row's 查看全部 (Phase 6f-2), with the section's values frozen in the route.
    case moduleList(ModuleListRoute)
    /// 官方模組's AI 推薦 page (AI 推薦 plan 8d).
    case aiRecommendations
    /// 模組 (M6), from 資源庫's •••: the repositories, 官方模組, 匯入的模組 and 首頁欄目引用.
    case moduleManager
    /// 官方模組 or 匯入的模組, from 模組.
    case moduleGroup(RuleModuleGroup)
    /// A subscribed repository's page, by its address.
    case moduleRepository(URL)
    /// 首頁欄目引用: home sections whose module is not installed.
    case homeModuleReferences

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.source(let lhsURL), .source(let rhsURL)):
            return lhsURL == rhsURL
        case (.book(let lhsBook), .book(let rhsBook)):
            return lhsBook.id == rhsBook.id
        case (.sourceCategory(let lhsReference), .sourceCategory(let rhsReference)):
            return lhsReference == rhsReference
        case (.searchInSource(let lhsURL), .searchInSource(let rhsURL)):
            return lhsURL == rhsURL
        case (.sourceManager, .sourceManager), (.aggregationSettings, .aggregationSettings),
             (.subscriptions, .subscriptions), (.aiRecommendations, .aiRecommendations),
             (.moduleManager, .moduleManager), (.homeModuleReferences, .homeModuleReferences):
            return true
        case (.moduleGroup(let lhsGroup), .moduleGroup(let rhsGroup)):
            return lhsGroup == rhsGroup
        case (.moduleRepository(let lhsURL), .moduleRepository(let rhsURL)):
            return lhsURL == rhsURL
        case (.library(let lhsKey), .library(let rhsKey)):
            return lhsKey == rhsKey
        case (.sources(let lhsGroup), .sources(let rhsGroup)):
            return lhsGroup == rhsGroup
        case (.module(let lhsID), .module(let rhsID)):
            return lhsID == rhsID
        case (.moduleList(let lhsRoute), .moduleList(let rhsRoute)):
            return lhsRoute == rhsRoute
        default:
            return false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case .source(let sourceURL):
            hasher.combine(0)
            hasher.combine(sourceURL)
        case .book(let book):
            hasher.combine(1)
            hasher.combine(book.id)
        case .sourceCategory(let reference):
            hasher.combine(3)
            hasher.combine(reference)
        case .searchInSource(let sourceURL):
            hasher.combine(4)
            hasher.combine(sourceURL)
        case .sourceManager:
            hasher.combine(7)
        case .aggregationSettings:
            hasher.combine(8)
        case .subscriptions:
            hasher.combine(9)
        case .library(let key):
            hasher.combine(10)
            hasher.combine(key)
        case .sources(let group):
            hasher.combine(11)
            hasher.combine(group)
        case .module(let id):
            hasher.combine(12)
            hasher.combine(id)
        case .moduleList(let route):
            hasher.combine(13)
            hasher.combine(route)
        case .aiRecommendations:
            hasher.combine(14)
        case .moduleManager:
            hasher.combine(15)
        case .moduleGroup(let group):
            hasher.combine(16)
            hasher.combine(group)
        case .moduleRepository(let url):
            hasher.combine(17)
            hasher.combine(url)
        case .homeModuleReferences:
            hasher.combine(18)
        }
    }
}

struct ExploreNavigationPath {
    // SearchView itself occupies this path before its result links append
    // SearchResultRoute values. Keep the stack heterogeneous and do not present
    // SearchView through a separate item-driven navigation state.
    var path = NavigationPath()

    mutating func push(_ route: ExploreNavigationRoute) {
        path.append(route)
    }

    mutating func pop() {
        guard !path.isEmpty else { return }
        path.removeLast()
    }
}
