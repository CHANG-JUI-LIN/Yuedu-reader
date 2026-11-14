import SwiftUI

// 同系列 on 作品詳情 (maintainer, 2026-10-12: Hero 系列連結＋頁尾區段, 其他冊依冊數排). The
// series is read once per page (`ShelfProvider.series(of:)`): the hero's link opens the series
// page, every volume in series order; the section lists the other volumes. Each card says
// 「第 N 冊」 where the author would be, since the series shares its author.

extension WorkSeriesShelf {
    /// A volume's card and its place in the series, 「第 N 冊」; no place for a volume whose
    /// metadata gives it no number.
    struct NumberedCard: Identifiable {
        let card: HomeCardContent
        let number: String?

        var id: SourceItemKey { card.id }
    }

    @MainActor
    static func numbered(_ volumes: [Volume], store: BookStore) -> [NumberedCard] {
        var numbers: [SourceItemKey: Double] = [:]
        for volume in volumes {
            if let key = WorkDetailRoute(volume.entry)?.nodeKey, let number = volume.number { numbers[key] = number }
        }
        return HomeRowContent(entries: volumes.map(\.entry), store: store).cards.map { card in
            NumberedCard(card: card, number: card.route.flatMap { numbers[$0.nodeKey] }.map(SeriesWorks.numberText))
        }
    }

    /// The volumes' cards, each numbered in place of its author.
    @MainActor
    static func cards(_ volumes: [Volume], store: BookStore) -> [HomeCardContent] {
        numbered(volumes, store: store).map { $0.card.inSeries($0.number) }
    }
}

/// 同系列: the series' other volumes as a shelf of covers; nothing when there is none.
struct BookDetailSeriesSection: View {
    let series: WorkSeriesShelf
    let onShowAll: () -> Void
    let onSelect: (WorkDetailRoute) -> Void
    @EnvironmentObject private var store: BookStore

    var body: some View {
        if !series.others.isEmpty {
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                BookDetailSectionHeader(title: localized("同系列"), actionTitle: localized("查看全部"), action: onShowAll)
                    .padding(.horizontal, DSSpacing.lg)
                BookDetailCoverShelf(cards: WorkSeriesShelf.cards(series.others, store: store),
                                     identifier: "detail.series.book", onSelect: onSelect)
                BookDetailSectionRule()
                    .padding(.horizontal, DSSpacing.lg)
            }
        }
    }
}

/// The series page, pushed from the hero's link or 同系列's 查看全部, as Apple Books' store draws
/// a series (maintainer, 2026-11-14, from a screenshot of it): the volumes' covers fanned on a
/// block of the first one's colour, the series' name, its author and 「系列 · N 本」, one button
/// to a volume, then every volume as a row, 「第 N 冊」 over its title, in series order. A series
/// with books and audiobooks lists one kind at a time, as the store's 書籍｜有聲書 does. A volume
/// opens its 作品詳情 on top.
struct WorkDetailSeriesPage: View {
    /// Which of the series' volumes the page lists, where it has both.
    private enum VolumeKind: Hashable {
        case books, audiobooks
    }

    let series: WorkSeriesShelf
    @EnvironmentObject private var store: BookStore
    @State private var pushedWork: WorkDetailRoute?
    @State private var pushedAuthor: AuthorPageRequest?
    @State private var form = VolumeKind.books

    var body: some View {
        let volumes = WorkSeriesShelf.numbered(series.volumes, store: store)
        let books = volumes.filter { $0.card.kind != .audio }
        let audiobooks = volumes.filter { $0.card.kind == .audio }
        // The hero is the series' books; a series of audiobooks only is its audiobooks.
        let fanned = books.isEmpty ? audiobooks : books
        let listed = books.isEmpty || audiobooks.isEmpty ? fanned : form == .books ? books : audiobooks
        let lead = Self.lead(of: fanned)
        SeriesPageLayout(
            hero: SeriesPageHero(
                name: series.name, author: Self.author(of: fanned), authorActions: authorLinks(of: fanned),
                meta: String(format: localized("系列 · %d 本"), fanned.count),
                cover: lead?.card.cover ?? .placeholder, coverTitle: lead?.card.title ?? series.name,
                coverAuthor: lead?.card.author ?? "", isSquare: lead?.card.kind == .audio,
                fan: Self.fan(of: fanned, around: lead), open: openAction(lead)),
            rows: listed.map { volume in
                let read = volume.card.inSeries(volume.number)
                return SeriesPageRow(id: volume.id.sortKey, cover: volume.card.cover, caption: volume.number,
                                     title: volume.card.title, author: volume.card.author, status: volume.card.detail,
                                     accessibilityLabel: read.accessibilityLabel, accessibilityValue: read.accessibilityValue,
                                     open: { pushedWork = volume.card.route })
            }
        ) {
            if !books.isEmpty, !audiobooks.isEmpty {
                // The store's two capsules, the chosen one filled.
                HStack(spacing: DSSpacing.sm) {
                    DSChip(title: localized("書籍"), isSelected: form == .books) { form = .books }
                        .accessibilityIdentifier("detail.series.form.books")
                    DSChip(title: localized("有聲書"), isSelected: form == .audiobooks) { form = .audiobooks }
                        .accessibilityIdentifier("detail.series.form.audiobooks")
                }
            }
        }
        .navigationDestination(item: $pushedWork) { route in
            WorkDetailView(route: route).environmentObject(store)
        }
        .navigationDestination(item: $pushedAuthor) { request in
            AuthorPageView(request: request).environmentObject(store)
        }
    }

