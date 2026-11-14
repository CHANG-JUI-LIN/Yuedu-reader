import SwiftUI

// 主打卡片 (maintainer, 2026-11-14: the default home follows Apple Books' store, which opens on a
// carousel of wide cards; 「欄目不存在就先設計欄目」, 1:1 from a recording of it). A book a page, the
// next one peeking: a small line over a headline of two lines, then a wide card. The store's
// cards are its editors' artwork and sentences; ours are made from the book alone, as the store
// draws a single book — its cover standing in the middle of a card of the cover's own colour —
// with its author over its title.

/// One book as the store's leading card.
struct HomeHeroCard: View {
    let content: HomeCardContent

    @Environment(\.colorSchemeContrast) private var contrast
    /// The cover's average colour, once the cover has drawn.
    @State private var coverColor: CoverTint.RGB?

    /// The line over the title: the author, or what kind of book it is where no author is known.
    private var eyebrow: String {
        content.author.isEmpty ? content.category ?? "" : content.author
    }

    /// The card's colour, the cover's own, as 色帶書架's band is (`CoverTint.blockGround`); the
    /// placeholder grey until the cover has drawn.
    private var ground: Color {
        guard let coverColor else { return DSColor.coverTintPlaceholder }
        return CoverTint.blockGround(for: coverColor, increasedContrast: contrast == .increased).color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Its line kept where a book has neither, so every card's headline starts level.
            Text(eyebrow.isEmpty ? " " : eyebrow)
                .font(DSFont.caption2.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(DSColor.textPrimary)
                .lineLimit(1)
            Text(content.title)
                .font(DSFont.title3.weight(.bold))
                .foregroundStyle(DSColor.textPrimary)
                .multilineTextAlignment(.leading)
                // Two lines kept, so every card stands on one line.
                .lineLimit(2, reservesSpace: true)
                .padding(.top, DSSpacing.xs)
            card
                .padding(.top, DSSpacing.md)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous)
        return Color.clear
            .aspectRatio(DSLayout.homeHeroCardAspect, contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    let height = proxy.size.height * DSLayout.homeHeroCoverShare
                    HomeCardCover(cover: content.cover, title: content.title, author: content.author,
                                  size: CGSize(width: height * DSLayout.discoverCoverAspectRatio, height: height))
                        .modifier(PublicLibraryCoverAnchor(id: content.publicLibraryBookID))
                        .environment(\.coverImageObserver, { image in
                            Task {
                                let color = await Task.detached(priority: .utility) { CoverTint.average(of: image) }.value
                                if color != coverColor { coverColor = color }
                            }
                        })
                        .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                }
            }
            .background(ground)
            .clipShape(shape)
            .shadow(color: DSColor.shadow, radius: DSLayout.exploreCardShadowRadius, y: DSLayout.exploreCardShadowY)
            .contentShape(shape)
            .animation(DSAnimation.standard, value: coverColor)
    }
}

#if DEBUG
#Preview("主打卡片") {
    ScrollView {
        HomeSectionCards(layout: .heroCards, cards: HomeLayoutSample.standard.cards(for: .heroCards), rowID: "preview",
                         hasShowAll: false, open: { _, _ in })
            .padding(.vertical, DSSpacing.lg)
    }
}

#Preview("主打卡片，載入中與輔助使用字級") {
    ScrollView {
        HomeSectionCards(layout: .heroCards, cards: (0..<3).map(HomeCardContent.placeholder), rowID: "loading",
                         hasShowAll: false, open: { _, _ in })
            .redacted(reason: .placeholder)
        HomeSectionCards(layout: .heroCards, cards: HomeLayoutSample.standard.cards(for: .heroCards), rowID: "large",
                         hasShowAll: false, open: { _, _ in })
            .environment(\.dynamicTypeSize, .accessibility3)
    }
}
#endif
