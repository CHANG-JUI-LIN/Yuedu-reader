import SwiftUI

// A series' page as Apple Books' store draws one (maintainer, 2026-11-14, from a screenshot of
// it; `Technotes/AppleBooksHomeLayouts-2026-10-25.md` §10): the series' books fanned upright on a
// block of the first one's colour, its name, its author and a line under them, one quiet button,
// then a row for each book. One layout for the series read on this device (`WorkDetailSeriesPage`)
// and the series a list's item stands for (`ListedSeriesPage`): each says what the rows hold.

/// The top of a series' page.
struct SeriesPageHero {
    var name: String
    /// Written plainly when no author has a page to open.
    var author: String
    var authorActions: [BookDetailAuthorAction] = []
    /// 「系列 · 5 本」, or 「系列」 alone where the count is not known.
    var meta: String
    /// The book the fan stands behind.
    var cover: HomeCardContent.Cover
    var coverTitle: String
    var coverAuthor: String
    var isSquare = false
    var fan: SeriesFan?
    var open: BookDetailAction
}

/// One book on a series' page.
struct SeriesPageRow: Identifiable {
    let id: String
    let cover: HomeCardContent.Cover
    /// Over the title: 「第 3 冊」, where the series numbers the book.
    var caption: String?
    let title: String
    /// For the cover drawn when the book has no artwork.
    var author = ""
    /// In a capsule at the row's end, where the store has the book's price: 新增, 已讀 42%.
    var status: String?
    let accessibilityLabel: String
    var accessibilityValue = ""
    /// Opens the book; nil for one that is only named, which is then no button.
    var open: (() -> Void)?
}

struct SeriesPageLayout<Filters: View>: View {
    let hero: SeriesPageHero
    let rows: [SeriesPageRow]
    /// Over the rows: 書籍｜有聲書, where the series has both.
    @ViewBuilder var filters: Filters

    var body: some View {
        BookDetailScaffold(title: hero.name, compactAction: hero.open) {
            BookDetailHero(artworkShape: hero.isSquare ? .square : .book,
                           cover: HomeCoverArtwork(cover: hero.cover, title: hero.coverTitle, author: hero.coverAuthor,
                                                   size: CGSize(width: DSLayout.seriesHeroCoverHeight * DSLayout.discoverCoverAspectRatio,
                                                                height: DSLayout.seriesHeroCoverHeight)),
                           title: hero.name, author: hero.author, meta: hero.meta,
                           primary: hero.open, secondary: nil, authorActions: hero.authorActions,
                           artworkHeight: DSLayout.seriesHeroCoverHeight,
                           seriesFan: hero.fan, quietPrimary: true)
        } content: {
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                filters
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        let face = SeriesVolumeRow(row: row, hasRule: row.id != rows.last?.id)
                        if let open = row.open {
                            Button(action: open) { face }
                                .buttonStyle(.plain)
                                .accessibilityLabel(row.accessibilityLabel)
                                .accessibilityValue(row.accessibilityValue)
                                .accessibilityIdentifier("detail.series.volume")
                        } else {
                            face
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(row.accessibilityLabel)
                                .accessibilityValue(row.accessibilityValue)
                                .accessibilityIdentifier("detail.series.volume")
                        }
                    }
                }
            }
            .padding(.horizontal, DSSpacing.lg)
        }
        .navigationTitle(hero.name)
    }
}

extension SeriesPageLayout where Filters == EmptyView {
    init(hero: SeriesPageHero, rows: [SeriesPageRow]) {
        self.init(hero: hero, rows: rows) { EmptyView() }
    }
}

/// One book on a series' page: a small cover, 「第 N 冊」 over the title, and how the shelf
/// stands with it in a capsule at the end, where the store has the book's price. The rule
/// under a row starts at its text, as the store's does.
private struct SeriesVolumeRow: View {
    let row: SeriesPageRow
    let hasRule: Bool

