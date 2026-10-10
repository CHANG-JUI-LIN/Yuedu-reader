import Foundation
import SwiftUI

enum ExploreNavigationRoute: Hashable {
    /// One explore source's discover page.
    case source(sourceURL: String)
    /// One of the reader's custom explore pages.
    case customPage(id: UUID)
    /// A custom page's blocks, changed, reordered and deleted.
    case customPageEditor(id: UUID)
    case book(OnlineBook)
    /// A category of any source — from its source's page or a custom page.
    case sourceCategory(ExploreCategoryReference)
    /// Legado's 搜索 on a source: the search page scoped to that source alone.
    case searchInSource(sourceURL: String)
    /// 書源管理, pushed on every version.
    case sourceManager

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.source(let lhsURL), .source(let rhsURL)):
            return lhsURL == rhsURL
        case (.customPage(let lhsID), .customPage(let rhsID)),
             (.customPageEditor(let lhsID), .customPageEditor(let rhsID)):
            return lhsID == rhsID
        case (.book(let lhsBook), .book(let rhsBook)):
            return lhsBook.id == rhsBook.id
        case (.sourceCategory(let lhsReference), .sourceCategory(let rhsReference)):
            return lhsReference == rhsReference
        case (.searchInSource(let lhsURL), .searchInSource(let rhsURL)):
            return lhsURL == rhsURL
        case (.sourceManager, .sourceManager):
            return true
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
        case .customPage(let id):
            hasher.combine(5)
            hasher.combine(id)
        case .customPageEditor(let id):
            hasher.combine(6)
            hasher.combine(id)
        case .sourceManager:
            hasher.combine(7)
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