    /// The authors every volume names alike, each opening its own page as 作品詳情's do; none
    /// when the volumes differ, and the hero then writes no author.
    private func authorLinks(of volumes: [WorkSeriesShelf.NumberedCard]) -> [BookDetailAuthorAction] {
        let named = Set(volumes.map { WorkMatchKey.knownAuthors($0.card.route?.summary.authors ?? []) })
        guard named.count == 1, let authors = named.first else { return [] }
        return authors.map { name in
            BookDetailAuthorAction(id: name, name: name,
                                   action: { pushedAuthor = AuthorPageRequest(name: name, context: .device) })
        }
    }

    /// The volume the hero shows and its button opens: the one being read, else the first.
    private static func lead(of volumes: [WorkSeriesShelf.NumberedCard]) -> WorkSeriesShelf.NumberedCard? {
        volumes.first { $0.card.progress != nil } ?? volumes.first
    }

    /// The author the volumes share; none when they name several, or none.
    private static func author(of volumes: [WorkSeriesShelf.NumberedCard]) -> String {
        let authors = Set(volumes.map(\.card.author).filter { !$0.isEmpty })
        return authors.count == 1 ? authors.first ?? "" : ""
    }

    /// The other volumes behind the hero's cover, those before it in the series on its leading side.
    private static func fan(of volumes: [WorkSeriesShelf.NumberedCard], around lead: WorkSeriesShelf.NumberedCard?) -> SeriesFan? {
        guard let lead, let own = volumes.firstIndex(where: { $0.id == lead.id }), volumes.count > 1 else { return nil }
        return SeriesFan(volumes: volumes.filter { $0.id != lead.id }.map { SeriesFan.Volume(id: $0.id.sortKey, cover: $0.card.cover) },
                         position: own)
    }

    /// 「檢視第 1 冊」, by the volume's title where it has no number: its 作品詳情, where it is read from.
    private func openAction(_ lead: WorkSeriesShelf.NumberedCard?) -> BookDetailAction {
        BookDetailAction(title: String(format: localized("檢視%@"), lead?.number ?? lead?.card.title ?? ""),
                         systemImage: lead?.card.kind == .audio ? "headphones" : "book",
                         isEnabled: lead?.card.route != nil,
                         action: { pushedWork = lead?.card.route })
    }
}

#if DEBUG
private extension WorkSeriesShelf {
    static var preview: WorkSeriesShelf {
        let person = AozoraPerson(id: "1", name: "劉 慈欣", yomi: "", sortYomi: "", born: "", died: "")
        let works = ["三體", "黑暗森林", "死神永生", "三體前傳"].enumerated().map { offset, title in
            AozoraWork(id: "\(offset + 1)", title: title, yomi: title, sortYomi: title, subtitle: "", kanaStyle: "",
                       ndc: "", published: "2000-01-0\(4 - offset)", updated: "", card: "", text: "", textUpdated: "",
                       credits: [.init(person: "1", role: "著者")], source: "", sourcePublisher: "")
        }
        let index = AozoraCatalogIndex(catalog: AozoraCatalog(schemaVersion: 1, persons: [person], works: works))
        let volumes = index.newWorks.enumerated().map { offset, work in
            Volume(entry: .aozora(work, index: index), number: Double(offset + 1), isPageWork: offset == 1)
        }
        return WorkSeriesShelf(name: "三體", number: 2, volumes: volumes)
    }
}

#Preview("同系列") {
    ScrollView {
        BookDetailSeriesSection(series: .preview, onShowAll: {}, onSelect: { _ in })
    }
    .environmentObject(BookStore())
}

#Preview("系列頁") {
    NavigationStack {
        WorkDetailSeriesPage(series: .preview)
    }
    .environmentObject(BookStore())
}
#endif
