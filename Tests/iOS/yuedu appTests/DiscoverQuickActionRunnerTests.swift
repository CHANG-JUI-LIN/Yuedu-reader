import Foundation
import Testing
@testable import yuedu_app

/// Explore controls' scripts run on the source's session host: the `infoMap` they share,
/// a `viewName`'s display text, and `java.refreshExplore()` reported back.
@Suite("Explore control scripts", .serialized)
struct DiscoverQuickActionRunnerTests {
    static func source() -> BookSource {
        BookSource(
            bookSourceUrl: "https://explore-actions-\(UUID().uuidString.prefix(8).lowercased()).example",
            bookSourceName: "explore actions"
        )
    }

    @Test("an input's value is in the infoMap the next script reads")
    func infoMapRoundTrip() async {
        let source = Self.source()
        await DiscoverQuickActionRunner.setInfoMapValue("玄幻", forKey: "genre", source: source)

        #expect(await DiscoverQuickActionRunner.infoMapValues(source: source)["genre"] == "玄幻")
        #expect(await DiscoverQuickActionRunner.displayName("infoMap.get('genre')", source: source) == "玄幻")
    }

    @Test("a viewName shows null for nothing and err for a throw, as legado does")
    func displayNameEdgeCases() async {
        let source = Self.source()
        #expect(await DiscoverQuickActionRunner.displayName("''", source: source) == "null")
        #expect(await DiscoverQuickActionRunner.displayName("throw new Error('x')", source: source) == "err")
    }

    @Test("java.refreshExplore() is reported, and the handlers are put back afterwards")
    func refreshIsReported() async {
        let source = Self.source()
        let outcome = await DiscoverQuickActionRunner.run(
            "java.refreshExplore()", title: "刷新", source: source, presentToast: { _ in }
        )
        #expect(outcome.refreshesExplore)
        #expect(outcome.errorMessage == nil)

        let restored = await BookSourceSession.session(for: source).host.run { $0.refreshExploreHandler == nil }
        #expect(restored)
    }
}
