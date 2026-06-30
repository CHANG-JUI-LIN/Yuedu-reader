import Foundation
import Testing
@testable import yuedu_app

// Debug tests for 35 comic sources (Legado format).
// Run: xcodebuild test -scheme "yuedu appTests" -only-testing:'yuedu appTests/ComicSourcesDebugTests'
@Suite("ComicSourcesDebug", .serialized)
struct ComicSourcesDebugTests {

    static let jsonPath = "/Users/zhangruilin/Desktop/Test document/RULE/35个漫画源.json"
    static let resultPath = "/tmp/yuedu_comic_debug.txt"

    private func loadSources() -> [BookSource] {
        guard let data = FileManager.default.contents(atPath: Self.jsonPath) else {
            return []
        }
        return (try? JSONDecoder().decode([BookSource].self, from: data)) ?? []
    }

    /// Step 1: Verify every source decodes from JSON without data loss
    @Test("decode validation")
    func validateDecode() {
        let sources = loadSources()
        guard !sources.isEmpty else {
            Issue.record("Could not load or decode \(Self.jsonPath)")
            return
        }
        var out = "========== DECODE VALIDATION (\(sources.count) sources) ==========\n"
        for (i, s) in sources.enumerated() {
            out += "[\(i)] \(s.bookSourceName)\n"
            out += "  url=\(s.bookSourceUrl)\n"
            out += "  type=\(s.bookSourceType) (0=text 2=manga)\n"
            out += "  enabledExplore=\(s.enabledExplore)\n"
            out += "  searchUrl=\(s.searchUrl.prefix(80))\n"
            out += "  exploreUrl=\(s.exploreUrl.prefix(80))\n"
            out += "  tocUrl=\(s.ruleBookInfo.tocUrl.prefix(80))\n"
            out += "  chapterList=\(s.ruleToc.chapterList.prefix(60))\n"

            // Check for issues
            if s.bookSourceUrl.isEmpty {
                out += "  WARN bookSourceUrl is empty\n"
            }
            if s.searchUrl.isEmpty {
                out += "  WARN searchUrl is empty\n"
            }
            if s.ruleToc.chapterList.isEmpty {
                out += "  WARN chapterList is empty\n"
            }
            if s.ruleToc.chapterUrl.isEmpty {
                out += "  WARN chapterUrl is empty\n"
            }
            if s.ruleContent.content.isEmpty {
                out += "  WARN content rule is empty\n"
            }
        }
        out += "========== END DECODE ==========\n"
        print(out)
        try? out.write(toFile: Self.resultPath, atomically: true, encoding: .utf8)
    }

