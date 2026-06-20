import Foundation
import Testing
@testable import yuedu_app

// A manga chapter's parsed content is a list of <img> tags. The shared online-chapter
// sanitizer strips HTML to plain text for novels — which would erase an all-image chapter
// and surface as "Fetched empty content". These guard that manga markup survives while prose
// is still flattened.
@Suite("Manga content survives chapter sanitization", .serialized)
struct MangaContentPreservationTests {

    private func resolve(_ content: String) async -> String {
        await ChapterFetcher.shared.resolveContent(
            parsed: ChapterParsePayload(
                content: content, title: "Ch", sourceMatched: true, isPay: false),
            replaceRules: "",
            fetchViaJS: { nil },
            fetchBySelectors: { nil }
        )
    }

    @Test("an all-<img> chapter is not stripped to empty")
    func imgChapterPreserved() async {
        let content = await resolve(
            #"<img src="https://c.example/1.webp"><img src="https://c.example/2.webp">"#)
        #expect(content.localizedCaseInsensitiveContains("<img"), "actual=>>>\(content)<<<")
        #expect(content.contains("https://c.example/1.webp"))
    }

    @Test("the Legado url,{headers} image form survives")
    func headeredImgPreserved() async {
        let content = await resolve(
            #"<img src="https://c.example/1.webp,{"headers":{"referer":"https://m.example/"}}">"#)
        #expect(content.localizedCaseInsensitiveContains("<img"))
        // The whole src (including the per-image headers) must be intact for the manga parser.
        #expect(content.contains("referer"))
    }

    @Test("mixed prose and images keeps image markup")
    func mixedProseAndImagesPreserved() async {
        let content = await resolve(
            #"<p>第一段文字。</p><img src="https://c.example/insert.webp"><p>第二段文字。</p>"#)
        #expect(content.contains("第一段文字"))
        #expect(content.localizedCaseInsensitiveContains("<img"), "actual=>>>\(content)<<<")
        #expect(content.contains("https://c.example/insert.webp"))
    }

    @Test("a prose chapter is still flattened to plain text")
    func proseStillStripped() async {
        let content = await resolve("<p>第一段文字。</p><p>第二段文字。</p>")
        #expect(!content.contains("<p"))
        #expect(content.contains("第一段文字"))
    }

    @Test("a single paragraph wrapping source newlines keeps every paragraph")
    func singleParagraphWithInteriorNewlinesSplits() async {
        let content = await resolve(
            "<p>第一段。\r\n　　第二段。\r\n　　第三段。\r\n　　第四段。</p>"
        )
        let lines = content
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        #expect(lines == ["第一段。", "第二段。", "第三段。", "第四段。"], "actual=>>>\(content)<<<")
    }
}
