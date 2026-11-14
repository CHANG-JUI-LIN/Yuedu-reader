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
/// each only when the site gave it.
struct WorkReviewCard: View {
    let review: WorkReview
    /// In 作品詳情's row: a few lines, and as tall as its neighbours.
    var isPreview = false
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            if let title = review.title {
                Text(verbatim: title)
                    .font(DSFont.subheadline.weight(.semibold))
                    .foregroundStyle(DSColor.textPrimary)
                    .lineLimit(isPreview ? 1 : 2)
            }
            Text(verbatim: review.text)
                .font(DSFont.subheadline)
                .foregroundStyle(DSColor.textPrimary)
                .lineLimit(isPreview ? DSLayout.reviewCardPreviewLines : nil)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, maxHeight: isPreview ? .infinity : nil, alignment: .topLeading)
            if review.rating != nil || !review.byline(locale: locale).isEmpty || review.likes != nil {
                HStack(spacing: DSSpacing.sm) {
                    if let rating = review.rating {
                        WorkRatingStars(rating: rating)
                    }
                    Text(verbatim: review.byline(locale: locale))
                        .lineLimit(1)
                    if let likes = review.likes {
                        Spacer(minLength: DSSpacing.sm)
                        HStack(spacing: DSSpacing.xs) {
                            Image(systemName: "hand.thumbsup")
                                .accessibilityHidden(true)
                            Text(likes, format: .number)
                                .monospacedDigit()
                        }
                    }
                }
                .font(DSFont.footnote)
                .foregroundStyle(DSColor.textSecondary)
            }
        }
        .padding(DSSpacing.lg)
        .frame(maxWidth: .infinity, maxHeight: isPreview ? .infinity : nil, alignment: .topLeading)
        .background(DSColor.quietCardFill, in: RoundedRectangle(cornerRadius: DSRadius.xl, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: DSRadius.xl, style: .continuous))
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
    func byline(locale: Locale) -> String {
        let day = date.map { $0.formatted(Date.FormatStyle(date: .long, time: .omitted, locale: locale, timeZone: .gmt)) }
        return [day, author].compactMap { $0 }.joined(separator: " · ")
    }

    /// The card as VoiceOver reads it: headline, text, rating, day and writer.
    func spokenText(locale: Locale) -> String {
        var parts = [title, text].compactMap { $0 }
        if let rating { parts.append(WorkRating.spoken(rating, locale: locale)) }
        let byline = byline(locale: locale)
        if !byline.isEmpty { parts.append(byline) }
        if let likes { parts.append(String(format: localized("%d 人覺得有幫助"), likes)) }
        return parts.joined(separator: "\n")
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
