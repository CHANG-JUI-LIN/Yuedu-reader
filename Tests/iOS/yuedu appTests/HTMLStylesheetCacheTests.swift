import Foundation
import Testing
@testable import yuedu_app

/// Guards the fix for a SIGSEGV a real device reported from inside
/// `HTMLStylesheetCache.parsedStylesheet`.
///
/// One cache instance is shared by every chapter of a book, and adjacent chapters
/// preload concurrently through a nonisolated `async` path, so the dictionary is
/// reached from more than one thread. Unsynchronised, a resize under a concurrent
/// read crashes.
@Suite("HTMLStylesheetCache")
struct HTMLStylesheetCacheTests {

    private let css = """
    p { font-size: 1em; margin: 0 0 1em 0; }
    h1 { font-size: 2em; font-weight: bold; }
    .verse { text-indent: 2em; }
    p:first-letter { font-size: 3em; }
    """

    @Test("the same key always resolves to one shared instance")
    func sameKeyIsShared() {
        let cache = HTMLStylesheetCache()
        let a = cache.parsedStylesheet(css: css, orderOffset: 0)
        let b = cache.parsedStylesheet(css: css, orderOffset: 0)
        #expect(a === b)
    }

    @Test("orderOffset is part of the key")
    func orderOffsetSeparatesEntries() {
        let cache = HTMLStylesheetCache()
        let a = cache.parsedStylesheet(css: css, orderOffset: 0)
        let b = cache.parsedStylesheet(css: css, orderOffset: 100)
        #expect(a !== b)
    }

    /// Not a CSS-parser test — it only confirms the cache hands back a real parse
    /// rather than an empty shell, so the identity assertions below mean something.
    ///
    /// Note the single-colon `:first-letter`: `CSSParser` matches on that suffix and
    /// then strips it, so the CSS3 `p::first-letter` form leaves `p:` behind,
    /// `parseSelector` rejects it, and the rule is dropped entirely. That is a real
    /// gap, but it belongs to the parser, not here.
    @Test("parsing actually produced rules")
    func parsingProducesRules() {
        let cache = HTMLStylesheetCache()
        let parsed = cache.parsedStylesheet(css: css, orderOffset: 0)
        #expect(!parsed.regularRules.isEmpty)
        #expect(!parsed.firstLetterRules.isEmpty)
    }

    /// The regression test. Concurrent callers for one key must all come back with the
    /// *same* instance — that is only true if the check-and-insert is serialised. It
    /// also exercises the dictionary hard enough to trip an unsynchronised resize.
    @Test("concurrent callers for one key share a single instance")
    func concurrentSameKeyIsRaceFree() async {
        let cache = HTMLStylesheetCache()

        let results: [ObjectIdentifier] = await withTaskGroup(
            of: ObjectIdentifier.self, returning: [ObjectIdentifier].self
        ) { group in
            for _ in 0..<64 {
                group.addTask {
                    ObjectIdentifier(cache.parsedStylesheet(css: self.css, orderOffset: 0))
                }
            }
            var seen: [ObjectIdentifier] = []
            for await id in group { seen.append(id) }
            return seen
        }

        #expect(results.count == 64)
        #expect(Set(results).count == 1, "every caller should share one parsed stylesheet")
    }

    /// Many distinct keys at once: this is the shape that actually crashed — a resize
    /// while another thread reads.
    @Test("concurrent distinct keys all survive and stay retrievable")
    func concurrentDistinctKeysAreRaceFree() async {
        let cache = HTMLStylesheetCache()
        let keyCount = 128

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<keyCount {
                group.addTask {
                    _ = cache.parsedStylesheet(css: ".c\(index) { color: red; }", orderOffset: index)
                }
                // Interleave repeats of an existing key so reads and writes overlap.
                group.addTask {
                    _ = cache.parsedStylesheet(css: self.css, orderOffset: 0)
                }
            }
            await group.waitForAll()
        }

        // Everything written is still there and still one instance per key.
        for index in 0..<keyCount {
            let first = cache.parsedStylesheet(css: ".c\(index) { color: red; }", orderOffset: index)
            let second = cache.parsedStylesheet(css: ".c\(index) { color: red; }", orderOffset: index)
            #expect(first === second)
        }
    }
}
