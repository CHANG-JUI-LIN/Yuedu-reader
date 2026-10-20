import Foundation
import Testing
@testable import yuedu_app

/// MetricKit cpu-exception d32f7c57 (≤2.0.7), cluster B2: `ChapterFetcher.extractLocalHTMLContent`,
/// the known-container heuristic a page falls to when its source has no usable content rule and
/// `WebNovelParser` finds only collapsed text. Times it on the Narou episode at 1×/4×/16× its body.
/// No network, no WebView.
///
/// The timings are reported, not asserted (Debug build: compare ratios, not milliseconds). Measured
/// 2026-10-20 while every selector reparsed the page: 1036 / 2487 / 7921 ms on the full episode.
@MainActor
@Suite("Chapter local content selectors", .serialized)
struct ChapterLocalSelectorsTests {
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/Narou")
    nonisolated private static let pageURL = "https://ncode.syosetu.com/n9669bk/1/"

    private struct Inputs {
        let page: String
        let paragraphs: [String]

        /// The episode as Narou serves it, body scaled.
        func fullPage(_ scale: Int) -> String {
            let body = Array(repeating: paragraphs.joined(separator: "\n"), count: scale).joined(separator: "\n")
            return page.replacingOccurrences(of: paragraphs.joined(separator: "\n"), with: body)
        }

        /// The episode with its whole body run into one line in a `#content` container, as a site
        /// that drops its line breaks serves it: `WebNovelParser` then finds one collapsed line,
        /// which sends `extractWebContentSinglePage` to the known-container heuristic. (Narou's own
        /// markup is no good here: the parser finds only "目次", which goes to the WebView.)
        func collapsedPage(_ scale: Int) -> String {
            // Every tag goes, the blank lines' `<br />` included: one `<br>` is a line break.
            let text = paragraphs.map {
                $0.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            }.joined()
            let body = "<div id=\"content\">" + String(repeating: text, count: scale) + "</div>"
            return page.replacingOccurrences(of: paragraphs.joined(separator: "\n"), with: body)
        }
    }

