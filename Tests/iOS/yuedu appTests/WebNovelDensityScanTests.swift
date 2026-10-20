import Foundation
import Testing
@testable import yuedu_app

/// `WebNovelParser.extractContent` falls to a density scan when no content selector names the
/// page. The scan walked each candidate's whole subtree, so nested wrappers made it grow with
/// depth × size (a 113 KB page of 240 wrappers: 5.8 s) during 書源檢查 (Crashlytics 084ef85c).
/// These pages pin what it picks; the expected text is what the scan picked before it was
/// made linear.
@Suite("Web novel density scan")
struct WebNovelDensityScanTests {
    private static let paragraph = "這是一段夠長的正文，有逗號，也有句號。"

    private static func paragraphs(_ count: Int, label: String) -> String {
        (0..<count).map { "<p>\(label)\($0)：\(paragraph)</p>" }.joined()
    }

    static let pages: [(name: String, html: String)] = [
        ("nested wrappers", """
        <html><body><div class="a"><div class="b"><div class="c">
        <div class="row0">\(paragraphs(4, label: "甲"))</div>
        <div class="row1">\(paragraphs(4, label: "乙"))</div>
        <div class="row2">\(paragraphs(4, label: "丙"))</div>
        </div></div></div>
        <div class="side"><a href="/1">第一章</a><a href="/2">第二章</a></div></body></html>
        """),
        ("class penalties", """
        <html><body>
        <section class="comment">\(paragraphs(8, label: "評"))</section>
        <div class="novel">\(paragraphs(6, label: "文"))</div>
        </body></html>
        """),
        ("line breaks only", """
        <html><body><div class="box"><div class="inner">
        \((0..<8).map { "第\($0)行：\(paragraph)" }.joined(separator: "<br><br>"))
        </div></div></body></html>
        """),
        ("one paragraph and loose text", """
        <html><body><div class="wrap"><p>只有一段：\(paragraph)</p>
        \((0..<6).map { "散文\($0)：\(paragraph)" }.joined(separator: "<br>"))
        </div></body></html>
        """),
        ("short paragraphs skipped", """
        <html><body><div class="x"><p>短</p><p>也短短</p>\(paragraphs(6, label: "長"))<p>　</p></div></body></html>
        """),
        ("tie keeps the first", """
        <html><body><div class="first">\(paragraphs(6, label: "同"))</div><div class="second">\(paragraphs(6, label: "後"))</div></body></html>
        """),
        ("nothing long enough", """
        <html><body><div class="y"><p>太短的一段文字。</p></div><span>頁面其餘文字</span></body></html>
        """),
    ]

    /// Captured from the scan as it was before it was made linear.
    static let expected: [String: String] = [
        "class penalties":
            "文0：這是一段夠長的正文，有逗號，也有句號。\n文1：這是一段夠長的正文，有逗號，也有句號。\n文2：這是一段夠長的正文，有逗號，也有句號。\n文3：這是一段夠長的正文，有逗號，也有句號。\n文4：這是一段夠長的正文，有逗號，也有句號。\n文5：這是一段夠長的正文，有逗號，也有句號。",
        "line breaks only":
            "第0行：這是一段夠長的正文，有逗號，也有句號。\n第1行：這是一段夠長的正文，有逗號，也有句號。\n第2行：這是一段夠長的正文，有逗號，也有句號。\n第3行：這是一段夠長的正文，有逗號，也有句號。\n第4行：這是一段夠長的正文，有逗號，也有句號。\n第5行：這是一段夠長的正文，有逗號，也有句號。\n第6行：這是一段夠長的正文，有逗號，也有句號。\n第7行：這是一段夠長的正文，有逗號，也有句號。",
        "nested wrappers":
            "甲0：這是一段夠長的正文，有逗號，也有句號。\n甲1：這是一段夠長的正文，有逗號，也有句號。\n甲2：這是一段夠長的正文，有逗號，也有句號。\n甲3：這是一段夠長的正文，有逗號，也有句號。\n乙0：這是一段夠長的正文，有逗號，也有句號。\n乙1：這是一段夠長的正文，有逗號，也有句號。\n乙2：這是一段夠長的正文，有逗號，也有句號。\n乙3：這是一段夠長的正文，有逗號，也有句號。\n丙0：這是一段夠長的正文，有逗號，也有句號。\n丙1：這是一段夠長的正文，有逗號，也有句號。\n丙2：這是一段夠長的正文，有逗號，也有句號。\n丙3：這是一段夠長的正文，有逗號，也有句號。",
        "nothing long enough":
            "太短的一段文字。頁面其餘文字",
        "one paragraph and loose text":
            "只有一段：這是一段夠長的正文，有逗號，也有句號。\n 散文0：這是一段夠長的正文，有逗號，也有句號。\n散文1：這是一段夠長的正文，有逗號，也有句號。\n散文2：這是一段夠長的正文，有逗號，也有句號。\n散文3：這是一段夠長的正文，有逗號，也有句號。\n散文4：這是一段夠長的正文，有逗號，也有句號。\n散文5：這是一段夠長的正文，有逗號，也有句號。",
        "short paragraphs skipped":
            "長0：這是一段夠長的正文，有逗號，也有句號。\n長1：這是一段夠長的正文，有逗號，也有句號。\n長2：這是一段夠長的正文，有逗號，也有句號。\n長3：這是一段夠長的正文，有逗號，也有句號。\n長4：這是一段夠長的正文，有逗號，也有句號。\n長5：這是一段夠長的正文，有逗號，也有句號。",
        "tie keeps the first":
            "同0：這是一段夠長的正文，有逗號，也有句號。\n同1：這是一段夠長的正文，有逗號，也有句號。\n同2：這是一段夠長的正文，有逗號，也有句號。\n同3：這是一段夠長的正文，有逗號，也有句號。\n同4：這是一段夠長的正文，有逗號，也有句號。\n同5：這是一段夠長的正文，有逗號，也有句號。",
    ]

    @Test("the scan picks the same text as before", arguments: pages.map(\.name))
    func picksAsBefore(name: String) throws {
        let html = try #require(Self.pages.first { $0.name == name }?.html)
        let text = WebNovelParser.extractContent(html: html, pageURL: "https://density.test/1.html")
        #expect(text == Self.expected[name])
    }
}