    /// Step 2: safeURL validation for search URLs
    @Test("search URL validation")
    func validateSearchURLs() {
        let sources = loadSources()
        guard !sources.isEmpty else { return }
        var out = "========== SEARCH URL VALIDATION ==========\n"

        for (i, s) in sources.enumerated() {
            out += "[\(i)] \(s.bookSourceName)\n"
            let raw = s.searchUrl
            guard !raw.isEmpty else {
                out += "  SKIP empty searchUrl\n"
                continue
            }
            // Replace {{key}} with test keyword
            let withKey = raw.replacingOccurrences(of: "{{key}}", with: "鬼灭之刃")
                .replacingOccurrences(of: "{{page}}", with: "1")
            let resolved = RuleEngine.resolveURL(withKey, base: s.bookSourceUrl)
            let url = safeURL(string: resolved)
            if url == nil {
                out += "  FAIL safeURL: \(resolved.prefix(120))\n"
                // Try percent encoding
                if let encoded = resolved.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                    out += "       encoded=\(encoded.prefix(120))\n"
                    out += "       safeURL(encoded)=\(safeURL(string: encoded)?.absoluteString ?? "nil")\n"
                }
            } else {
                out += "  OK \(url!.absoluteString.prefix(120))\n"
            }
            // Check shouldUseLegadoRuntimeFetch
            let useLegado = s.shouldUseLegadoRuntimeFetch(for: withKey)
            if useLegado {
                out += "       uses Legado runtime fetch\n"
            }
        }
        out += "========== END SEARCH URL ==========\n"
        print(out)
    }

    /// Step 2b: Lenient URL-option parsing (no network).
    /// Locks in the fix that lets `AnalyzeUrl` accept Legado's GSON-lenient
    /// option blocks — single-quoted strings and unquoted keys — which broke
    /// comic discover (POST options) and produced `Invalid URL` base failures.
    @Test("lenient URL option + base parsing")
    func validateLenientOptionParsing() {
        // Single-quoted POST option (星际漫画/铅笔漫画 discover endpoints)
        let post = AnalyzeUrl.parseOptionDictionary(
            "{'method': 'POST','body':'action=getclasscomics&pageindex=1&tagid=31'}")
        #expect((post?["method"] as? String)?.uppercased() == "POST")
        #expect((post?["body"] as? String)?.contains("getclasscomics") == true)

        // Unquoted key (search bookUrl Cookie option)
        let cookie = AnalyzeUrl.parseOptionDictionary("{Cookie:\"xmanhua_lang=2\"}")
        #expect(cookie?["Cookie"] as? String == "xmanhua_lang=2")

        // Strict JSON must still parse unchanged
        let strict = AnalyzeUrl.parseOptionDictionary("{\"method\":\"GET\"}")
        #expect((strict?["method"] as? String) == "GET")

        // Base URL with a non-ASCII `#♤Haxc` tag must reduce to a parseable origin
        #expect(AnalyzeUrl.cleanBaseURL("http://www.xmanhua.com#♤Haxc") == "http://www.xmanhua.com")
        #expect(AnalyzeUrl.cleanBaseURL("https://cn.baozimh.com/##@okou") == "https://cn.baozimh.com/")
        #expect(URL(string: AnalyzeUrl.cleanBaseURL("http://www.xmanhua.com#♤Haxc")) != nil)

        // End-to-end: an AnalyzeUrl built from the explore rule yields a POST request
        let analyze = AnalyzeUrl(
            ruleUrl: "https://www.xmanhua.com/manga-list-31-0-10/mangabz.ashx,{'method': 'POST','body':'action=getclasscomics&pageindex={{page}}&tagid=31'}",
            page: 1,
            baseUrl: "http://www.xmanhua.com#♤Haxc")
        let request = analyze.toURLRequest()
        #expect(request != nil)
        #expect(request?.httpMethod == "POST")
        let body = request?.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        #expect(body.contains("pageindex=1"))
    }

    /// Step 2c: Bare-attribute extraction on a list element (no network).
    /// Root-cause fix for the `Invalid URL: ,{Cookie...}` TOC failure: when the
    /// bookList element IS the `<a>` and bookUrl is the bare rule `href`, the
    /// element was re-parsed into a document wrapper and `href` read off the
    /// empty root. The fix descends to the fragment's root element.
    @Test("bare href on list element fragment")
    func validateBareAttributeExtraction() throws {
        let extractor = JsoupDefaultExtractor()
        let fragment = "<a href=\"/73xm/\" title=\"鬼灭之刃\" class=\"manga-item\"><p class=\"manga-item-title\">鬼灭之刃</p></a>"

        // Bare `href` must resolve to the real link, not "" (which collapsed
        // `href##$##,{Cookie...}` into a URL-less option blob).
        let href = try extractor.extractValue(
            from: fragment, rule: "href", baseURL: "https://www.xmanhua.com/search?title=x")
        #expect(href == "https://www.xmanhua.com/73xm/")

        // Content keywords stay on the existing path and keep working.
        let title = try extractor.extractValue(
            from: fragment, rule: "text", baseURL: "https://www.xmanhua.com/")
        #expect(title.contains("鬼灭之刃"))

        // Navigating rules (with selector steps) are unaffected.
        let viaTag = try extractor.extractValue(
            from: "<div class=\"box\"><a href=\"/73xm/\">x</a></div>",
            rule: "tag.a@href", baseURL: "https://www.xmanhua.com/")
        #expect(viaTag == "https://www.xmanhua.com/73xm/")
    }

    /// Step 2d: bare-tag index field extraction (mangabz `p.0@text`).
    /// The discover log showed `.manga-i-list-item` elements found but name empty,
    /// even though each div has `<p class="manga-i-list-title">`. This pins whether
    /// `p.0@text` (select first <p>, take text) extracts correctly.
    @Test("tag-index field extraction p.0@text")
    func validateTagIndexExtraction() throws {
        let ext = JsoupDefaultExtractor()
        let div = "<div class=\"manga-i-list-item\" mid=\"39904\">"
            + "<a href=\"/39904bz/\"><img src=\"x.jpg\" class=\"manga-i-cover\"></a>"
            + "<p class=\"manga-i-list-title\">HIGH不起來的約會</p>"
            + "<p class=\"manga-i-list-subtitle\">sub</p></div>"
        let name = try ext.extractValue(from: div, rule: "p.0@text", baseURL: "https://www.mangabz.com/")
        #expect(name == "HIGH不起來的約會")
        // also the no-index form should yield the first <p>
        let first = try ext.extractValue(from: div, rule: "p@text", baseURL: "https://www.mangabz.com/")
        #expect(first == "HIGH不起來的約會")

        // Real root cause: a bare `.class` list rule (no @accessor) must route to
        // CssExtractor — which yields each element's outerHtml — not the text
        // fallback (which returned element TEXT, so `p.0@text` found no tags).
        #expect(CssExtractor().canHandle(rule: ".manga-i-list-item"))
        #expect(CssExtractor().canHandle(rule: ".comic-item"))
        #expect(!CssExtractor().canHandle(rule: ".manga-list@a")) // has @accessor → JsoupDefault

        // `tag.index` (p.0, a.0) is Legado index notation — first/that-nth element —
        // NOT CSS `tag.class`. It must route to JsoupDefault, not CssExtractor (which
        // would `select("p.0")` for a <p class="0"> that never exists → empty name).
        #expect(!CssExtractor().canHandle(rule: "p.0@text"))
        #expect(!CssExtractor().canHandle(rule: "a.0@href"))
        #expect(!CssExtractor().canHandle(rule: "li.-1@text"))
        #expect(CssExtractor().canHandle(rule: "div.item@text")) // real tag.class stays CSS
        // outerHtml (not text) must come back for the bare class list rule
        let outer = try CssExtractor().extractList(
            from: "<ul><li class=\"manga-i-list-item\"><p class=\"t\">名字</p></li></ul>",
            rule: ".manga-i-list-item@outerHtml", baseURL: "https://www.mangabz.com/")
        #expect(outer.first?.contains("<p") == true)
    }

    /// Step 3: Explore URL parsing diagnostic
    @Test("explore URL parsing")
    func validateExplore() {
        let sources = loadSources()
        guard !sources.isEmpty else { return }
        var out = "========== EXPLORE PARSING ==========\n"

        for (i, s) in sources.enumerated() {
            out += "[\(i)] \(s.bookSourceName)\n"
            let raw = s.exploreUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            guard s.enabledExplore, !raw.isEmpty else {
                out += "  SKIP disabled or empty exploreUrl\n"
                continue
            }

            // Check format
            if raw.hasPrefix("<js>") || raw.hasPrefix("@js:") {
                out += "  format=JS rule (<js> or @js:)\n"
            } else if raw.hasPrefix("[") || raw.hasPrefix("{") {
                out += "  format=JSON array/object\n"
                // Try to decode the JSON
                if let data = raw.data(using: .utf8) {
                    if let items = try? JSONDecoder().decode([ModernParserBridge.DiscoverItem].self, from: data) {
                        out += "       OK parsed \(items.count) items\n"
                        for item in items.prefix(5) {
                            out += "       - title=\(item.title ?? "nil") url=\(item.url?.prefix(60) ?? "nil")\n"
                        }
                    } else if let single = try? JSONDecoder().decode(ModernParserBridge.DiscoverItem.self, from: data) {
                        out += "       OK single item: \(single.title ?? "nil")\n"
                    } else {
                        out += "       FAIL decode as DiscoverItem\n"
                    }
                }
            } else {
                out += "  format=text (title::url)\n"
                // Try parsing
                let items = raw.split(separator: "\n", omittingEmptySubsequences: true)
                for item in items.prefix(5) {
                    let entry = item.trimmingCharacters(in: .whitespacesAndNewlines)
                    if entry.contains("::") {
                        let parts = entry.components(separatedBy: "::")
                        out += "       OK \(parts[0].prefix(30)) -> \(parts.dropFirst().joined().prefix(60))\n"
                    } else {
                        out += "       WARN no :: separator: \(entry.prefix(60))\n"
                    }
                }
            }

            // Check explore URLs with safeURL
            if raw.contains("{{page}}") {
                let withPage = raw.replacingOccurrences(of: "{{page}}", with: "1")
                if !withPage.contains("<js>") && !withPage.contains("@js:") {
                    let url = safeURL(string: withPage)
                    out += "       safeURL(with page=1): \(url?.absoluteString ?? "FAIL")\n"
                }
            }
        }
        out += "========== END EXPLORE ==========\n"
        print(out)
    }

    /// Step 5: Live discover — categories + first-category book parse per source.
    /// Streams one NSLog line group per source (filter Console by `❖DISC❖`).
    @Test("live discover debug", .timeLimit(.minutes(20)))
    func debugDiscover() async {
        func log(_ s: String) { print("❖DISC❖ " + s); NSLog("❖DISC❖ %@", s) }
        let fetcher = BookSourceFetcher.shared
        // On a real device the Mac JSON path is unreachable, so use the sources the
        // user actually imported (BookSourceStore loads them from the app sandbox).
        // Fall back to the file only when the store is empty (e.g. Mac-sim runs).
        let stored = await MainActor.run { BookSourceStore.shared.sources }
        let all = stored.isEmpty ? loadSources() : stored
        let sources = all.filter {
            $0.enabledExplore && !$0.exploreUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !sources.isEmpty else {
            log("no explore-enabled sources (store=\(stored.count), file=\(loadSources().count))")
            return
        }
        log("==== LIVE DISCOVER DEBUG (\(sources.count) explore sources, store=\(stored.count)) ====")

        for (i, source) in sources.enumerated() {
            let exploreHead = source.exploreUrl.prefix(70).replacingOccurrences(of: "\n", with: " / ")
            log("[\(i)] \(source.bookSourceName) | enabledExplore=\(source.enabledExplore) | ruleExplore.bookList='\(source.ruleExplore.bookList.prefix(30))' ruleSearch.bookList='\(source.ruleSearch.bookList.prefix(30))'")
            log("[\(i)] exploreUrl=\(exploreHead)")

            guard source.enabledExplore,
                  !source.exploreUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                log("[\(i)] SKIP no explore")
                continue
            }

            // 1. Categories
            let items = await fetcher.discoverItems(in: source)
            log("[\(i)] categories=\(items.count) :: " + items.prefix(4).map { "\($0.title ?? "nil")[\($0.type ?? "-")]" }.joined(separator: ", "))
            let fetchable = items.first { ($0.type ?? "") != "select" && !($0.url ?? "").isEmpty }
            guard let first = fetchable else {
                log("[\(i)] no fetchable category")
                continue
            }
            log("[\(i)] fetch category '\(first.title ?? "")' url=\(first.url?.prefix(80) ?? "nil")")

            // 2. Books in the first category
            do {
                let books = try await fetcher.discoverBooks(from: first, page: 1, in: source)
                log("[\(i)] books=\(books.count) :: " + books.prefix(3).map { "\($0.name)|\($0.bookUrl.prefix(40))" }.joined(separator: " ;; "))
            } catch {
                log("[\(i)] discoverBooks ERROR: \(error.localizedDescription)")
            }
        }
        log("==== DISCOVER DEBUG DONE ====")
    }

    /// Step 4: Full pipeline - search, detail, and TOC URL resolution
    @Test("live search to detail to toc debug", .timeLimit(.minutes(15)))
    func debugPipeline() async {
        let fetcher = BookSourceFetcher.shared
        // Clear caches
        try? FileManager.default.removeItem(at: fetcher.bookInfoCacheDir())
        try? FileManager.default.removeItem(at: fetcher.tocCacheDir())

        let sources = loadSources()
        guard !sources.isEmpty else { return }
        var out = "========== LIVE PIPELINE DEBUG (query=鬼灭之刃) ==========\n"

        for (i, source) in sources.enumerated() {
            out += "\n-- [\(i)] \(source.bookSourceName) --\n"
            out += "    sourceType=\(source.bookSourceType) url=\(source.bookSourceUrl)\n"

            // 1. SEARCH
            var first: OnlineBook?
            do {
                let books = try await fetcher.search(query: "鬼灭之刃", in: source)
                first = books.first
                out += "    search -> \(books.count) results\n"
                if let b = first {
                    out += "       name=\(b.name) author=\(b.author)\n"
                    out += "       bookUrl=\(b.bookUrl.prefix(150))\n"
                    out += "       tocUrl=\(b.tocUrl.prefix(150))\n"
                    // Validate bookUrl with safeURL
                    if safeURL(string: b.bookUrl) == nil {
                        out += "       FAIL bookUrl fails safeURL\n"
                    }
                    // Check shouldUseLegadoRuntimeFetch
                    let useLegado = source.shouldUseLegadoRuntimeFetch(for: b.bookUrl)
                    out += "       usesLegadoRuntimeFetch=\(useLegado)\n"
                    if b.runtimeVariables?.isEmpty == false {
                        out += "       runtimeVars=\(b.runtimeVariables!)\n"
                    }
                }
            } catch {
                out += "    search -> ERROR: \(error.localizedDescription)\n"
                continue
            }
            guard let book = first, !book.bookUrl.isEmpty else {
                out += "    SKIP no search result\n"
                continue
            }

            // 2. DETAIL (fetch book info, extract tocUrl)
            var tocURL = book.bookUrl
            var runtimeVars = book.runtimeVariables
            do {
                let pkg = try await fetcher.fetchBookInfoPackage(
                    url: book.bookUrl, source: source, runtimeVariables: runtimeVars)
                runtimeVars = pkg.runtimeVariables
                out += "    detail -> name=\(pkg.name) author=\(pkg.author)\n"
                out += "       coverEmpty=\(pkg.coverUrl.isEmpty)\n"
                if !pkg.tocUrl.isEmpty {
                    tocURL = pkg.tocUrl
                    out += "       tocUrl (from ruleBookInfo)=\(pkg.tocUrl.prefix(150))\n"
                } else {
                    out += "       tocUrl is empty, falling back to bookUrl\n"
                }
                out += "       final tocURL=\(tocURL.prefix(150))\n"
                // Validate tocURL with safeURL
                let legadoFetch = source.shouldUseLegadoRuntimeFetch(for: tocURL)
                out += "       usesLegadoRuntimeFetch=\(legadoFetch)\n"
                if !legadoFetch {
                    // Only check safeURL for non-Legado path
                    if safeURL(string: tocURL) == nil {
                        out += "       FAIL tocURL fails safeURL\n"
                    } else {
                        out += "       OK safeURL\n"
                    }
                }
            } catch {
                out += "    detail -> ERROR: \(error.localizedDescription)\n"
                out += "       using bookUrl as TOC URL\n"
            }

            // 3. TOC
            do {
                let tocPkg = try await fetcher.fetchTOCPackage(
                    tocUrl: tocURL, source: source, runtimeVariables: runtimeVars)
                let sample = tocPkg.chapters.prefix(3).map { $0.title }.joined(separator: " / ")
                out += "    toc -> \(tocPkg.chapters.count) chapters"
                    + (tocPkg.chapters.isEmpty ? "" : " : \(sample)")
                out += "\n"
            } catch {
                out += "    toc -> ERROR: \(error.localizedDescription)\n"
            }

            try? out.write(toFile: Self.resultPath, atomically: true, encoding: .utf8)
        }

        out += "\n========== PIPELINE DEBUG DONE ==========\n"
        print(out)
        try? out.write(toFile: Self.resultPath, atomically: true, encoding: .utf8)
    }
}
