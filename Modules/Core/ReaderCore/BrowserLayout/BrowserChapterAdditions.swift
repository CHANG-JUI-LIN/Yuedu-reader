// Built only against a YueduCoreText that lays out pictures a client adds with no character of
// the chapter's source text (`BrowserAddedContent`, 0.19.0). On an older package every added
// picture would take a character and move each offset after it, so until the project asks for
// that version this file is compiled only when a build sets `YUEDU_ADDED_CONTENT` (a workspace
// build over the local package). Delete the condition with the version bump.
#if YUEDU_ADDED_CONTENT
import Foundation
import SwiftSoup
import UIKit
import YueduCoreText

/// A module's comments in a chapter the browser engine lays out (a reflowable EPUB's): the
/// chapter's HTML with a badge at the end of each commented paragraph and a card under it or
/// after the chapter, as `ReaderCommentPieces` draws them into a chapter document.
///
/// It stands between the engine and the book's own resource: every reader of a chapter's HTML
/// sees the same additions, and the pictures they name are served beside the book's. The
/// additions are `<img>` elements the package gives no character of the source text
/// (`BrowserAddedContent`), so a position, a bookmark or a highlight is where it was whether
/// the comments have arrived or not.
@MainActor
final class BrowserChapterAdditions: BrowserLayoutResourceProviding {
    /// A picture an added element names.
    enum Picture: Equatable {
        case bubble(count: Int)
        case card(ReviewCardContent)
    }

    /// Sources of added pictures: no publication resource has this scheme.
    nonisolated static let scheme = "yd-added"

    private let base: any BrowserLayoutResourceProviding
    weak var source: (any ReaderChapterDecorationSource)?
    /// The settings the chapter is laid out with now: a picture is drawn at the reading size,
    /// in the theme's text colour.
    var settings: () -> ReaderRenderSettings? = { nil }
    private var pictures: [Int: [String: Picture]] = [:]

    init(base: any BrowserLayoutResourceProviding, source: (any ReaderChapterDecorationSource)?) {
        self.base = base
        self.source = source
    }

    // MARK: - The book's own

    var chapterCount: Int { base.chapterCount }
    var declaredLanguage: String? { base.declaredLanguage }
    func chapterTitle(at index: Int) -> String { base.chapterTitle(at: index) }
    func chapterSourceHref(at index: Int) -> String? { base.chapterSourceHref(at: index) }
    func resolveMediaAttachment(forChapter index: Int, media: EPUBMediaAttachment) -> EPUBMediaAttachment {
        base.resolveMediaAttachment(forChapter: index, media: media)
    }
    func cssFrontendInput(forChapter index: Int, html: String) async -> CSSFrontendInput {
        await base.cssFrontendInput(forChapter: index, html: html)
    }
    func prepareFonts(requests: Set<BrowserFontRequest>) async { await base.prepareFonts(requests: requests) }
    func fontResolver() -> BrowserFontResolver? { base.fontResolver() }

    // MARK: - With the comments

    func chapterHTML(at index: Int) async throws -> String {
        let html = try await base.chapterHTML(at: index)
        guard let source else { return html }
        let title = base.chapterTitle(at: index)
        guard let added = Self.inject(into: html, spine: index, placements: { paragraphs in
            source.placements(forSpine: index, title: title, paragraphs: paragraphs)
        }) else {
            pictures[index] = nil
            return html
        }
        pictures[index] = added.pictures
        return added.html
    }

    func prefetchImages(forChapter index: Int, html: String, renderWidth: CGFloat) async -> [String: UIImage] {
        var images = await base.prefetchImages(forChapter: index, html: html, renderWidth: renderWidth)
        for (name, picture) in pictures[index] ?? [:] where html.contains(name) {
            images[name] = await image(of: picture, renderWidth: renderWidth)
        }
        return images
    }

    func loadImage(forChapter index: Int, source: String, renderWidth: CGFloat) async -> UIImage? {
        if let picture = pictures[index]?[source] { return await image(of: picture, renderWidth: renderWidth) }
        return await base.loadImage(forChapter: index, source: source, renderWidth: renderWidth)
    }

    // MARK: - Pictures

    private func image(of picture: Picture, renderWidth: CGFloat) async -> UIImage? {
        guard let settings = settings() else { return nil }
        switch picture {
        case .bubble(let count):
            return Self.bubbleImage(count: count, pointSize: settings.fontSize, textColor: settings.textColor)
        case .card(let content):
            let font = UIFont(name: UserReaderFontResolver.selectedPostScriptName ?? "", size: settings.fontSize)
                ?? .systemFont(ofSize: settings.fontSize)
            return await ReviewCardRaster.image(card: content, columnWidth: max(1, renderWidth),
                                                reader: .init(font: font, textColor: settings.textColor))
        }
    }

