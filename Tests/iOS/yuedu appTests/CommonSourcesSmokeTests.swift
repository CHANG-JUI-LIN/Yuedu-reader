import Foundation
import Testing
@testable import yuedu_app

// Live smoke test for 常用书源.json (the 10 sources, 7 of which require login).
// Hits real servers — distinguishes "engine error (our bug)" from
// "empty / needs-login / server-down (external)". Run manually:
//   xcodebuild test ... -only-testing:'yuedu appTests/CommonSourcesSmokeTests'
@Suite("CommonSourcesSmoke", .serialized)
struct CommonSourcesSmokeTests {

    static var jsonPath: String {
        ProcessInfo.processInfo.environment["COMMON_SOURCES_JSON"]
            ?? ProcessInfo.processInfo.environment["TEST_RUNNER_COMMON_SOURCES_JSON"]
            ?? "/Users/zhangruilin/Desktop/Test document/RULE/常用书源.json"
    }

    static var searchKeyword: String {
        ProcessInfo.processInfo.environment["COMMON_SOURCES_QUERY"]
            ?? ProcessInfo.processInfo.environment["TEST_RUNNER_COMMON_SOURCES_QUERY"]
            ?? "斗罗大陆"
    }

    private func loadSources() -> [BookSource] {
        guard let data = FileManager.default.contents(atPath: Self.jsonPath) else {
            return []
        }
        return (try? JSONDecoder().decode([BookSource].self, from: data)) ?? []
    }

    static let resultPath = "/tmp/yuedu_smoke_results.txt"
    static let inspectPath = "/tmp/yuedu_buildrequest.txt"

    /// Inspect what the obfuscated `buildRequest(...)` returns for sources that use it
    /// in their searchUrl (番茄-明月 / 69-明月) — so we can teach AnalyzeUrl to consume it.
    @Test("inspect buildRequest return shape")
    func inspectBuildRequest() {
        var out = ""
        func log(_ s: String) {
            out += s + "\n"
            print(s)
            try? out.write(toFile: Self.inspectPath, atomically: true, encoding: .utf8)
        }

        let sources = loadSources()
        log("START sources.count=\(sources.count) path=\(Self.jsonPath)")
        guard !sources.isEmpty else {
            log("⏭️  Skipping inspectBuildRequest: file not found / decode failed")
            return
        }

        for source in sources where source.searchUrl.contains("buildRequest") {
            log("══════ \(source.bookSourceName)")
            log("searchUrl: \(source.searchUrl.replacingOccurrences(of: "\n", with: " "))")

            let engine = JSCoreEngine()
            engine.bookSource = source
            var vars: [String: String] = [:]
            engine.sourceBridge.getVariableHandler = {
                (try? JSONSerialization.data(withJSONObject: vars))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            }
            engine.sourceBridge.setVariableHandler = { json in
                if let d = json?.data(using: .utf8),
                   let m = try? JSONSerialization.jsonObject(with: d) as? [String: String] { vars = m }
            }

            // NOTE: 番茄-明月 / 69-明月 ship self-defending obfuscated jsLib (obfuscator.io).
            // Without browser globals, buildRequest() throws inside Function.prototype.bind on a
            // missing global; injecting those globals trips the obfuscator's self-defense and
            // leaves buildRequest undefined. Both dead-ends — these sources actively resist
            // non-Legado (JavaScriptCore) engines, so we don't attempt to run them.
            _ = engine.evaluate(source.jsLib, bindings: ["baseUrl": source.bookSourceUrl])
            if let err = engine.lastError { log("  jsLib error: \(err)") }

            log("  typeof buildRequest = \(engine.evaluate("typeof buildRequest") ?? "nil")")
            log("  typeof backend = \(engine.evaluate("typeof backend") ?? "nil")")

            // Which common browser/Node globals are missing in JSContext?
            let globals = ["console", "setTimeout", "setInterval", "clearTimeout",
                           "queueMicrotask", "Promise", "globalThis", "window", "self",
                           "navigator", "document", "crypto", "TextEncoder", "TextDecoder",
                           "btoa", "atob", "performance", "WebAssembly", "Reflect", "Proxy",
                           "Symbol", "fetch", "XMLHttpRequest", "location"]
            let missing = globals.filter { (engine.evaluate("typeof \($0)") ?? "undefined") == "undefined" }
            log("  missing globals: \(missing.joined(separator: ", "))")

            let probe = """
            (function(){
              try {
                var b = (typeof backend !== 'undefined') ? backend : '';
                var r = buildRequest(b + '/test/search?key=斗破&page=1');
                return 'TYPE=' + (typeof r) + ' | VAL=' + (typeof r === 'object' ? JSON.stringify(r) : String(r));
              } catch(e) {
                return 'THROW: ' + e + '\\n  STACK: ' + (e && e.stack ? String(e.stack).split('\\n').slice(0,8).join(' | ') : 'n/a');
              }
            })()
            """
            log("  buildRequest(...) → \(engine.evaluate(probe) ?? "nil")")
        }
        log("DONE")
    }

