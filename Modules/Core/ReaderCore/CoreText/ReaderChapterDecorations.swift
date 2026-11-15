import Foundation
import UIKit

/// A module's comments on a chapter, on the chapter's own paragraphs: 段評 bubbles, 熱評
/// cards and the cards after the chapter (作者說, 本章說). What to draw and what a tap opens,
/// not how: each layout engine draws them its own way (`ReaderCommentPieces` for a chapter
/// document, `BrowserChapterAdditions` for a chapter the browser engine lays out).
struct ReaderCommentPlacements: Equatable, Sendable {
    /// A count at the end of a paragraph.
    struct Bubble: Equatable, Sendable {
        var count: Int
        /// `ReaderHTMLUtilities.moduleReviewHref`: what the tap opens.
        var href: String
        var title: String
    }

    /// A card on a line of its own.
    struct Card: Equatable, Sendable {
        var content: ReviewCardContent
        var href: String
    }

    /// By the paragraph's position in the list the source was asked with.
    var bubbles: [Int: Bubble] = [:]
    /// Under a paragraph, by the same position.
    var cards: [Int: [Card]] = [:]
    /// After the chapter's last paragraph.
    var chapterEnd: [Card] = []

    var isEmpty: Bool { bubbles.isEmpty && cards.values.allSatisfy(\.isEmpty) && chapterEnd.isEmpty }
}

/// What a chapter is given beside its own text: a module's 段評 bubbles, 熱評 and 本章說 cards
/// (maintainer, 2026-11-15: these belong in the text, as a 來源配置's own are). However they are
/// drawn, none owns a character of the chapter: a bookmark, a highlight or the reading position
/// is where it was whether the comments have arrived, are off, or change.
@MainActor
protocol ReaderChapterDecorationSource: AnyObject {
    /// The chapter's comments on `paragraphs` — the chapter's paragraphs' text, in order, its
    /// title among them or not — or nil when it has none yet. A source that does not have a
    /// chapter's asks for them and says so later (the reader then lays the chapter out again).
    func placements(forSpine spineIndex: Int, title: String, paragraphs: [String]) -> ReaderCommentPlacements?
}

/// Draws the pieces a `ReaderChapterDecorationSource` adds, through the chapter renderer a
/// 來源配置's own bubbles and cards go through: the same bubble, the same card templates, the
/// same tap (`internalLinkAttribute`).
@MainActor
struct ReaderCommentPieces {
    let settings: ReaderRenderSettings
    let textColor: UIColor
    /// The column a card is drawn to.
    let columnWidth: CGFloat

    private func renderer(image: UIImage? = nil) -> NodeAttributedStringRenderer {
        NodeAttributedStringRenderer(config: .init(
            from: settings, textColor: textColor, fontFamily: UserReaderFontResolver.selectedPostScriptName,
            renderWidth: columnWidth, imageLoader: { _ in image }))
    }

    /// A 段評 bubble with `count` in it, for the end of the paragraph whose last character has
    /// `host`'s attributes: on that paragraph's line, in its paragraph style.
    func bubble(count: Int, href: String, title: String, host: [NSAttributedString.Key: Any]) async -> NSAttributedString {
        let rendered = await renderer().render([.commentBadge(count: String(min(count, 99)), reviewURL: href, title: title)])
        let piece = NSMutableAttributedString(attributedString: rendered)
        // The renderer ends a top-level run with its paragraph's line break; the bubble joins a
        // paragraph that has its own.
        while piece.string.hasSuffix("\n") { piece.deleteCharacters(in: NSRange(location: piece.length - 1, length: 1)) }
        guard piece.length > 0 else { return piece }
        if let style = host[.paragraphStyle] {
            piece.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: piece.length))
        }
        return piece
    }

    /// `placements` as the pieces spliced into `built`, the chapter as its builder made it, whose
    /// paragraphs (`ReaderTranslationText.paragraphs`) the source was asked with.
    func decorations(_ placements: ReaderCommentPlacements, in built: NSAttributedString,
                     paragraphs: [ReaderTranslationText.Paragraph]) async -> ReaderTranslationLayout.Decorations? {
        var decorations = ReaderTranslationLayout.Decorations()
        for (position, bubble) in placements.bubbles.sorted(by: { $0.key < $1.key }) {
            guard paragraphs.indices.contains(position), paragraphs[position].range.length > 0 else { continue }
            let host = built.attributes(at: NSMaxRange(paragraphs[position].range) - 1, effectiveRange: nil)
            let piece = await self.bubble(count: bubble.count, href: bubble.href, title: bubble.title, host: host)
            guard piece.length > 0 else { continue }
            decorations.paragraphs[position, default: .init()].trailing = piece
        }
        for (position, cards) in placements.cards.sorted(by: { $0.key < $1.key }) where paragraphs.indices.contains(position) {
            for card in cards {
                let piece = await self.card(card.content, href: card.href)
                guard piece.length > 0 else { continue }
                decorations.paragraphs[position, default: .init()].below.append(piece)
            }
        }
        for card in placements.chapterEnd {
            decorations.chapterEnd.append(await self.card(card.content, href: card.href))
        }
        return decorations.isEmpty ? nil : decorations
    }

    /// Whether the chapter's source drew comments of its own: any review anchor in it. Such a
    /// chapter is left as it is: a second bubble on a paragraph helps nobody.
    static func hasSourceComments(_ built: NSAttributedString) -> Bool {
        var found = false
        built.enumerateAttribute(HTMLAttributedStringBuilder.internalLinkAttribute,
                                 in: NSRange(location: 0, length: built.length), options: []) { value, _, stop in
            if let href = value as? String, href.hasPrefix("\(ReaderHTMLUtilities.reviewURLScheme)://") {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    /// A card of `content`, on a line of its own, opening `href` when tapped. Empty when the
    /// card cannot be drawn.
    func card(_ content: ReviewCardContent, href: String) async -> NSAttributedString {
        let font = UIFont(name: UserReaderFontResolver.selectedPostScriptName ?? "", size: settings.fontSize)
            ?? .systemFont(ofSize: settings.fontSize)
        guard let image = await ReviewCardRaster.image(card: content, columnWidth: columnWidth,
                                                       reader: .init(font: font, textColor: textColor)) else {
            return NSAttributedString()
        }
        return await renderer(image: image).render([
            .block(tag: "yd-review-full", children: [
                .anchor(href: href, children: [.image(src: "ydcard:\(content.kind.rawValue)", alt: content.title)]),
            ]),
        ])
    }
}
