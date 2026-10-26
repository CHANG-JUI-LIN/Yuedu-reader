import SwiftUI

// 作品詳情's series fan (Apple Books' series header, `Technotes/AppleBooksHomeLayouts-2026-10-25.md`;
// maintainer, by option, 2026-10-26): the other volumes' covers fanned behind the page's own,
// up to two on each side, the nearest in series order. The volumes are the series read on this
// device (同系列), else the covers a list gave the item that stands for its series (趨勢's
// `seriesCovers`). Real artwork only: a volume whose cover would be generated is skipped, and
// with none left the hero keeps its single cover. The fan is decoration; the hero names the
// series once, by its series link or a list's series name.

/// The other volumes of the page's series, before the fan picks from them.
struct SeriesFan {
    struct Volume: Identifiable {
        let id: String
        let cover: HomeCardContent.Cover
        /// For the cover drawn while the artwork loads.
        let title: String
        let author: String
    }

    /// Every other volume, in series order.
    let volumes: [Volume]
    /// How many of `volumes` come before the page's own.
    let position: Int

    /// How many covers stand on each side of the page's.
    static let perSide = DSLayout.bookDetailSeriesFanScales.count

    /// The covers each side draws, nearest the page's cover first: those with artwork, the
    /// nearest volumes in series order. Both empty when no other volume has artwork.
    func sides(hasArtwork: (HomeCardContent.Cover) -> Bool) -> (leading: [Volume], trailing: [Volume]) {
        let before = volumes.prefix(position).reversed().filter { hasArtwork($0.cover) }
        let after = volumes.dropFirst(position).filter { hasArtwork($0.cover) }
        return Self.arrange(before: before, after: after, perSide: Self.perSide)
    }

    /// The volumes before the page's to the leading side, those after to the trailing one, each
    /// nearest first. At an end of the series the side with too few takes the next nearest
    /// from the other, so the first volume's page fans out on both sides too.
    static func arrange<Item>(before: [Item], after: [Item], perSide: Int) -> (leading: [Item], trailing: [Item]) {
        let leading = Array(before.prefix(perSide)), trailing = Array(after.prefix(perSide))
        let spareBefore = before.dropFirst(leading.count), spareAfter = after.dropFirst(trailing.count)
        return (leading + spareAfter.prefix(perSide - leading.count),
                trailing + spareBefore.prefix(perSide - trailing.count))
    }
}

extension SeriesFan {
    /// The series read on this device (同系列) around the page's own volume; nil when the
    /// page's volume is not among its volumes.
    @MainActor
    init?(_ series: WorkSeriesShelf, store: BookStore) {
        guard let own = series.volumes.firstIndex(where: \.isPageWork) else { return nil }
        let cards = HomeRowContent(entries: series.others.map(\.entry), store: store).cards
        // A card is made of each item entry, and only of those.
        let before = series.volumes[..<own].filter { if case .item = $0.entry { true } else { false } }.count
        self.init(volumes: cards.map { Volume(id: $0.id.sortKey, cover: $0.cover, title: $0.title, author: $0.author) },
                  position: before)
    }
}

extension SeriesFan {
    /// A list's item that stands for a series (趨勢's, under its first book): the other
    /// volumes' covers the list gave, after the page's own. Nil without them.
    init?(_ summary: WorkSummary, session: URLSession?) {
        guard let series = summary.series, !summary.seriesCovers.isEmpty else { return nil }
        let author = summary.authors.joined(separator: "、")
        self.init(volumes: summary.seriesCovers.enumerated().map { offset, cover in
            Volume(id: "\(offset)", cover: .reference(cover, session: session), title: series, author: author)
        }, position: 0)
    }
}

extension HomeCardContent.Cover {
    /// Whether the cover draws a volume's own artwork, as the shelf decides it
    /// (`BookshelfCoverPlan.shelf`): its saved, catalog or filled cover, never a 預設封面 or a
    /// generated one. A file that turns out unreadable is only known once loaded.
    @MainActor
    func hasArtwork(filledCovers: FilledCoverIndex?, colorScheme: ColorScheme) -> Bool {
        switch self {
        case .shelf(let book):
            let plan = BookshelfCoverPlan.shelf(for: book, colorScheme: colorScheme, filledCover: filledCovers?.path(for: book))
            return plan.ownCover != nil || plan.catalogFallback != nil
        case .reference(.remote, _), .reference(.copyFile, _):
            return true
        case .reference(.generated, _), .reference(nil, _), .placeholder:
            return false
        }
    }
}

