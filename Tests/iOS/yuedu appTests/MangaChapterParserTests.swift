import Foundation
import Testing
@testable import yuedu_app

@Suite("Manga chapter parser")
struct MangaChapterParserTests {

    @Test("parses a JSON array of image URLs")
    func jsonArray() {
        let content = #"["https://cdn.example.com/1.jpg", "https://cdn.example.com/2.jpg"]"#
        let urls = MangaChapterParser.imageURLs(from: content)
        #expect(urls == ["https://cdn.example.com/1.jpg", "https://cdn.example.com/2.jpg"])
    }

    @Test("parses newline-separated URLs and drops non-URL lines")
    func newlineSeparated() {
        let content = """
        https://cdn.example.com/a.png
        not a url
        https://cdn.example.com/b.png
        """
        let urls = MangaChapterParser.imageURLs(from: content)
        #expect(urls == ["https://cdn.example.com/a.png", "https://cdn.example.com/b.png"])
    }

    @Test("normalizes protocol-relative URLs to https")
    func protocolRelative() {
        let urls = MangaChapterParser.imageURLs(from: "//cdn.example.com/c.webp")
        #expect(urls == ["https://cdn.example.com/c.webp"])
    }

    @Test("empty content yields no pages")
    func empty() {
        #expect(MangaChapterParser.imageURLs(from: "   \n  ").isEmpty)
    }

    @Test("pages attach headers and page indices")
    func pagesAttachHeaders() {
        let headers = ["Referer": "https://example.com"]
        let pages = MangaChapterParser.pages(
            from: "https://cdn.example.com/1.jpg\nhttps://cdn.example.com/2.jpg",
            headers: headers
        )
        #expect(pages.count == 2)
        #expect(pages[0].id == 0)
        #expect(pages[1].id == 1)
        #expect(pages[0].headers["Referer"] == "https://example.com")
        #expect(pages[0].localURL == nil)
    }

    @Test("extracts URLs from <img> tags, preferring data-src")
    func imgTags() {
        let content = """
        <div><img class="lazy" data-src="https://cdn.example.com/1.jpg" src="placeholder.gif"></div>
        <img src="//cdn.example.com/2.png">
        """
        let urls = MangaChapterParser.imageURLs(from: content)
        #expect(urls == ["https://cdn.example.com/1.jpg", "https://cdn.example.com/2.png"])
    }

    // MARK: - Legado `url,{headers}` image syntax (aggregation manga sources)

    /// Real shape returned by 光遇聚合: `<img src="<url>,{"headers":{...}}">` with unescaped
    /// quotes, where the CDN needs the per-image referer.
    private static let headeredContent = #"""
    <img src="https://f40.g-mh.online/scomic/a/0/1.webp,{"headers":{"User-Agent":"Mozilla/5.0 (Linux; Android 13)","referer":"https://manhuafree.com/"}}"><img src="https://f40.g-mh.online/scomic/a/0/2.webp,{"headers":{"referer":"https://manhuafree.com/"}}"><img src="https://f40.g-mh.online/scomic/a/0/3.webp,{"headers":{"referer":"https://manhuafree.com/"}}">
    """#

    @Test("splits the url,{headers} image syntax into clean URL + per-image headers")
    func parsesHeaderedImageSyntax() {
        let images = MangaChapterParser.parsedImages(from: Self.headeredContent)
        #expect(images.count == 3)
        #expect(images.first?.url == "https://f40.g-mh.online/scomic/a/0/1.webp")
        #expect(!(images.first?.url.contains(",{") ?? true))
        #expect(images.first?.headers["referer"] == "https://manhuafree.com/")
        #expect(images.first?.headers["User-Agent"] == "Mozilla/5.0 (Linux; Android 13)")
    }

    @Test("pages merge per-image headers over the source defaults")
    func pagesMergeHeaders() {
        let pages = MangaChapterParser.pages(
            from: Self.headeredContent,
            headers: ["referer": "https://default.example/", "Cookie": "a=b"]
        )
        #expect(pages.count == 3)
        // Per-image referer wins; source-only headers (Cookie) are retained.
        #expect(pages[0].headers["referer"] == "https://manhuafree.com/")
        #expect(pages[0].headers["Cookie"] == "a=b")
        #expect(pages[0].imageURL == "https://f40.g-mh.online/scomic/a/0/1.webp")
    }
}
