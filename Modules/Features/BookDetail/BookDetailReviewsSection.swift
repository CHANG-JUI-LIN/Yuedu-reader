import SwiftUI

/// 讀者評論 on 作品詳情 (maintainer, 2026-11-14: as Apple Books' store draws it): a title that
/// opens every review, over a row of cards. Not shown at all until reviews are read, nor when a
/// module has none of the work: no header over a spinner that could then vanish and move the
/// page. Only what the module's site gave is drawn — a review without a rating has no stars.
struct BookDetailReviewsSection: View {
    let reviews: WorkReviewSet?
    let onShowAll: (WorkReviewSet) -> Void

    var body: some View {
        if let reviews, !reviews.reviews.isEmpty {
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                BookDetailSectionHeader(title: localized("讀者評論"), actionTitle: localized("查看全部"),
                                        action: { onShowAll(reviews) })
                    .padding(.horizontal, DSSpacing.lg)
                    .accessibilityIdentifier("detail.reviews.header")
                ReviewCardRow(reviews: Array(reviews.reviews.prefix(DSLayout.reviewPreviewCount)),
                              onSelect: { onShowAll(reviews) })
                BookDetailSectionRule()
                    .padding(.horizontal, DSSpacing.lg)
            }
        }
    }
}

/// The first reviews side by side, each as tall as the tallest. Not lazy: a handful of cards,
/// and a lazy stack would neither size them alike nor keep them all in VoiceOver's order.
private struct ReviewCardRow: View {
    let reviews: [WorkReview]
    let onSelect: () -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: DSSpacing.md) {
                // By position: two readers can write the same words.
                ForEach(reviews.indices, id: \.self) { index in
                    let review = reviews[index]
                    Button(action: onSelect) {
                        WorkReviewCard(review: review, isPreview: true)
                            .containerRelativeFrame(.horizontal) { width, _ in
                                min(max(width - DSLayout.reviewCardPeek, 0), DSLayout.reviewCardMaxWidth)
                            }
                    }
                    .buttonStyle(ExploreTileButtonStyle())
                    .accessibilityLabel(review.spokenText(locale: locale))
                    .accessibilityHint(localized("查看全部"))
                    .accessibilityIdentifier("detail.reviews.card")
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .contentMargins(.horizontal, DSSpacing.lg, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollClipDisabled()
    }
}

/// One reader's review: its headline if it has one, its text, then its stars, day and writer —
/// each only when the site gave it. A writer the site gives a picture, a 粉絲稱號 or a floor is
/// named above the text, as 起點's comment list does; the replies the page showed under it
/// follow (not in 作品詳情's row).
struct WorkReviewCard: View {
    let review: WorkReview
    /// In 作品詳情's row: a few lines, and as tall as its neighbours.
    var isPreview = false
    /// Draws the replies under it; off for the comment a replies list is headed by.
    var showsReplies = true
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.commentListLook) private var listLook
    /// Sizes a style sets grow with the reader's Dynamic Type, as the App's own text does.
    @ScaledMetric(relativeTo: .subheadline) private var fontScale: CGFloat = 1

    var body: some View {
        let look = listLook.resolved(isDark: colorScheme == .dark, fontScale: fontScale)
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            if review.hasPersona {
                personaHeader(look)
            }
            if let title = review.title {
                Text(verbatim: title)
                    .font(DSFont.subheadline.weight(.semibold))
                    .foregroundStyle(look.text.color)
                    .lineLimit(isPreview ? 1 : 2)
            }
            if !isPreview, look.shows(.quote), let quote = review.quote {
                quoteView(quote, look: look)
            }
            Text(verbatim: review.text)
                .font(look.text.font)
                .foregroundStyle(look.text.color)
                .lineSpacing(look.textLineSpacing)
                .tracking(look.textTracking)
                .lineLimit(isPreview ? DSLayout.reviewCardPreviewLines : look.textLineLimit)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, maxHeight: isPreview ? .infinity : nil, alignment: .topLeading)
            if !isPreview, look.shows(.images), let images = review.images, !images.isEmpty {
                CommentImageStrip(urls: images)
            }
            if !isPreview, look.shows(.voice), let voice = review.voice {
                CommentVoiceButton(url: voice, tint: look.badgeText, fill: look.badgeFill)
            }
            footer(look)
            if !isPreview, showsReplies, look.inlineReplies > 0, let replies = review.replies, !replies.isEmpty {
                inlineReplies(Array(replies.prefix(look.inlineReplies)), look: look)
            }
        }
        .padding(look.padding)
        .frame(maxWidth: .infinity, maxHeight: isPreview ? .infinity : nil, alignment: .topLeading)
        .background(look.cardFill, in: RoundedRectangle(cornerRadius: look.cornerRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: look.cornerRadius, style: .continuous))
    }

    /// Stars, the day (or the site's own when-and-where), the writer when the header does not
    /// name them, and the likes.
    @ViewBuilder
    private func footer(_ look: CommentListLook.Resolved) -> some View {
        let byline = review.byline(locale: locale, includesAuthor: !review.hasPersona, includesWhen: look.shows(.meta))
        let likes = look.shows(.likes) ? review.likes : nil
        if review.rating != nil || !byline.isEmpty || likes != nil {
            HStack(spacing: DSSpacing.sm) {
                if let rating = review.rating {
                    WorkRatingStars(rating: rating)
                        .font(DSFont.footnote)
                        .foregroundStyle(DSColor.textSecondary)
                }
                Text(verbatim: byline)
                    .font(look.meta.font)
                    .foregroundStyle(look.meta.color)
                    .lineLimit(1)
                if let likes {
                    Spacer(minLength: DSSpacing.sm)
                    HStack(spacing: DSSpacing.xs) {
                        Image(systemName: "hand.thumbsup")
                            .accessibilityHidden(true)
                        Text(likes, format: .number)
                            .monospacedDigit()
                    }
                    .font(look.likes.font)
                    .foregroundStyle(look.likes.color)
                }
            }
        }
    }

    /// Picture, name, 作者 and 粉絲稱號, and the floor at the far end.
    private func personaHeader(_ look: CommentListLook.Resolved) -> some View {
        HStack(spacing: DSSpacing.sm) {
            if look.shows(.avatar), let avatar = review.avatar {
                CommentAvatarImage(url: avatar)
                    .frame(width: look.avatarSize, height: look.avatarSize)
                    .clipShape(RoundedRectangle(cornerRadius: look.avatarCornerRadius ?? look.avatarSize / 2,
                                                style: .continuous))
                    .accessibilityHidden(true)
            }
            if let author = review.author {
                Text(verbatim: author)
                    .font(look.name.font)
                    .foregroundStyle(look.name.color)
                    .lineLimit(1)
            }
            if look.shows(.author), review.isAuthor == true {
                CommentWriterBadge(text: localized("作者"), tint: look.authorText, fill: look.authorFill)
            }
            if look.shows(.badge), let badge = review.badge {
                CommentWriterBadge(text: badge, tint: look.badgeText, fill: look.badgeFill)
            }
            Spacer(minLength: DSSpacing.sm)
            if look.shows(.floor), let floor = review.floorText {
                Text(verbatim: floor)
                    .font(look.floor.font)
                    .foregroundStyle(look.floor.color)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
        }
    }

    /// The book's words it answers, set off by a bar.
    private func quoteView(_ quote: String, look: CommentListLook.Resolved) -> some View {
        Text(verbatim: quote)
            .font(look.quote.font)
            .foregroundStyle(look.quote.color)
            .lineLimit(DSLayout.commentQuoteLines)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, DSSpacing.sm + look.quoteBarWidth)
            .padding(.vertical, look.quoteFill == nil ? 0 : DSSpacing.xs)
            .padding(.trailing, look.quoteFill == nil ? 0 : DSSpacing.sm)
            .overlay(alignment: .leading) {
                Capsule().fill(look.quoteBar).frame(width: look.quoteBarWidth)
            }
            .background {
                if let fill = look.quoteFill {
                    RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous).fill(fill)
                }
            }
    }

    /// The first replies, each its writer's name then its words, on a ground of their own.
    private func inlineReplies(_ replies: [WorkReview], look: CommentListLook.Resolved) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            // By position: two readers can write the same words.
            ForEach(replies.indices, id: \.self) { index in
                Text(replies[index].inlineReplyText)
                    .font(look.reply.font)
                    .foregroundStyle(look.reply.color)
                    .lineLimit(DSLayout.commentInlineReplyLines)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(DSSpacing.md)
        .background(look.replyFill, in: RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous))
    }
}