/// The fan behind the hero's cover, bottom-aligned with it: on each side the nearer volume a
/// little smaller and further out, the next smaller and further still, each tilted out from its
/// foot. It opens out from behind the cover once the series is read; with Reduce Motion it is
/// simply there.
struct SeriesCoverFan: View {
    let fan: SeriesFan
    /// The hero's cover, which the fan stands behind.
    let size: CGSize

    @Environment(FilledCoverIndex.self) private var filledCovers: FilledCoverIndex?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isOpen = false

    private struct Slot: Identifiable {
        let volume: SeriesFan.Volume
        /// 0 next to the cover, 1 behind that.
        let depth: Int
        /// -1 leading, 1 trailing.
        let side: CGFloat
        var id: String { volume.id }
    }

    /// Farthest first, so the nearer covers draw over them.
    private var slots: [Slot] {
        let sides = fan.sides { $0.hasArtwork(filledCovers: filledCovers, colorScheme: colorScheme) }
        let leading = sides.leading.enumerated().map { Slot(volume: $1, depth: $0, side: -1) }
        let trailing = sides.trailing.enumerated().map { Slot(volume: $1, depth: $0, side: 1) }
        return (leading + trailing).sorted { $0.depth > $1.depth }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ForEach(slots) { slot in cover(slot) }
        }
        .frame(width: size.width, height: size.height, alignment: .bottom)
        // Only the page's own cover tints the hero's wash, and no observer above the page
        // (the shelf's) hears these.
        .environment(\.coverImageObserver, nil)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(DSAnimation.standard) { isOpen = true }
        }
    }

    private func cover(_ slot: Slot) -> some View {
        let scale = DSLayout.bookDetailSeriesFanScales[slot.depth]
        let drawn = CGSize(width: size.width * scale, height: size.height * scale)
        let isOpen = isOpen || reduceMotion
        let shape = RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous)
        return HomeCoverArtwork(cover: slot.volume.cover, title: slot.volume.title, author: slot.volume.author, size: drawn)
            .frame(width: drawn.width, height: drawn.height)
            .clipShape(shape)
            .overlay(shape.stroke(DSColor.separator, lineWidth: 0.5))
            .shadow(color: DSColor.bookDetailCoverShadow, radius: DSLayout.bookDetailCoverShadowRadius,
                    y: DSLayout.bookDetailCoverShadowOffsetY)
            .rotationEffect(.degrees(isOpen ? DSLayout.bookDetailSeriesFanAngles[slot.depth] * slot.side : 0), anchor: .bottom)
            .offset(x: isOpen ? size.width * DSLayout.bookDetailSeriesFanOffsets[slot.depth] * slot.side : 0)
    }
}

#if DEBUG
private extension SeriesFan {
    /// Five bundled public-domain covers: the page's is the second.
    static var preview: (own: HomeCardContent.Cover, fan: SeriesFan) {
        let covers = ["frankenstein", "dracula", "dorian-gray", "jane-eyre", "moby-dick"].map { name in
            HomeCardContent.Cover.reference(Bundle.main.path(forResource: "layout-sample-\(name)", ofType: "jpg").map(CoverReference.copyFile),
                                            session: nil)
        }
        let volumes = covers.enumerated().filter { $0.offset != 1 }.map { offset, cover in
            Volume(id: "\(offset)", cover: cover, title: "第 \(offset + 1) 冊", author: "")
        }
        return (covers[1], SeriesFan(volumes: volumes, position: 1))
    }
}

#Preview("系列扇形") {
    let sample = SeriesFan.preview
    NavigationStack {
        BookDetailScaffold(title: "第 2 冊", compactAction: BookDetailAction(title: "開始閱讀", systemImage: "book", action: {})) {
            BookDetailHero(
                artworkShape: .book,
                cover: HomeCoverArtwork(cover: sample.own, title: "第 2 冊", author: "",
                                        size: CGSize(width: DSLayout.bookDetailCoverWidth, height: DSLayout.bookDetailCoverHeight)),
                title: "第 2 冊",
                author: "示範作者",
                meta: "",
                primary: BookDetailAction(title: "開始閱讀", systemImage: "book", action: {}),
                secondary: nil,
                links: [BookDetailLink(id: "series", title: SeriesWorks.line(name: "示範系列", number: 2), action: {})],
                seriesFan: sample.fan
            )
        } content: {
            EmptyView()
        }
    }
}
#endif
