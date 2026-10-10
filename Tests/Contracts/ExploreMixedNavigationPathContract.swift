import Foundation

// Minimal stand-ins needed to compile ExploreNavigationPath.swift as an isolated contract:
//   xcrun swiftc -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
//     Modules/Features/Explore/ExploreNavigationPath.swift \
//     Tests/Contracts/ExploreMixedNavigationPathContract.swift -o /tmp/contract && /tmp/contract
struct OnlineBook: Hashable {
    let id: UUID
}

struct ExploreCategoryReference: Hashable {
    let sourceURL: String
}

struct SearchResultRoute: Hashable {
    let id: UUID
    let snapshot: String
}

struct OPDSFeedRoute: Hashable {
    let url: String
}

@main
enum ExploreMixedNavigationPathContract {
    static func main() {
        // The scoped search page occupies the path before its result links append
        // SearchResultRoute values; other route types (a feed from the home) mix in too.
        var navigation = ExploreNavigationPath()
        navigation.push(.searchInSource(sourceURL: "https://example.com/source"))
        navigation.path.append(
            SearchResultRoute(
                id: UUID(),
                snapshot: "frozen-search-result"
            )
        )
        navigation.path.append(OPDSFeedRoute(url: "https://example.com/opds"))

        precondition(navigation.path.count == 3)
        navigation.pop()
        precondition(navigation.path.count == 2)
        navigation.pop()
        precondition(navigation.path.count == 1)
        navigation.pop()
        precondition(navigation.path.isEmpty)
        navigation.pop()
        precondition(navigation.path.isEmpty)
    }
}
