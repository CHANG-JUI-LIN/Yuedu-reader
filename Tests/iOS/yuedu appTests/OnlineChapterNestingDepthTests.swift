import Foundation
import SwiftSoup
import Testing
import UIKit
@testable import yuedu_app

/// Crashlytics 66f63f61: a stack overflow (`___chkstk_darwin`) in SwiftSoup's `outerHtmlFast`,
/// which recurses once per nesting level, under `Element.html()` in
/// `ChapterFetcher.buildRenderableNormalizedHTML` — on a 512KB cooperative-pool thread. HTML5
/// tree construction has no depth limit, so markup that never closes an element nests one level
/// per paragraph, and the reader's IR converter recurses per level too. Each test feeds such a
/// chapter through the fetcher's real entry point and then through the production reader builder
/// (`OnlineProviderAttributedStringBuilder`, on the main actor as in the app), so neither the
/// serialization nor any later consumer can overflow, and no paragraph is lost or reordered.
///
/// The depth is well past what a 512KB stack survives in `outerHtmlFast` even in Release
/// (~464 bytes per level in a Debug build): on the old code these tests crash the runner.
@Suite("Online chapter nesting depth", .serialized)
@MainActor
struct OnlineChapterNestingDepthTests {
    private static let depth = 3_000

    @Test("a 3000-deep <div> chain renders every level, in order, within the depth limit")
    func deepDivChain() async throws {
        let markers = Self.markers(prefix: "L")
        let html = markers.map { "<div>\($0)" }.joined()
            + String(repeating: "</div>", count: Self.depth)
        // The input really is as deep as claimed — otherwise this test proves nothing.
        #expect(try Self.maxElementDepth(ofBodyIn: html) >= Self.depth)

        let chapter = try await Self.renderThroughReader(html)

        #expect(try Self.maxElementDepth(ofBodyIn: chapter.normalized) <= Self.normalizedDepthBound)
        #expect(Self.missingMarkers(markers, inOrderIn: chapter.normalized).isEmpty)
        #expect(Self.missingMarkers(markers, inOrderIn: chapter.rendered).isEmpty)
    }

    @Test("paragraphs that each leave a <font> open render every paragraph, in order, within the depth limit")
    func unclosedFontPerParagraph() async throws {
        let markers = Self.markers(prefix: "P")
        // Same attributes on every <font>: the HTML5 "Noah's Ark" clause caps the list of
        // active formatting elements, but not the stack of open elements, so each paragraph
        // still nests one level inside the previous one.
        let html = markers.map { "<font color=\"#333333\">\($0)<br>" }.joined()
        #expect(try Self.maxElementDepth(ofBodyIn: html) >= Self.depth)

        let chapter = try await Self.renderThroughReader(html)

        #expect(try Self.maxElementDepth(ofBodyIn: chapter.normalized) <= Self.normalizedDepthBound)
        #expect(Self.missingMarkers(markers, inOrderIn: chapter.normalized).isEmpty)
        #expect(Self.missingMarkers(markers, inOrderIn: chapter.rendered).isEmpty)
    }

    // MARK: - Helpers

    /// `<body>` → `<article id="reader-content">` adds one level over the fetcher's own body;
    /// flattening leaves leaf content two levels under the element at the limit; `<br>`
    /// promotion and the 段評 reattachment can each push content one level further down.
    private static let normalizedDepthBound = ChapterFetcher.maxBodyNestingDepth + 5

    /// Fixed-width ASCII markers: no marker is a prefix of another, and none sits against CJK
    /// text that typography or 繁簡 conversion could touch in the rendered string.
    private static func markers(prefix: String) -> [String] {
        (0..<depth).map { prefix + String(format: "%04d", $0) }
    }

    private static func renderThroughReader(
        _ rawHTML: String
    ) async throws -> (normalized: String, rendered: String) {
        let normalized = await ChapterFetcher.shared.buildRenderableNormalizedHTML(
            title: "第1章", plainTextContent: "", rawHTMLContent: rawHTML
        )
        let payload = ChapterContentPayload(
            index: 0, title: "第1章", plainText: "", body: .html(normalized),
            sourceHref: "https://book.example/chapter/1"
        )
        let built = try await OnlineProviderAttributedStringBuilder(
            provider: NestingDepthStubProvider(payload: payload),
            renderSize: CGSize(width: 400, height: 800)
        ).buildChapter(at: 0, settings: settings(), themeTextColor: .black, themeBackgroundColor: .white)
        return (normalized, built.attributedString.string)
    }

    private static func settings() -> ReaderRenderSettings {
        ReaderRenderSettings(
            theme: "sepia", textColor: .black, backgroundColor: .white,
            fontSize: 18, lineHeightMultiple: 1.6, lineSpacing: 10, paragraphSpacing: 8,
            letterSpacing: 0, marginH: 20, marginV: 16, footerHeight: 24,
            contentInsets: UIEdgeInsets(top: 40, left: 20, bottom: 40, right: 20)
        )
    }

    /// Element depth below `<body>`, walked with an explicit stack — a recursive walk would
    /// overflow on the very input under test. Parsing is iterative in SwiftSoup, and so is
    /// tearing the tree down.
    private static func maxElementDepth(ofBodyIn html: String) throws -> Int {
        let document = try SwiftSoup.parse(html)
        let body = try #require(document.body())
        var deepest = 0
        var pending: [(element: Element, depth: Int)] = [(body, 0)]
        while let (element, depth) = pending.popLast() {
            deepest = max(deepest, depth)
            for child in element.children().array() {
                pending.append((child, depth + 1))
            }
        }
        return deepest
    }

    /// Markers that are absent, or present only before the previous marker. Searching forward
    /// from the last hit makes this linear and checks order at the same time.
    private static func missingMarkers(_ markers: [String], inOrderIn text: String) -> [String] {
        var cursor = text.startIndex
        var missing: [String] = []
        for marker in markers {
            guard let range = text.range(of: marker, range: cursor..<text.endIndex) else {
                missing.append(marker)
                continue
            }
            cursor = range.upperBound
        }
        return missing
    }
}

private struct NestingDepthStubProvider: BookContentProvider {
    let payload: ChapterContentPayload

    var totalChapters: Int { 1 }

    func chapterTitle(at index: Int) -> String {
        index == payload.index ? payload.title : ""
    }

    func contentForChapter(index: Int) async throws -> ChapterContentPayload {
        guard index == payload.index else {
            throw BookContentProviderError.chapterIndexOutOfRange(index)
        }
        return payload
    }
}