    private func loadInputs() throws -> Inputs {
        let page = try String(contentsOf: Self.fixtures.appendingPathComponent("narou-episode.html"), encoding: .utf8)
        let regex = try NSRegularExpression(pattern: #"<p id="L\d+">.*?</p>"#)
        let ns = page as NSString
        let paragraphs = regex.matches(in: page, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
        try #require(paragraphs.count > 200)
        try #require(page.contains(paragraphs.joined(separator: "\n")), "the pages scale the contiguous body")
        return Inputs(page: page, paragraphs: paragraphs)
    }

    /// Median of `runs` wall-clock timings, in milliseconds.
    private func time(runs: Int = 3, _ work: () async throws -> Void) async rethrows -> Double {
        var samples: [Double] = []
        for _ in 0..<runs {
            let start = ContinuousClock.now
            try await work()
            let elapsed = ContinuousClock.now - start
            samples.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
        }
        return samples.sorted()[samples.count / 2]
    }

    private func report(_ stage: String, _ timings: [(Int, Double, Int)]) {
        let cells = timings.map { scale, ms, bytes in
            "\(scale)x=\(String(format: "%.1f", ms))ms(\(bytes / 1024)KB)"
        }.joined(separator: " ")
        let growth = timings.count > 1 && timings[0].1 > 0
            ? String(format: " %dx/1x=%.1f", timings[timings.count - 1].0, timings[timings.count - 1].1 / timings[0].1) : ""
        print("CARD5-LOCAL \(stage): \(cells)\(growth)")
    }

    @Test("a collapsed page reaches the known-container heuristic, not the WebView")
    func collapsedPageReachesLocalSelectors() async throws {
        let page = try loadInputs().collapsedPage(1)
        let parsed = WebNovelParser.extractContent(html: page, pageURL: Self.pageURL)
        try #require(ReaderHTMLUtilities.isLikelyCollapsedChapterText(parsed), "parser output: \(parsed.prefix(200))")
        let local = ChapterFetcher.extractLocalHTMLContent(html: page, pageURL: Self.pageURL)
        try #require(local.count >= 80)
        let extracted = await ChapterFetcher.shared.extractWebContentSinglePage(html: page, pageURL: Self.pageURL)
        #expect(extracted == local)
    }

    @Test("the known-container heuristic, at three body sizes")
    func localSelectorTimings() async throws {
        let inputs = try loadInputs()
        var stages: [(String, [(Int, Double, Int)])] = [
            "localSelectors(page)", "localSelectors(collapsed)", "extractWebContentSinglePage(collapsed)",
            "WebNovelParser.extractContent(collapsed)", "parseHTML once(collapsed)",
            "reference: 29 reparses(page)", "reference: 29 reparses(collapsed)",
        ].map { ($0, []) }
        func add(_ index: Int, _ scale: Int, _ ms: Double, _ size: Int) { stages[index].1.append((scale, ms, size)) }

        for scale in [1, 4, 16] {
            let page = inputs.fullPage(scale)
            let collapsed = inputs.collapsedPage(scale)
            add(0, scale, await time {
                _ = ChapterFetcher.extractLocalHTMLContent(html: page, pageURL: Self.pageURL)
            }, page.utf8.count)
            add(1, scale, await time {
                _ = ChapterFetcher.extractLocalHTMLContent(html: collapsed, pageURL: Self.pageURL)
            }, collapsed.utf8.count)
            add(2, scale, await time {
                _ = await ChapterFetcher.shared.extractWebContentSinglePage(html: collapsed, pageURL: Self.pageURL)
            }, collapsed.utf8.count)
            add(3, scale, await time {
                _ = WebNovelParser.extractContent(html: collapsed, pageURL: Self.pageURL)
            }, collapsed.utf8.count)
            add(4, scale, await time { _ = parseHTML(collapsed) }, collapsed.utf8.count)
            add(5, scale, await time { _ = Self.reference(page) }, page.utf8.count)
            add(6, scale, await time { _ = Self.reference(collapsed) }, collapsed.utf8.count)
        }
        for (stage, timings) in stages { report(stage, timings) }
    }
    // MARK: - Equivalence with one parse per selector

    /// The heuristic as it was before it parsed the page once: every selector through
    /// `RuleEngine.extractValue(fromHTML:)`, which parses the page itself.
    nonisolated private static func reference(_ html: String) -> String {
        var best = ""
        for selector in ChapterFetcher.knownContentSelectors {
            let selectorHTML = RuleEngine.extractValue(fromHTML: html, rule: selector + "@html", baseURL: pageURL)
            let trimmed = ChapterFetcher.stripHtmlToText(selectorHTML).trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count > best.count { best = trimmed }
        }
        if best.count >= 80 { return best }
        return ChapterFetcher.stripHtmlToText(html).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// An element tree with each element's attributes sorted. `buildOuterHTML` writes attributes
    /// in `[String: String]` order, which differs between two parses of one page, so two outer
    /// HTMLs of the same element can differ in attribute order and nothing else.
    nonisolated private static func canonical(_ html: String) -> String {
        func dump(_ node: HTMLNode) -> String {
            if node.tag == "#text" { return node.rawText }
            let attrs = node.attrs.sorted { $0.key < $1.key }.map { " \($0.key)=\"\($0.value)\"" }.joined()
            return "<\(node.tag)\(attrs)>" + node.children.map(dump).joined() + "</\(node.tag)>"
        }
        let document = parseHTML(html)
        return dump(document)
    }

    nonisolated private static let sentences = [
        "清晨的霧氣還沒有散去，他推開客棧的木門，看見街上已經有人在叫賣熱騰騰的包子與豆漿。",
        "「你終於來了。」老人頭也不抬地說，手裡的茶壺冒著白煙，彷彿早就知道他會在這個時候出現。",
        "他沒有回答，只是把那封信放在桌上；信封上的火漆印早已裂開，露出裡面泛黃的紙頁。",
        "窗外傳來一陣急促的馬蹄聲，緊接著是幾聲呼喝！兩人對望一眼，都沒有說話？",
    ]

    /// Pages built so that several selectors match: nested containers, one element matched by
    /// three selectors, a tie, the JSOUP Default `article` route, every selector at once, a best
    /// match too short to use, and none at all.
    nonisolated private static func corpus() -> [(name: String, html: String, minHits: Int)] {
        let s = sentences
        let nested = """
        <html><head><title>第一章 開端</title><style>.x{color:red}</style><script>var ad = "廣告";</script></head><body>
        <div class="nav"><a href="/">首頁</a> &gt; <a href="/b/1/">書名</a></div>
        <div id="chaptercontent">本章導讀：短短一句。</div>
        <div id="content" class="content txt"><h1>第一章 開端</h1><div class="read-content"><p>\(s[0])</p><p>\(s[1]) &amp; 甲&nbsp;乙</p><script>document.write("廣告")</script><br>\(s[2])</div><div class="txtnav">下一頁</div></div>
        <article><p>\(s[3])</p><p>\(s[0])</p></article>
        </body></html>
        """
        let tie = """
        <html><body><div id="chapter-content">\(String(repeating: "甲", count: 100))。</div>\
        <div class="chapter-content">\(String(repeating: "乙", count: 100))。</div></body></html>
        """
        let every = "<html><body>" + ChapterFetcher.knownContentSelectors.enumerated().map { index, selector in
            let text = String(repeating: s[index % s.count], count: 1 + (index * 7) % 5)
            switch selector.first {
            case "#": return "<div id=\"\(selector.dropFirst())\"><p>\(text)</p></div>"
            case ".": return "<div class=\"\(selector.dropFirst())\"><p>\(text)</p></div>"
            default: return "<\(selector)><p>\(text)</p></\(selector)>"
            }
        }.joined(separator: "\n") + "</body></html>"
        let nestedArticles = """
        <html><body><article><h2>外層</h2><article><p>\(s[1])\(s[2])</p></article><p>\(s[3])</p></article></body></html>
        """
        let mixedCase = """
        <HTML><BODY><DIV ID="BookText"><P>\(s[0])</P><P>\(s[2])</P></DIV><div class="bookText">\(s[1])</div></BODY></HTML>
        """
        let short = "<html><body><div id=\"content\">太短了。</div><p>\(s[0])</p><p>\(s[1])</p></body></html>"
        let none = "<html><body><div class=\"main\"><p>\(s[2])</p><p>\(s[3])</p></div></body></html>"
        return [
            ("nested", nested, 7), ("tie", tie, 2), ("every selector", every, 29),
            ("nested articles", nestedArticles, 1), ("mixed case", mixedCase, 1),
            ("short", short, 1), ("none", none, 0),
        ]
    }

    @Test("one parse gives every selector the same @html, and the heuristic the same text")
    func parseOnceMatchesPerSelectorParse() throws {
        let inputs = try loadInputs()
        let cases = Self.corpus() + [
            ("narou page", inputs.fullPage(1), 1), ("narou collapsed", inputs.collapsedPage(1), 2),
        ]
        for (name, html, minHits) in cases {
            let document = parseHTML(html)
            var hits = 0
            for selector in ChapterFetcher.knownContentSelectors {
                let once = ChapterFetcher.knownSelectorHTML(selector, in: document, pageURL: Self.pageURL)
                let reparsed = RuleEngine.extractValue(fromHTML: html, rule: selector + "@html", baseURL: Self.pageURL)
                #expect(once.isEmpty == reparsed.isEmpty, "\(name) \(selector)")
                #expect(Self.canonical(once) == Self.canonical(reparsed), "\(name) \(selector)")
                #expect(ChapterFetcher.stripHtmlToText(once) == ChapterFetcher.stripHtmlToText(reparsed), "\(name) \(selector)")
                if !once.isEmpty { hits += 1 }
            }
            #expect(hits >= minHits, "\(name): \(hits) selectors matched")
            let output = ChapterFetcher.extractLocalHTMLContent(html: html, pageURL: Self.pageURL)
            #expect(output == Self.reference(html), "\(name)")
            #expect(!output.isEmpty, "\(name)")
        }
        // The tie keeps the earlier selector: `#chapter-content` comes before `.chapter-content`.
        let tie = try #require(Self.corpus().first { $0.name == "tie" })
        #expect(ChapterFetcher.extractLocalHTMLContent(html: tie.html, pageURL: Self.pageURL).hasPrefix("甲"))
    }
}
