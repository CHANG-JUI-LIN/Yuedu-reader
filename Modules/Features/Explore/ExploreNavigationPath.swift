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
             (.subscriptions, .subscriptions):
            return true
        case (.library(let lhsKey), .library(let rhsKey)):
            return lhsKey == rhsKey
        case (.sources(let lhsGroup), .sources(let rhsGroup)):
            return lhsGroup == rhsGroup
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