    /// How far above the baseline the middle of a line's text is, in ems: where a 段評 bubble is
    /// centred in a chapter document (`CoreTextPaginator.textSizedImageBottom`).
    nonisolated static let textMiddle: CGFloat = 0.38

    /// The app's own bubble with `count` in it, on a canvas that sets it on the line as a
    /// chapter document does. The package sets an inline picture's bottom on the baseline and
    /// has no `vertical-align` for one, so the room under the bubble is part of the picture:
    /// its middle then sits at the text's.
    static func bubbleImage(count: Int, pointSize: CGFloat, textColor: UIColor) -> UIImage? {
        guard let bubble = CommentBubbleSVGRecognizer.commentBadgeImage(
            count: String(min(count, 99)), pointSize: pointSize, themeTextColor: textColor),
            bubble.size.width > 0, bubble.size.height > 0 else { return nil }
        // The picture is drawn `bubbleWidthEm` wide, so one em is this many of its points.
        let em = bubble.size.width / bubbleWidthEm
        let under = max(0, textMiddle * em - bubble.size.height / 2)
        let canvas = CGSize(width: bubble.size.width, height: bubble.size.height + under)
        let format = UIGraphicsImageRendererFormat()
        format.scale = bubble.scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: canvas, format: format).image { _ in bubble.draw(at: .zero) }
    }

    /// A bubble's width in ems: a full-width character's, by the reader's 氣泡大小, as in a
    /// chapter document (`NodeAttributedStringRenderer.textSizedImageWidth`).
    static var bubbleWidthEm: CGFloat {
        let settings = GlobalSettings.snapshot
        return settings.commentBubbleFollowsSourceSVG ? 1 : min(max(CGFloat(settings.commentBubbleScale), 0.5), 2)
    }

    // MARK: - Injection

    /// Elements that hold a paragraph of the chapter when no other of them is inside.
    private static let blocks = "p, div, li, blockquote, h1, h2, h3, h4, h5, h6, dd, dt"

    /// `html` with the comments `placements` gives for its paragraphs' text, and the pictures the
    /// added elements name. Nil when there is nothing to add.
    ///
    /// The document is parsed as the package parses it (`SwiftSoup.parse`) and written back
    /// without reformatting, so the package reads the same text nodes it would read from `html`:
    /// the chapter's source text is the same with and without the additions
    /// (`BrowserChapterAdditionsTests`).
    static func inject(into html: String, spine: Int,
                       placements: ([String]) -> ReaderCommentPlacements?) -> (html: String, pictures: [String: Picture])? {
        do {
            let document = try SwiftSoup.parse(html)
            guard let body = document.body() else { return nil }
            let paragraphs = try body.select(blocks).array().filter { try $0.select(blocks).size() == 1 }
            let texts = paragraphs.map(text(of:))
            guard let placements = placements(texts), !placements.isEmpty else { return nil }
            document.outputSettings().prettyPrint(pretty: false)

            var pictures: [String: Picture] = [:]
            var cardCount = 0
            func card(_ card: ReaderCommentPlacements.Card) -> String {
                cardCount += 1
                let name = "\(scheme):card/\(spine)/\(cardCount)"
                pictures[name] = .card(card.content)
                // A block of its own, as wide as the column; its height follows the picture's shape.
                return "<a href=\"\(escaped(card.href))\" style=\"display:block;margin:0.5em 0\">"
                    + "<img src=\"\(name)\" \(BrowserAddedContent.attributeName) style=\"display:block;width:100%\"></a>"
            }
            let width = String(format: "%.3f", Double(bubbleWidthEm))
            for (position, bubble) in placements.bubbles where paragraphs.indices.contains(position) {
                let name = "\(scheme):bubble/\(min(bubble.count, 99))"
                pictures[name] = .bubble(count: bubble.count)
                try paragraphs[position].append(
                    "<a href=\"\(escaped(bubble.href))\"><img src=\"\(name)\" \(BrowserAddedContent.attributeName)"
                        + " style=\"width:\(width)em;margin-left:0.15em\"></a>")
            }
            for (position, cards) in placements.cards where paragraphs.indices.contains(position) {
                try paragraphs[position].after(cards.map(card).joined())
            }
            if !placements.chapterEnd.isEmpty {
                try body.append(placements.chapterEnd.map(card).joined())
            }
            return (try document.outerHtml(), pictures)
        } catch {
            AppLogger.render("chapter comments: the chapter's HTML could not be read; it is laid out without them",
                             context: ["spine": spine, "error": String(describing: error)])
            return nil
        }
    }

    /// A paragraph's own text: without a ruby's reading, which no site's quote of the paragraph has.
    private static func text(of element: Element) -> String {
        var text = ""
        func walk(_ node: Node) {
            if let node = node as? TextNode {
                text += node.getWholeText()
            } else if let element = node as? Element, !["rt", "rp"].contains(element.tagName().lowercased()) {
                element.getChildNodes().forEach(walk)
            }
        }
        walk(element)
        return text
    }

    private static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
#endif
