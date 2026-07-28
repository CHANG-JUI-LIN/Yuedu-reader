import Foundation
import SwiftUI

enum ExploreNavigationRoute: Hashable {
    case category(UUID)
    case book(OnlineBook)
    case search(String)

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.category(let lhsID), .category(let rhsID)):
            return lhsID == rhsID
        case (.book(let lhsBook), .book(let rhsBook)):
            return lhsBook.id == rhsBook.id
        case (.search(let lhsQuery), .search(let rhsQuery)):
            return lhsQuery == rhsQuery
        default:
            return false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case .category(let sectionID):
            hasher.combine(0)
            hasher.combine(sectionID)
        case .book(let book):
            hasher.combine(1)
            hasher.combine(book.id)
        case .search(let query):
            hasher.combine(2)
            hasher.combine(query)
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