/// A title by a comment writer's name — the site's 粉絲稱號, or 作者 — as a small capsule.
struct CommentWriterBadge: View {
    let text: String
    var tint: Color = DSColor.accent
    var fill: Color = DSColor.accentLight

    var body: some View {
        Text(verbatim: text)
            .font(DSFont.caption2.weight(.medium))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, DSSpacing.xs)
            .padding(.vertical, DSSpacing.xxs)
            .background(fill, in: Capsule())
    }
}

/// A comment's picture — its writer's, or one it carries — through the covers' cache; a
/// symbol while it loads or when it cannot.
struct CommentAvatarImage: View {
    let url: URL
    var placeholder = "person.crop.circle.fill"
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image = image ?? BookCoverLoader.cachedImage(for: url.absoluteString) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: placeholder)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(DSColor.textTertiary)
            }
        }
        .task(id: url) {
            image = await BookCoverLoader.loadImage(urlString: url.absoluteString, headers: [:])
        }
    }
}

/// A rating as five stars, to the nearest half. Drawn only: its number is spoken by whatever
/// holds it.
struct WorkRatingStars: View {
    let rating: Double

    var body: some View {
        HStack(spacing: 0) {
            ForEach(1...WorkRating.stars, id: \.self) { star in
                Image(systemName: Self.symbol(for: star, rating: rating))
            }
        }
        .accessibilityHidden(true)
    }

