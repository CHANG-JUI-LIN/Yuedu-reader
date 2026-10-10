import Foundation
import Testing
@testable import yuedu_app

/// Characterization tests (unified library, Phase 0a) for the discover category cache.
///
/// `DiscoverKindsCache` has only `shared`, in the app's real Caches directory. Entries use
/// fixed keys under `phase0-kinds.test`, so a rerun overwrites them. `removeAll()` would
/// wipe the real cache and is never called here.
@Suite("Discover kinds cache (characterization)", .serialized)
struct DiscoverKindsCacheTests {
    @Test("the key is a stable 32-character hex digest of its three inputs")
    func keyIsStable() {
        let key = DiscoverKindsCache.key(sourceUrl: "https://phase0-kinds.test/a", exploreUrl: "e", variableJSON: "{}")

        #expect(key == DiscoverKindsCache.key(sourceUrl: "https://phase0-kinds.test/a", exploreUrl: "e", variableJSON: "{}"))
        #expect(key.count == 32)
        #expect(key.allSatisfy { $0.isHexDigit })
    }

    @Test("changing any input changes the key")
    func everyInputCounts() {
        let base = DiscoverKindsCache.key(sourceUrl: "https://phase0-kinds.test/a", exploreUrl: "e", variableJSON: "{}")

        #expect(base != DiscoverKindsCache.key(sourceUrl: "https://phase0-kinds.test/b", exploreUrl: "e", variableJSON: "{}"))
        #expect(base != DiscoverKindsCache.key(sourceUrl: "https://phase0-kinds.test/a", exploreUrl: "f", variableJSON: "{}"))
        #expect(base != DiscoverKindsCache.key(sourceUrl: "https://phase0-kinds.test/a", exploreUrl: "e", variableJSON: "{\"k\":1}"))
    }

    @Test("no variable and an empty variable give the same key")
    func nilAndEmptyVariableMatch() {
        // Current behavior: both feed an empty string into the digest.
        #expect(
            DiscoverKindsCache.key(sourceUrl: "https://phase0-kinds.test/a", exploreUrl: "e", variableJSON: nil)
                == DiscoverKindsCache.key(sourceUrl: "https://phase0-kinds.test/a", exploreUrl: "e", variableJSON: "")
        )
    }

    @Test("a separator moved between inputs gives the same key")
    func separatorIsAmbiguous() {
        // Current behavior: inputs are joined with "|" without escaping, so these collide.
        #expect(
            DiscoverKindsCache.key(sourceUrl: "a|b", exploreUrl: "c", variableJSON: nil)
                == DiscoverKindsCache.key(sourceUrl: "a", exploreUrl: "b|c", variableJSON: nil)
        )
    }

    @Test("stored items read back in order, and a later store replaces them")
    func storeRoundTripsAndReplaces() {
        let cache = DiscoverKindsCache.shared
        let key = DiscoverKindsCache.key(sourceUrl: "https://phase0-kinds.test/round-trip", exploreUrl: "e", variableJSON: nil)
        let first: [ModernParserBridge.DiscoverItem] = [
            .init(title: "熱門", url: "https://phase0-kinds.test/hot"),
            .init(title: "篩選", type: "select", chars: ["全部", "完結"], default: "全部"),
        ]

        cache.store(first, forKey: key)
        let read = cache.items(forKey: key)
        #expect(read?.map(\.title) == ["熱門", "篩選"])
        #expect(read?.last?.type == "select")
        #expect(read?.last?.chars == ["全部", "完結"])

        cache.store([.init(title: "新書", url: "https://phase0-kinds.test/new")], forKey: key)
        #expect(cache.items(forKey: key)?.map(\.title) == ["新書"])
    }

    @Test("storing an empty list writes nothing")
    func emptyListIsNotStored() {
        let key = DiscoverKindsCache.key(sourceUrl: "https://phase0-kinds.test/never-stored", exploreUrl: "e", variableJSON: nil)

        DiscoverKindsCache.shared.store([], forKey: key)

        #expect(DiscoverKindsCache.shared.items(forKey: key) == nil)
    }

    @Test("storing an empty list keeps what was there")
    func emptyListKeepsTheOldEntry() {
        let key = DiscoverKindsCache.key(sourceUrl: "https://phase0-kinds.test/keeps-old", exploreUrl: "e", variableJSON: nil)
        DiscoverKindsCache.shared.store([.init(title: "熱門", url: "https://phase0-kinds.test/hot")], forKey: key)

        DiscoverKindsCache.shared.store([], forKey: key)

        #expect(DiscoverKindsCache.shared.items(forKey: key)?.map(\.title) == ["熱門"])
    }
}
