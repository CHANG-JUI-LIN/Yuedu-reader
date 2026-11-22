@testable import YueduCoreText
import CoreText
import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// A portrait illustration in an online chapter, on a page wider than two thirds of its height:
/// the folded iPhone Duo's outer screen (466×678pt), whose text column is 426×516pt. A picture
/// was sized from the column's width alone — at most one and a half times as tall as it is wide —
/// so a 2:3 picture came out 426×639pt, taller than the page. CoreText fits no line taller than
/// its frame: the picture was never drawn, and the chapter had two blank pages where it stood.
@Suite("A portrait picture in an online chapter fits its page", .serialized)
@MainActor
struct OnlinePortraitPictureFitsPageTests {
    private static let page = CGSize(width: 466, height: 678)
    private static let paragraph = String(repeating: "鐵匠錘帶著呼嘯風聲直奔林淵後腦勺，那雙眼睛里全是凶殘與嗜血。", count: 2)

    private static func pictureData(_ size: CGSize) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            UIColor.gray.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// The ways a source writes an illustration into a chapter: `%@` is the `<img>`.
    nonisolated static let markups = [
        "<p>%@</p>",
        "%@",
        "<div>%@</div>",
        "<p>拿企鵝當%@盾牌。</p>",
    ]

    private func layout(picture: CGSize, insets: UIEdgeInsets, markup: String = "<p>%@</p>", lineSpacing: CGFloat = 0,
                        paragraphSpacing: CGFloat = 10, fontSize: CGFloat = 20,
                        lineHeightMultiple: CGFloat = 1.6) async throws -> CoreTextPaginator.ChapterLayout {
        let before = (1...8).map { "<p>\(Self.paragraph)（前\($0)）</p>" }.joined()
        let after = (1...12).map { "<p>\(Self.paragraph)（後\($0)）</p>" }.joined()
        // The picture as a downloaded chapter has it: in the book's image cache, read before the network.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("yd-portrait-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let src = "https://plates.example/\(UUID().uuidString).png"
        try OnlineImageDiskCache(directory: directory).write(Self.pictureData(picture), for: src)
        let html = before + markup.replacingOccurrences(of: "%@", with: "<img src=\"\(src)\">") + after
        let builder = OnlineProviderAttributedStringBuilder(
            provider: PortraitPictureChapterProvider(html: html),
            renderSize: Self.page,
            imageCacheDirectory: directory
        )
        let built = try await builder.buildChapter(
            at: 0,
            settings: ReaderRenderSettings(
                theme: "test", textColor: .black, backgroundColor: .white,
                fontSize: fontSize, lineHeightMultiple: lineHeightMultiple, lineSpacing: lineSpacing, paragraphSpacing: paragraphSpacing,
                letterSpacing: 0, marginH: 20, marginV: 0, footerHeight: 0,
                contentInsets: insets, writingMode: .horizontal
            ),
            themeTextColor: .black,
            themeBackgroundColor: .white
        )
        return await CoreTextPaginator().paginate(
            spineIndex: 0,
            attrStr: LayoutShared(built.attributedString).wrappedValue,
            renderSize: Self.page,
            fontSize: fontSize,
            contentInsets: insets
        )
    }

    private func pictures(_ layout: CoreTextPaginator.ChapterLayout, page: Int) -> [CoreTextPaginator.RenderedAttachment] {
        ((layout.inlineAttachments[page] ?? []) + (layout.blockAttachments[page] ?? [])
            + (layout.blockRenderables[page] ?? []).compactMap(\.imageAttachment))
            .filter { $0.rect.width > 100 }
    }