    /// Full from its own number up, half from half a star below it.
    static func symbol(for star: Int, rating: Double) -> String {
        let halves = (rating * 2).rounded()
        if halves >= Double(star * 2) { return "star.fill" }
        return halves >= Double(star * 2 - 1) ? "star.leadinghalf.filled" : "star"
    }
}

extension WorkReview {
    /// 「2025年1月2日 · 讀者名」, each part only when the review has it. The day is the one the
    /// site wrote: its date is read as UTC (`RuleModuleClient.date`), so it is shown in UTC too,
    /// never a day later for a reader east of it.
    /// The site's own when-and-where (`meta`) stands for the day when it has one.
    func byline(locale: Locale, includesAuthor: Bool = true, includesWhen: Bool = true) -> String {
        let day = date.map { $0.formatted(Date.FormatStyle(date: .long, time: .omitted, locale: locale, timeZone: .gmt)) }
        return [includesWhen ? meta ?? day : nil, includesAuthor ? author : nil].compactMap { $0 }.joined(separator: " · ")
    }

    /// The site named its writer the way a comment list does: a picture, a title, a floor.
    var hasPersona: Bool { avatar != nil || badge != nil || floor != nil || isAuthor == true }

    /// 「3 樓」 for a floor the site wrote as a number; its own words (`沙發`) otherwise.
    var floorText: String? {
        guard let floor else { return nil }
        let number = floor.trimmingCharacters(in: CharacterSet(charactersIn: "#＃ "))
        guard !number.isEmpty, number.allSatisfy({ $0.isASCII && $0.isNumber }) else { return floor }
        return String(format: localized("%@ 樓"), number)
    }

