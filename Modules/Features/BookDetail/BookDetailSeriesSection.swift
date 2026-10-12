import SwiftUI

// 同系列 on 作品詳情 (maintainer, 2026-10-12: Hero 系列連結＋頁尾區段, 其他冊依冊數排). The
// series is read once per page (`ShelfProvider.series(of:)`): the hero's link opens the series
// page, every volume in series order; the section lists the other volumes. Each card says
// 「第 N 冊」 where the author would be, since the series shares its author.

extension WorkSeriesShelf {
    /// The volumes' cards, each numbered in place of its author.
    @MainActor
    static func cards(_ volumes: [Volume], store: BookStore) -> [HomeCardContent] {
        var numbers: [SourceItemKey: Double] = [:]
        for volume in volumes {
            if let key = WorkDetailRoute(volume.entry)?.nodeKey, let number = volume.number { numbers[key] = number }
        }
        return HomeRowContent(entries: volumes.map(\.entry), store: store).cards.map { card in
            card.inSeries(card.route.flatMap { numbers[$0.nodeKey] }.map(SeriesWorks.numberText))
        }
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
            }
        }
    }
}

/// The series page, pushed from the hero's link or 同系列's 查看全部: every volume, the page's
/// own included, in series order. A volume opens its 作品詳情 on top.
struct WorkDetailSeriesPage: View {
    let series: WorkSeriesShelf
    @EnvironmentObject private var store: BookStore
    @State private var pushedWork: WorkDetailRoute?

    var body: some View {
        ScrollView {
            HomeSectionCards(layout: .coverGrid, cards: WorkSeriesShelf.cards(series.volumes, store: store),
                             rowID: "detail.series", hasShowAll: false,
                             open: { card, _ in pushedWork = card.route })
                .padding(.vertical, DSSpacing.lg)
        }
        .navigationTitle(series.name)
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .explore)
        .navigationDestination(item: $pushedWork) { route in
            WorkDetailView(route: route).environmentObject(store)
        }
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
