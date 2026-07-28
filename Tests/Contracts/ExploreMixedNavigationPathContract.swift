import Foundation

// Minimal stand-in needed to compile ExploreNavigationPath.swift as an isolated contract.
struct OnlineBook: Hashable {
    let id: UUID
}

@main
enum ExploreMixedNavigationPathContract {
    static func main() {
        var navigation = ExploreNavigationPath()
        navigation.push(ExploreNavigationRoute.category(UUID()))
        navigation.path.append(
            SearchResultRoute(
                id: UUID(),
                snapshot: "frozen-search-result"
            )
        )

        precondition(navigation.path.count == 2)
        navigation.pop()
        precondition(navigation.path.count == 1)
    }
}