    /// A reply under its comment: 「名字：內容」, the name in bold.
    var inlineReplyText: AttributedString {
        guard let author else { return AttributedString(text) }
        var name = AttributedString(author)
        name.inlinePresentationIntent = .stronglyEmphasized
        return name + AttributedString(localized("：") + text)
    }

    /// The card as VoiceOver reads it: writer and titles, floor, headline, quote, text,
    /// pictures and voice, rating, day, likes, then the replies it shows.
    /// What 評論列表 hides (`hidden`) is not read either.
    func spokenText(locale: Locale, inlineReplies: Int = DSLayout.commentInlineReplies,
                    hidden: Set<CommentListPart> = []) -> String {
        func shown(_ part: CommentListPart) -> Bool { !hidden.contains(part) }
        var parts: [String] = []
        if hasPersona {
            parts.append([author, shown(.author) && isAuthor == true ? localized("作者") : nil, shown(.badge) ? badge : nil]
                .compactMap { $0 }.joined(separator: " "))
            if shown(.floor), let floorText { parts.append(floorText) }
        }
        if let title { parts.append(title) }
        if shown(.quote), let quote { parts.append(String(format: localized("引用：%@"), quote)) }
        parts.append(text)
        if shown(.images), let images, !images.isEmpty { parts.append(String(format: localized("%d 張配圖"), images.count)) }
        if shown(.voice), voice != nil { parts.append(localized("有語音")) }
        if let rating { parts.append(WorkRating.spoken(rating, locale: locale)) }
        let byline = byline(locale: locale, includesAuthor: !hasPersona, includesWhen: shown(.meta))
        if !byline.isEmpty { parts.append(byline) }
        if shown(.likes), let likes { parts.append(String(format: localized("%d 人覺得有幫助"), likes)) }
        for reply in (replies ?? []).prefix(inlineReplies) {
            parts.append(String(format: localized("%@ 回覆：%@"), reply.author ?? localized("讀者"), reply.text))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

extension WorkRating {
    /// 「3.3」: one decimal, in the reader's numerals.
    static func text(_ stars: Double, locale: Locale) -> String {
        stars.formatted(.number.precision(.fractionLength(1)).locale(locale))
    }

    /// 「3.3 顆星，滿分 5 顆星」.
    static func spoken(_ stars: Double, locale: Locale) -> String {
        String(format: localized("%@ 顆星，滿分 %d 顆星"), text(stars, locale: locale), Self.stars)
    }
}

#if DEBUG
extension WorkReviewSet {
    static var preview: WorkReviewSet {
        let day = Date(timeIntervalSince1970: 1_735_776_000)
        return WorkReviewSet(moduleID: "preview", moduleTitle: "範例書評", reviews: [
            WorkReview(title: "子曰", text: "知之為知之，不知為不知，是知也。", author: "讀者甲", date: day, rating: 3, likes: 12),
            WorkReview(title: nil, text: "排版格式非常適合閱讀，內容也很有啟發性。\n第二段說得更細，值得慢慢讀。", author: "南山泉",
                       date: day.addingTimeInterval(-86_400 * 400), rating: nil, likes: nil),
            WorkReview(title: "超好看", text: "真的很有趣", author: nil, date: nil, rating: 4.5, likes: 1),
        ], rating: WorkRating(score: 3.3, count: 1_059, distribution: [320, 210, 180, 150, 199]))
    }
}

#Preview("讀者評論") {
    ScrollView {
        BookDetailReviewsSection(reviews: .preview, onShowAll: { _ in })
            .padding(.vertical, DSSpacing.lg)
    }
}

#Preview("讀者評論 · 沒有星數和日期") {
    ScrollView {
        BookDetailReviewsSection(
            reviews: WorkReviewSet(moduleID: "preview", moduleTitle: "範例", reviews: [
                WorkReview(text: "從這本開始入坑。"), WorkReview(text: "good book, recommend to read", author: "scouthe"),
            ], rating: nil),
            onShowAll: { _ in })
            .padding(.vertical, DSSpacing.lg)
    }
}
#endif
