import Foundation

enum ExploreNavigationRoute: Hashable {
    case category(UUID)
    case book(OnlineBook)

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.category(let lhsID), .category(let rhsID)):
            return lhsID == rhsID
        case (.book(let lhsBook), .book(let rhsBook)):
            return lhsBook.id == rhsBook.id
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
        }
    }
}

struct ExploreNavigationPath {
    var path: [ExploreNavigationRoute] = []

    mutating func push(_ route: ExploreNavigationRoute) {
        path.append(route)
    }

    mutating func pop() {
        guard !path.isEmpty else { return }
        path.removeLast()
    }
}
