import UIKit

/// How a page bitmap draws a template card that has glass panels (`ReviewCardImage`).
///
/// The system's glass samples what is behind it as it is shown, so it lives in a
/// `ReviewCardGlassView` over the page, never in a bitmap. A bitmap under that view must leave
/// the card out, or the glass would refract the card's own text.
enum ReviewCardGlassDrawing: Sendable {
    /// A page on screen: the card is left to its `ReviewCardGlassView`.
    case liveViews
    /// A picture of the page that no view sits on — curl back pages, cover-transition and
    /// auto-read snapshots: the card is drawn over a still stand-in for its glass.
    case baked
}

extension CoreTextPaginator.RenderedAttachment {
    /// The card image when this attachment is a template card with glass panels.
    var reviewCardGlassImage: ReviewCardImage? {
        guard let card = image as? ReviewCardImage, !card.glassPanels.isEmpty else { return nil }
        return card
    }

    /// Draws the attachment as `glassCards` says a glass card is drawn; anything else as always.
    func draw(glassCards: ReviewCardGlassDrawing) {
        guard let card = reviewCardGlassImage else {
            image.draw(in: rect, blendMode: .normal, alpha: opacity)
            return
        }
        guard glassCards == .baked else { return }
        let isNight = card.isNight
        for panel in card.glassPanels {
            let placed = panel.placed(in: rect, imageSize: card.size)
            let path = UIBezierPath(roundedRect: placed.rect, cornerRadius: placed.cornerRadius)
            UIColor.white.withAlphaComponent(isNight ? 0.1 : 0.5).setFill()
            path.fill()
            UIColor.white.withAlphaComponent(isNight ? 0.18 : 0.8).setStroke()
            path.lineWidth = 0.5
            path.stroke()
        }
        image.draw(in: rect, blendMode: .normal, alpha: opacity)
    }
}

extension CoreTextPaginator.ChapterLayout {
    /// The glass cards on `pageIndex`, each once: a block card can be listed both as a block
    /// attachment and as a block renderable's image.
    func reviewCardGlassAttachments(onPage pageIndex: Int) -> [CoreTextPaginator.RenderedAttachment] {
        let all = (inlineAttachments[pageIndex] ?? [])
            + (blockAttachments[pageIndex] ?? [])
            + (blockRenderables[pageIndex] ?? []).compactMap(\.imageAttachment)
        return ReviewCardGlassView.uniqueGlassCards(all)
    }
}

extension ReviewCardGlassView {
    nonisolated static func uniqueGlassCards(
        _ attachments: [CoreTextPaginator.RenderedAttachment]
    ) -> [CoreTextPaginator.RenderedAttachment] {
        var seen: [(ObjectIdentifier, CGRect)] = []
        return attachments.filter { attachment in
            guard let card = attachment.reviewCardGlassImage else { return false }
            let key = (ObjectIdentifier(card), attachment.rect)
            guard !seen.contains(where: { $0.0 == key.0 && $0.1 == key.1 }) else { return false }
            seen.append(key)
            return true
        }
    }
}