    var body: some View {
        HStack(alignment: .center, spacing: DSSpacing.md) {
            HomeCardCover(cover: row.cover, title: row.title, author: row.author,
                          size: CGSize(width: DSLayout.seriesVolumeCoverWidth,
                                       height: DSLayout.seriesVolumeCoverWidth / DSLayout.discoverCoverAspectRatio))
            VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                if let caption = row.caption {
                    Text(caption)
                        .font(DSFont.footnote)
                        .foregroundStyle(DSColor.textSecondary)
                        .lineLimit(1)
                }
                Text(row.title)
                    .font(DSFont.body.weight(.medium))
                    .foregroundStyle(DSColor.textPrimary)
                    .lineLimit(2)
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            if let status = row.status {
                Text(status)
                    .font(DSFont.subheadline.weight(.semibold))
                    .foregroundStyle(DSColor.textPrimary)
                    .lineLimit(1)
                    .padding(.horizontal, DSSpacing.md)
                    .padding(.vertical, DSSpacing.xs)
                    .background(DSColor.neutralControlFill, in: Capsule())
            }
        }
        .padding(.vertical, DSSpacing.md)
        .frame(minHeight: DSLayout.minimumTapTarget)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            if hasRule {
                Divider().padding(.leading, DSLayout.seriesVolumeCoverWidth + DSSpacing.md)
            }
        }
    }
}

// MARK: - A list's series

/// The series a list's item stands for (趨勢's), opened from its card before the work's own
/// page (maintainer, 2026-11-14: 「點進去先這樣」).
struct ListedSeriesRoute: Hashable, Sendable {
    /// The item, with the series' books in its summary.
    let work: WorkDetailRoute

    /// The item as a work alone: its 作品詳情, which lists no volumes and so leads back to no
    /// series page, and shows its own cover without the others behind it (maintainer,
    /// 2026-11-14: the fan is the series page's; a book's page has the book's cover).
    var workAlone: WorkDetailRoute {
        var summary = work.summary
        summary.volumes = []
        summary.seriesCovers = []
        return WorkDetailRoute(record: work.record, summary: summary, opening: work.opening,
                               recommendationReason: work.recommendationReason)
    }
}

/// A list's series: the books the list names, as it names them. It prints no count and no
/// 「第 N 冊」: the list holds the books it knows, in its order, which is neither how many the
/// series has nor each one's number (趨勢: the series' books in its pool; Bangumi's volumes start
/// with a 0 for some series). A book the list gives a page opens as a work of its own; the
/// others are only named. The button opens the item's own 作品詳情, where it is read from.
struct ListedSeriesPage: View {
    let route: ListedSeriesRoute
    @EnvironmentObject private var store: BookStore
    @State private var pushedWork: WorkDetailRoute?
    @State private var pushedAuthor: AuthorPageRequest?

    var body: some View {
        let summary = route.work.summary
        let session = HomeCardContent.session(for: route.work.opening, connections: .shared)
        let author = summary.authors.joined(separator: ", ")
        let fan = SeriesFan(summary, session: session)
        SeriesPageLayout(
            hero: SeriesPageHero(
                name: summary.series ?? summary.title, author: author,
                authorActions: WorkMatchKey.knownAuthors(summary.authors).map { name in
                    BookDetailAuthorAction(id: name, name: name,
                                           action: { pushedAuthor = AuthorPageRequest(name: name, context: .device) })
                },
                meta: localized("系列"),
                cover: .reference(summary.cover, session: session), coverTitle: summary.title, coverAuthor: author,
                fan: fan,
                open: BookDetailAction(title: localized("作品詳情"), systemImage: "book",
                                       action: { pushedWork = route.workAlone })),
            rows: summary.volumes.map { volume in
                SeriesPageRow(id: volume.id, cover: .reference(volume.cover ?? .generated(seed: volume.title), session: session),
                              title: volume.title, author: author, accessibilityLabel: volume.title,
                              open: volume.work.map { work in { pushedWork = work } })
            })
        // A book's page names the series and leads back here (maintainer, 2026-11-14:
        // 「詳情頁還要標出系列」): by its name, or 「系列」 for a work that is the series itself.
        .navigationDestination(item: $pushedWork) { work in
            WorkDetailView(route: work, listedSeries: WorkDetailListedSeries(
                name: summary.series ?? localized("系列"), open: { pushedWork = nil }))
                .environmentObject(store)
        }
        .navigationDestination(item: $pushedAuthor) { request in
            AuthorPageView(request: request).environmentObject(store)
        }
    }
}

/// The series a list's book belongs to, for the book's 作品詳情: what its hero writes, and how
/// the reader gets back to the series' page it came from.
struct WorkDetailListedSeries {
    let name: String
    let open: () -> Void
}
