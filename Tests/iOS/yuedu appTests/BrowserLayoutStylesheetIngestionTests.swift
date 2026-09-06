import Foundation
import Testing
@testable import yuedu_app

@MainActor
@Suite(.serialized)
struct BrowserLayoutStylesheetIngestionTests {
    @Test func preservesDocumentOrderAndSeparateCurrentReplay() async throws {
        let html = """
        <head><link rel="stylesheet" href="../Styles/a.css">
        <style>p { width:20px }</style>
        <link rel="stylesheet" href="../Styles/c.css">
        <style>p { width:40px }</style></head>
        <body><p style="width:50px">Hello</p></body>
        """
        let provider = IngestionResources([
            "OPS/Styles/a.css": "p { width:10px }",
            "OPS/Styles/c.css": "p { width:30px }"
        ])
        let input = await collect(html, provider: provider)
        #expect(input.activeAuthorStylesheets.map(\.source) == [
            .linked(href: "OPS/Styles/a.css"), .inline(nodeOrdinal: 1),
            .linked(href: "OPS/Styles/c.css"), .inline(nodeOrdinal: 3)
        ])
        #expect(input.activeAuthorStylesheets.map(\.text) == [
            "p { width:10px }", "p { width:20px }", "p { width:30px }", "p { width:40px }"
        ])
        // Preserve the pre-migration inline chapter-cache collision explicitly.
        #expect(CurrentCSSFrontendSupport.stylesheetsForCurrentCompatibility(input.stylesheets) == [
            "p { width:20px }", "p { width:20px }", "p { width:10px }", "p { width:30px }"
        ])
        #expect(input.html.contains("style=\"width:50px\""))
        let again = await collect(html, provider: provider)
        #expect(again.stylesheets == input.stylesheets)
    }

    @Test func retainsInactiveMetadataAndLoadDiagnostics() async throws {
        let html = """
        <head><style media="all">p { width:10px }</style>
        <style media="print">p { width:20px }</style>
        <link rel="alternate stylesheet" href="alternate.css">
        <link rel="stylesheet" href="missing.css"></head><body><p>Text</p></body>
        """
        let input = await collect(html, provider: IngestionResources(["OPS/Text/alternate.css": "p { width:30px }"]))
        #expect(input.activeAuthorStylesheets.count == 1)
        #expect(input.stylesheets.contains { $0.media == "print" })
        #expect(input.stylesheets.contains { $0.isAlternate })
        #expect(input.diagnostics.contains { $0.message.contains("unsupported media") })
        #expect(input.diagnostics.contains { $0.message.contains("alternate") })
        #expect(input.diagnostics.contains { $0.message.contains("load failed") })
    }

    @Test func importsUseExistingResolverAndRetainDiagnosticsOnCacheHit() async throws {
        let provider = IngestionResources([
            "OPS/Styles/a.css": "@import 'base.css'; @import 'https://example.invalid/remote.css'; p { width:20px }",
            "OPS/Styles/base.css": "p { width:10px }"
        ])
        let resolver = EPUBStyleResolver(resourceProvider: provider, fontRegistrationService: CoreTextFontRegistrationService())
        let html = "<head><link rel='stylesheet' href='../Styles/a.css'></head><body>Text</body>"
        let first = await EPUBStylesheetIngestion.collect(html: html, chapterHref: "OPS/Text/ch.xhtml", resourceProvider: provider, styleResolver: resolver)
        let second = await EPUBStylesheetIngestion.collect(html: html, chapterHref: "OPS/Text/ch.xhtml", resourceProvider: provider, styleResolver: resolver)
        let css = try #require(first.activeAuthorStylesheets.first?.text)
        #expect(css.range(of: "width:10px")!.lowerBound < css.range(of: "width:20px")!.lowerBound)
        #expect(!css.contains("@import"))
        #expect(first.diagnostics.contains { $0.message.contains("remote @import") })
        #expect(first.diagnostics == second.diagnostics)
        #expect(!provider.requests.contains { $0.contains("example.invalid") })
    }

    @Test func stringCompatibilityInputRemainsOrderedAndActive() {
        let input = CSSFrontendInput.currentCompatibility(html: "<p>x</p>", cssTexts: ["a", "b"])
        #expect(input.activeAuthorStylesheets.map(\.text) == ["a", "b"])
        #expect(input.stylesheets.map(\.sourceOrder) == [0, 1])
    }

    private func collect(_ html: String, provider: IngestionResources) async -> CSSFrontendInput {
        await EPUBStylesheetIngestion.collect(
            html: html, chapterHref: "OPS/Text/ch.xhtml", resourceProvider: provider,
            styleResolver: EPUBStyleResolver(resourceProvider: provider, fontRegistrationService: CoreTextFontRegistrationService())
        )
    }
}

private final class IngestionResources: BookResourceProvider {
    let texts: [String: String]
    var requests: [String] = []
    init(_ texts: [String: String]) { self.texts = texts }
    var customScheme: String { "reader-book" }
    var chapters: [BookResourceChapterDescriptor] { [] }
    func cssResourceHrefs() -> [String] { [] }
    func resourceURL(for href: String) -> URL { URL(string: "reader-book://test/" + href)! }
    func chapterDataSize(at index: Int) async throws -> Int { 0 }
    func chapterIndex(for href: String) -> Int? { nil }
    func chapterHTML(at index: Int) async throws -> String { "" }
    func response(for url: URL) async throws -> PublicationResourceResponse {
        requests.append(url.absoluteString)
        guard let text = texts[String(url.path.dropFirst())] else { throw URLError(.fileDoesNotExist) }
        return PublicationResourceResponse(data: Data(text.utf8), mimeType: "text/css", textEncodingName: "utf-8")
    }
}
