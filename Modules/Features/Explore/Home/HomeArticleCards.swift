import SwiftUI

// Unified library 5g: 訂閱的最新文章's articles on Explore's home (Phase 5 plan, decision 26).
// An article is not a book (design §13.8), so it has no cover, no author and no progress: the
// book layouts would show a 2:3 jacket and 書籍・ for it. Two looks instead, by the family the
// section's 呈現方式 belongs to:
// - 圖文資訊清單 (ranked or not): rows as the RSS tab's, the picture at the trailing end;
// - every sideways or grid layout: one row of landscape cards that swipes sideways.

struct HomeArticleCards: View {
    let layout: HomeSectionLayout
    let articles: [SubscriptionArticle]
    let open: (SubscriptionArticle) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .subheadline) private var cardWidth = DSLayout.homeArticleCardWidth
    @ScaledMetric(relativeTo: .headline) private var thumbnailWidth = DSLayout.homeListCoverWidth

    var body: some View {
        if layout.style == .list {
            list
        } else {
            rail
        }
    }

    private func button(_ article: SubscriptionArticle, @ViewBuilder label: () -> some View) -> some View {
        Button { open(article) } label: { label() }
            .buttonStyle(ExploreTileButtonStyle())
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(article.title)
            .accessibilityValue(article.accessibilityValue)
            .accessibilityIdentifier("home.article.\(article.id)")
    }

    // MARK: Sideways

    private var rail: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: DSSpacing.md) {
                ForEach(articles.indices, id: \.self) { index in
                    button(articles[index]) {
                        HomeArticleCard(article: articles[index], width: min(cardWidth, DSLayout.homeArticleCardMaxWidth))
                    }
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, DSSpacing.lg, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }

    // MARK: 圖文資訊清單

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(articles.indices, id: \.self) { index in
                let rank = layout.showsRanks ? index + 1 : nil
                button(articles[index]) {
                    HomeArticleRow(article: articles[index], rank: rank, thumbnailWidth: thumbnailWidth,
                                   stacksVertically: dynamicTypeSize.isAccessibilitySize)
                }
                if index < articles.count - 1 { Divider() }
            }
        }
        .padding(.horizontal, DSSpacing.lg)
    }
}

extension SubscriptionArticle {
    /// The feed, when, and 未讀 as the card's dot shows it; the title is the label.
    var accessibilityValue: String {
        [feedName, dateText, isRead ? "" : localized("未讀")].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    var dateText: String {
        date.formatted(.relative(presentation: .named))
    }

    /// The feed's name, then when: 「少數派 · 3 小時前」.
    var feedAndDate: String {
        [feedName, dateText].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// The unread dot: the RSS tab's mark, with the words for VoiceOver on the card's value.
private struct HomeArticleUnreadDot: View {
    @ScaledMetric(relativeTo: .caption) private var side = DSLayout.homeArticleUnreadDot

    var body: some View {
        Circle()
            .fill(DSColor.accent)
            .frame(width: side, height: side)
            .accessibilityHidden(true)
    }
}

/// An article's picture, or a plain surface with the feed symbol when it has none, so every
/// card in a row is the same height.
private struct HomeArticleImage: View {
    let url: URL?

    var body: some View {
        Rectangle()
            .fill(DSColor.surfaceTertiary)
            .overlay {
                if let url {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else if phase.error != nil {
                            symbol
                        }
                    }
                } else {
                    symbol
                }
            }
            .clipped()
            .accessibilityHidden(true)
    }

    private var symbol: some View {
        Image(systemName: "dot.radiowaves.up.forward")
            .font(DSFont.title2)
            .foregroundStyle(DSColor.textTertiary)
    }
}

/// One card of the sideways row: the picture, the feed and when, then the title.
struct HomeArticleCard: View {
    let article: SubscriptionArticle
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            HomeArticleImage(url: article.imageURL)
                .frame(width: width, height: width / DSLayout.homeArticleImageAspectRatio)
                .clipShape(RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous))
            HStack(spacing: DSSpacing.xs) {
                if !article.isRead { HomeArticleUnreadDot() }
                Text(article.feedAndDate)
                    .font(DSFont.caption)
                    .foregroundStyle(DSColor.textSecondary)
                    .lineLimit(1)
            }
            // Three lines kept even when shorter, so the cards line up.
            Text(article.title)
                .font(DSFont.subheadline.weight(.semibold))
                .foregroundStyle(DSColor.textPrimary)
                .lineLimit(3, reservesSpace: true)
                .multilineTextAlignment(.leading)
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// One row of 圖文資訊清單: the title, the feed and when, the picture at the trailing end.
struct HomeArticleRow: View {
    let article: SubscriptionArticle
    let rank: Int?
    let thumbnailWidth: CGFloat
    var stacksVertically = false

    var body: some View {
        let layout = stacksVertically
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: DSSpacing.sm))
            : AnyLayout(HStackLayout(alignment: .top, spacing: DSSpacing.md))
        layout {
            VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                if let rank {
                    HomeRankBadge(rank: rank)
                        .padding(.bottom, DSSpacing.xxs)
                }
                Text(article.title)
                    .font(DSFont.subheadline.weight(.semibold))
                    .foregroundStyle(DSColor.textPrimary)
                    .lineLimit(2)
                HStack(spacing: DSSpacing.xs) {
                    if !article.isRead { HomeArticleUnreadDot() }
                    Text(article.feedAndDate)
                        .font(DSFont.caption)
                        .foregroundStyle(DSColor.textSecondary)
                        .lineLimit(1)
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            if article.imageURL != nil {
                HomeArticleImage(url: article.imageURL)
                    .frame(width: thumbnailWidth, height: thumbnailWidth)
                    .clipShape(RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous))
            }
        }
        .padding(.vertical, DSSpacing.md)
        .contentShape(Rectangle())
    }
}

#Preview("訂閱的最新文章") {
    let articles = [
        SubscriptionArticle(id: "1", title: "一篇很長的文章標題，長到要換行才放得下，看看三行怎麼排", feedName: "少數派",
                            date: .now.addingTimeInterval(-3_600), imageURL: nil, isRead: false),
        SubscriptionArticle(id: "2", title: "Swift 6.2 的新功能", feedName: "Swift.org",
                            date: .now.addingTimeInterval(-86_400), imageURL: nil, isRead: true),
        SubscriptionArticle(id: "3", title: "短標題", feedName: "", date: .now.addingTimeInterval(-600),
                            imageURL: nil, isRead: false),
    ]
    ScrollView {
        VStack(alignment: .leading, spacing: DSSpacing.xxl) {
            HomeArticleCards(layout: .row, articles: articles, open: { _ in })
            HomeArticleCards(layout: .rankedList, articles: articles, open: { _ in })
        }
    }
}
