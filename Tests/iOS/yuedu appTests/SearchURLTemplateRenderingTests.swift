import Foundation
import Testing
@testable import yuedu_app

/// The native search path's `{{…}}` source JS, evaluated in the source's session runtime
/// (`BookSource.renderSearchURL`). A source with no `jsLib` keeps its JS templates on this path;
/// one with `jsLib` sends them to the runtime instead (`shouldUseLegadoRuntimeFetch`).
@Suite("Search URL template rendering")
struct SearchURLTemplateRenderingTests {

    private func source(searchUrl: String) -> BookSource {
        var source = BookSource(
            bookSourceUrl: "https://template-render.test/\(UUID().uuidString)",
            bookSourceName: "模板測試"
        )
        source.searchUrl = searchUrl
        return source
    }

    @Test("a JS template reads the same key and page bindings as AnalyzeUrl")
    func expressionSeesKeyAndPage() async {
        let source = source(searchUrl: "https://template-render.test/s?q={{key}}&offset={{(page-1)*20}}")
        #expect(!source.shouldUseLegadoRuntimeFetch(for: source.searchUrl))

        let request = await source.renderSearchURL(query: "abc", page: 3)

        #expect(request.url == "https://template-render.test/s?q=abc&offset=40")
        #expect(request.method == "GET")
        #expect(request.body == nil)
    }

    @Test("source.getKey() resolves through the session's source bridge")
    func sourceBridgeIsInScope() async {
        let source = source(searchUrl: "https://template-render.test/s?id={{source.getKey()}}&q={{key}}")

        let request = await source.renderSearchURL(query: "abc")

        #expect(request.url == "https://template-render.test/s?id=\(source.bookSourceUrl)&q=abc")
    }

    @Test("a side-effect template renders empty")
    func sideEffectTemplateRendersEmpty() async {
        let source = source(
            searchUrl: "{{cookie.removeCookie(source.getKey())}}https://template-render.test/s?q={{key}}"
        )

        let request = await source.renderSearchURL(query: "abc")

        #expect(request.url == "https://template-render.test/s?q=abc")
    }

    @Test("the legacy POST body gets its templates evaluated too")
    func postBodyTemplates() async {
        let source = source(searchUrl: "https://template-render.test/s,POST,kw={{key}}&from={{page*10}}")

        let request = await source.renderSearchURL(query: "abc", page: 2)

        #expect(request.url == "https://template-render.test/s")
        #expect(request.method == "POST")
        #expect(request.body == "kw=abc&from=20")
    }
}