    @Test("live search + discover for every source")
    func smokeAllSources() async {
        var out = ""
        func log(_ s: String) { out += s + "\n"; print(s) }

        let sources = loadSources()
        // Manual diagnostic: silently skip when the local JSON isn't present
        // (e.g. CI / other machines) so the regular test run stays green.
        guard !sources.isEmpty else {
            print("⏭️  Skipping CommonSourcesSmoke: \(Self.jsonPath) not found")
            return
        }
        log("========== 常用书源 SMOKE TEST (\(sources.count) sources) ==========")

        for (i, source) in sources.enumerated() {
            let needsLogin = !source.loginUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !source.loginUi.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            log("\n──[\(i)] \(source.bookSourceName)\(needsLogin ? "  🔑login" : "")")
            log("    url: \(source.bookSourceUrl)")

            // SEARCH
            do {
                let books = try await BookSourceFetcher.shared.search(query: Self.searchKeyword, in: source)
                let sample = books.prefix(3).map { "\($0.name)/\($0.author)" }.joined(separator: ", ")
                log("    🔎 search → \(books.count) results\(books.isEmpty ? "" : " · \(sample)")")
            } catch {
                log("    🔎 search → ERROR: \(error.localizedDescription)")
            }

            // DISCOVER (explore)
            let hasExplore = !source.exploreUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if hasExplore {
                let items = await BookSourceFetcher.shared.discoverItems(in: source)
                let sample = items.prefix(4).compactMap { $0.title }.joined(separator: " / ")
                log("    🧭 discover → \(items.count) categories\(items.isEmpty ? "" : " · \(sample)")")
            } else {
                log("    🧭 discover → (no exploreUrl)")
            }
        }
        log("\n========== SMOKE TEST DONE ==========")
        try? out.write(toFile: Self.resultPath, atomically: true, encoding: .utf8)
    }

    static let detailResultPath = "/tmp/yuedu_detail_smoke.txt"

    /// Full pipeline probe: for every source run search → take first result →
    /// fetch book detail → fetch TOC, logging exactly which step goes empty / throws.
    /// Answers "search works but detail/TOC don't" by isolating the failing stage per source.
    @Test("live search → detail → toc for every source")
    func smokeDetailAndToc() async {
        var out = ""
        func log(_ s: String) {
            out += s + "\n"
            print(s)
            try? out.write(toFile: Self.detailResultPath, atomically: true, encoding: .utf8)
        }

        // Clear detail/TOC caches so we exercise the live path, not a stale package.
        let fetcher = BookSourceFetcher.shared
        try? FileManager.default.removeItem(at: fetcher.bookInfoCacheDir())
        try? FileManager.default.removeItem(at: fetcher.tocCacheDir())

        let sources = loadSources()
        guard !sources.isEmpty else {
            print("⏭️  Skipping detail smoke: \(Self.jsonPath) not found")
            return
        }
        log("========== 常用书源 DETAIL+TOC SMOKE (\(sources.count) sources, query=\(Self.searchKeyword)) ==========")

        for (i, source) in sources.enumerated() {
            log("\n──[\(i)] \(source.bookSourceName)")

            // 1. SEARCH
            var first: OnlineBook?
            do {
                let books = try await fetcher.search(query: Self.searchKeyword, in: source)
                first = books.first
                log("    🔎 search → \(books.count) results")
                if let b = first {
                    log("       first.name=\(b.name) | author=\(b.author)")
                    log("       first.bookUrl=\(String(b.bookUrl.prefix(140)))")
                    log("       first.runtimeVars=\(b.runtimeVariables?.count ?? 0)")
                }
            } catch {
                log("    🔎 search → ERROR: \(error.localizedDescription)")
                continue
            }
            guard let book = first, !book.bookUrl.isEmpty else {
                log("    ⏭️  no usable search result — skip detail/toc")
                continue
            }

            // 2. DETAIL
            var tocURL = book.bookUrl
            var runtimeVars = book.runtimeVariables
            do {
                let pkg = try await fetcher.fetchBookInfoPackage(
                    url: book.bookUrl, source: source, runtimeVariables: runtimeVars)
                runtimeVars = pkg.runtimeVariables
                if !pkg.tocUrl.isEmpty { tocURL = pkg.tocUrl }
                log("    📖 detail → name=\(pkg.name) | author=\(pkg.author) | "
                    + "coverEmpty=\(pkg.coverUrl.isEmpty) | introLen=\(pkg.intro.count) | "
                    + "tocUrl=\(String(pkg.tocUrl.prefix(100)))")
            } catch {
                log("    📖 detail → ERROR: \(error.localizedDescription)")
            }

            // 3. TOC
            do {
                let tocPkg = try await fetcher.fetchTOCPackage(
                    tocUrl: tocURL, source: source, runtimeVariables: runtimeVars)
                let sample = tocPkg.chapters.prefix(2).map { $0.title }.joined(separator: " / ")
                log("    📑 toc → \(tocPkg.chapters.count) chapters"
                    + (tocPkg.chapters.isEmpty ? "" : " · \(sample)"))
            } catch {
                log("    📑 toc → ERROR: \(error.localizedDescription)")
            }
        }
        log("\n========== DETAIL+TOC SMOKE DONE ==========")
    }
}