    /// The reader's insets on a folded iPhone Duo: the text runs the full width under the camera
    /// (20pt each side), or keeps clear of its side (84pt more on the right).
    @Test("the picture is drawn whole on one page, and no page is blank", arguments: markups, [
        UIEdgeInsets(top: 102, left: 20, bottom: 60, right: 20),
        UIEdgeInsets(top: 102, left: 20, bottom: 60, right: 104),
    ])
    func portraitPictureIsDrawnOnOnePage(markup: String, insets: UIEdgeInsets) async throws {
        let layout = try await layout(picture: CGSize(width: 1024, height: 1536), insets: insets, markup: markup)
        let text = layout.attributedString.string as NSString

        let picturePages = layout.pageRanges.indices.filter { !pictures(layout, page: $0).isEmpty }
        #expect(picturePages.count == 1, "pages with the picture: \(picturePages) of \(layout.pageRanges.count)")
        let picture = try #require(picturePages.first.flatMap { pictures(layout, page: $0).first })
        let content = CGRect(x: insets.left, y: insets.top,
                             width: Self.page.width - insets.left - insets.right,
                             height: Self.page.height - insets.top - insets.bottom)
        #expect(content.insetBy(dx: -0.5, dy: -0.5).contains(picture.rect),
                "the picture \(picture.rect) leaves the page's text area \(content)")
        // 2:3, as the source drew it.
        #expect(abs(picture.rect.height / picture.rect.width - 1.5) < 0.01, "\(picture.rect)")

        for (index, range) in layout.pageRanges.enumerated() where pictures(layout, page: index).isEmpty {
            let words = text.substring(with: NSRange(location: range.location, length: range.length))
                .replacingOccurrences(of: "\u{FFFC}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(!words.isEmpty, "page \(index + 1) of \(layout.pageRanges.count) is blank")
        }
    }

    /// A picture the page has room for keeps the column's width: only its height is limited.
    @Test("a square picture still fills the column")
    func squarePictureFillsTheColumn() async throws {
        let insets = UIEdgeInsets(top: 102, left: 20, bottom: 60, right: 20)
        let layout = try await layout(picture: CGSize(width: 1024, height: 1024), insets: insets)
        let picture = try #require(layout.pageRanges.indices.flatMap { pictures(layout, page: $0) }.first)
        #expect(abs(picture.rect.width - 426) < 0.5, "\(picture.rect)")
    }

    /// The picture's line carries the body text's baseline offset, which grows with the reading
    /// size and the line height: a picture that fits its page at one setting did not at another.
    @Test("the picture is drawn at every reading size and line height", arguments: markups, [
        [CGFloat(18), CGFloat(1.8)], [18, 1.0], [20, 1.8], [17, 1.5], [24, 2.0], [30, 2.4],
    ])
    func portraitPictureIsDrawnAtEveryReadingSize(markup: String, reading: [CGFloat]) async throws {
        let (fontSize, lineHeightMultiple) = (reading[0], reading[1])
        // The folded iPhone Duo's page as the reader lays it out: 418×503pt.
        let insets = UIEdgeInsets(top: 102, left: 24, bottom: 73, right: 24)
        let layout = try await layout(
            picture: CGSize(width: 1024, height: 1536), insets: insets, markup: markup,
            lineSpacing: (lineHeightMultiple - 1) * fontSize, paragraphSpacing: fontSize * 0.8,
            fontSize: fontSize, lineHeightMultiple: lineHeightMultiple)
        let drawn = layout.pageRanges.indices.flatMap { pictures(layout, page: $0) }
        #expect(drawn.count == 1, "\(drawn.count) pictures on \(layout.pageRanges.count) pages")
        let picture = try #require(drawn.first)
        // As tall as the page takes: within a line of text of its height.
        #expect(picture.rect.height > 503 - fontSize * lineHeightMultiple, "\(picture.rect)")
        #expect(picture.rect.maxY <= Self.page.height - insets.bottom + 0.5, "\(picture.rect)")
    }
}

private final class PortraitPictureChapterProvider: BookContentProvider {
    private let html: String

    init(html: String) {
        self.html = html
    }

    var totalChapters: Int { 1 }

    func chapterTitle(at index: Int) -> String { "第1章" }

    func contentForChapter(index: Int) async throws -> ChapterContentPayload {
        ChapterContentPayload(
            index: 0,
            title: "第1章",
            plainText: "",
            body: .html(html),
            sourceHref: "https://example.com/1"
        )
    }
}
