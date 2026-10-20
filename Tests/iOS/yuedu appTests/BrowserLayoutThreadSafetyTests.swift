@testable import YueduCoreText
import Testing
import UIKit
@testable import yuedu_app

/// Continuous layout runs off the main thread. What it calls while laying out —
/// the chapter's font resolver and image store — must be safe there.
@Suite(.serialized)
@MainActor
struct BrowserLayoutThreadSafetyTests {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func increment() { lock.withLock { count += 1 } }
    }

    @Test func documentFontResolverResolvesEachTupleOnceAcrossThreads() throws {
        let calls = Counter()
        let resolver = BrowserDocumentFontResolver { @Sendable _, weight, italic, size in
            calls.increment()
            return UIFont.systemFont(ofSize: size + CGFloat(weight) / 1000 + (italic ? 0.5 : 0))
        }
        var built: [([String], Int, Bool, CGFloat)] = []
        for n in 0..<8 {
            let family = "Family\(n % 3)"
            let weight = n % 2 == 0 ? 400 : 700
            built.append(([family], weight, n >= 4, CGFloat(15 + n)))
        }
        let keys = built
        let seen = Locked<[Int: Set<ObjectIdentifier>]>([:])
        DispatchQueue.concurrentPerform(iterations: 64) { iteration in
            for offset in keys.indices {
                let index = (iteration + offset) % keys.count
                let (families, weight, italic, size) = keys[index]
                guard let font = resolver.resolve(families: families, weight: weight, italic: italic, size: size) else { continue }
                seen.withLock { _ = $0[index, default: []].insert(ObjectIdentifier(font)) }
            }
        }
        #expect(calls.value == keys.count, "each tuple resolves exactly once, whichever thread asks first")
        #expect(resolver.resolutionCount == keys.count)
        #expect(resolver.requestCount == 64 * keys.count)
        let fonts = seen.withLock { $0 }
        #expect(fonts.count == keys.count)
        #expect(fonts.values.allSatisfy { $0.count == 1 }, "every thread gets the one resolved font")
    }

    /// The production resolver a chapter's layout receives: it reads the faces
    /// registered for that chapter, so resolving off the main thread gives the
    /// same fonts as resolving on it.
    @Test func chapterFontResolverResolvesOffTheMainThreadLikeOnIt() async throws {
        var entries = EPUBTestFixtures.proseSmoke().entries
        let fontURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Ahem.ttf")
        let package = String(decoding: try #require(entries["OPS/package.opf"]), as: UTF8.self)
        entries["OPS/package.opf"] = Data(package.replacingOccurrences(of: "</manifest>", with:
            "<item id='primary-font' href='Fonts/primary.ttf' media-type='font/ttf'/><item id='fonts-css' href='Styles/fonts.css' media-type='text/css'/></manifest>").utf8)
        entries["OPS/Fonts/primary.ttf"] = try Data(contentsOf: fontURL)
        entries["OPS/Styles/fonts.css"] = Data("""
        @font-face { font-family: BookSubset; src: url('../Fonts/primary.ttf'); }
        p { font-family: BookSubset, TimesNewRomanPSMT; font-size: 24px; }
        """.utf8)
        entries["OPS/chapter1.xhtml"] = Data("""
        <html xmlns="http://www.w3.org/1999/xhtml"><head>
        <link href="Styles/fonts.css" rel="stylesheet" type="text/css"/>
        </head><body><p>AЖ</p></body></html>
        """.utf8)
        let session = try await PublicationSession.open(sourceURL: EPUBTestFixtures.makeArchive(entries: entries))
        let adapter = EPUBBrowserLayoutResourceAdapter(session: session)
        let html = try await adapter.chapterHTML(at: 0)
        // Ingestion only collects the faces; the engine registers the ones the
        // capability scan says the chapter shapes, before it takes the resolver.
        let input = await adapter.cssFrontendInput(forChapter: 0, html: html)
        let scan = BrowserLayoutCapabilityScanner.scan(
            input: input, configuration: BrowserLayoutConfig(renderWidth: 320, renderHeight: 480))
        await adapter.prepareFonts(requests: scan.fontRequests)
        let tuples: [([String], Int, Bool, CGFloat)] = [
            (["BookSubset", "TimesNewRomanPSMT"], 400, false, 24),
            (["BookSubset"], 700, false, 24),
            (["BookSubset"], 400, true, 18),
            (["TimesNewRomanPSMT"], 400, false, 20),
            (["NotInstalledAnywhere"], 400, false, 20),
        ]
        let onMain = try #require(adapter.fontResolver())
        let expected = tuples.map { onMain($0.0, $0.1, $0.2, $0.3).map(Self.describe) }
        #expect(expected[0]?.hasPrefix("Ahem") == true, "the chapter's embedded face resolves: \(String(describing: expected[0]))")
        // A separate resolver, so nothing is served from the main thread's cache.
        let offMain = try #require(adapter.fontResolver())
        let (background, ranOffMain) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let fonts = tuples.map { offMain($0.0, $0.1, $0.2, $0.3).map(Self.describe) }
                continuation.resume(returning: (fonts, !Thread.isMainThread))
            }
        }
        #expect(ranOffMain)
        #expect(background == expected)
    }

    nonisolated private static func describe(_ font: UIFont) -> String {
        let cascade = (font.fontDescriptor.object(forKey: .cascadeList) as? [UIFontDescriptor] ?? [])
            .map(\.postscriptName)
        return "\(font.fontName)@\(font.pointSize)[\(cascade.joined(separator: ","))]"
    }
}
