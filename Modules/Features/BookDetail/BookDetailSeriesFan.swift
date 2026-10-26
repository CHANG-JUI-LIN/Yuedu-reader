import SwiftUI

// 作品詳情's series fan (Apple Books' series header, `Technotes/AppleBooksHomeLayouts-2026-10-25.md`;
// maintainer, by option, 2026-10-26): the other volumes' covers fanned behind the page's own,
// up to two on each side, the nearest in series order. The volumes are the series read on this
// device (同系列), else the covers a list gave the item that stands for its series (趨勢's
// `seriesCovers`). Real artwork only: a volume whose cover would be a 預設封面 or generated, or
// whose artwork does not load, is skipped, and with none left the hero keeps its single cover.
// The fan is decoration; the hero names the series once, by its series link or a list's series
// name.

/// The other volumes of the page's series, before the fan picks from them.
struct SeriesFan {
    struct Volume: Identifiable {
        let id: String
        let cover: HomeCardContent.Cover
    }

    /// Every other volume, in series order.
    let volumes: [Volume]
    /// How many of `volumes` come before the page's own.
    let position: Int

    /// How many covers stand on each side of the page's.
    static let perSide = DSLayout.bookDetailSeriesFanScales.count

    /// The covers each side draws, nearest the page's cover first: the nearest volumes in
    /// series order that have artwork. Both empty when no other volume has any.
    func sides(hasArtwork: (Volume) -> Bool) -> (leading: [Volume], trailing: [Volume]) {
        let before = volumes.prefix(position).reversed().filter(hasArtwork)
        let after = volumes.dropFirst(position).filter(hasArtwork)
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

    /// The artwork the fan draws, by volume: the volumes `sides` picks, each loaded before
    /// any is drawn, so the fan never shows a cover standing in for one still loading. A
    /// volume whose artwork does not load gives its place to the next nearest. Empty when
    /// none loads.
    @MainActor
    func artwork(pipeline: CoverImagePipeline, source: (Volume) -> SeriesFanArtwork?) async -> [Volume.ID: UIImage] {
        let sources = Dictionary(volumes.compactMap { volume in source(volume).map { (volume.id, $0) } },
                                 uniquingKeysWith: { first, _ in first })
        var images: [Volume.ID: UIImage] = [:]
        var failed: Set<Volume.ID> = []
        while !Task.isCancelled {
            let chosen = sides { sources[$0.id] != nil && !failed.contains($0.id) }
            let pending = (chosen.leading + chosen.trailing).compactMap { volume in
                images[volume.id] == nil ? sources[volume.id].map { (volume.id, $0) } : nil
            }
            guard !pending.isEmpty else { return images }
            await withTaskGroup(of: (Volume.ID, UIImage?).self) { group in
                for (id, source) in pending {
                    group.addTask { (id, await source.image(pipeline: pipeline)) }
                }
                for await (id, image) in group {
                    if let image { images[id] = image } else { failed.insert(id) }
                }
            }
        }
        return [:]
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
        self.init(volumes: cards.map { Volume(id: $0.id.sortKey, cover: $0.cover) }, position: before)
    }
}

extension SeriesFan {
    /// A list's item that stands for a series (趨勢's, under its first book): the other
    /// volumes' covers the list gave, after the page's own. Nil without them.
    init?(_ summary: WorkSummary, session: URLSession?) {
        guard summary.series != nil, !summary.seriesCovers.isEmpty else { return nil }
        self.init(volumes: summary.seriesCovers.enumerated().map { offset, cover in
            Volume(id: "\(offset)", cover: .reference(cover, session: session))
        }, position: 0)
    }
}

/// Where a volume's own artwork comes from, for the loaders and caches its cover is drawn
/// from everywhere else: the saved or indexed file through the cover pipeline, the address
/// through `BookCoverImage`'s fetch.
struct SeriesFanArtwork: Sendable {
    var file: CoverImageRequest?
    var remote: Remote?

    struct Remote: Sendable {
        let url: String
        let headers: [String: String]
        let sourceID: UUID?
        let session: URLSession?
    }

    /// The artwork, or nil when it cannot be read or fetched. A file known to be unusable
    /// falls through to the address, as the shelf's cover does; a load cut short does not.
    func image(pipeline: CoverImagePipeline) async -> UIImage? {
        if let file {
            switch await pipeline.image(for: file) {
            case .image(let image): return image
            case .unavailable: break
            case .superseded, .cancelled: return nil
            }
        }
        guard let remote else { return nil }
        return await BookCoverImage.fetchCover(coverURL: remote.url, sourceBaseURL: nil, sourceHeaders: remote.headers,
                                               sourceID: remote.sourceID, session: remote.session)
    }
}

extension HomeCardContent.Cover {
    /// The volume's own artwork as `HomeCoverArtwork` draws it, at `pixels`: a shelf copy's
    /// saved, filled or catalog cover (`BookshelfCoverPlan.shelf`), a list's address or file.
    /// Nil when it would draw a 預設封面, a generated cover or a placeholder, and for every
    /// volume under 強制使用預設封面.
    @MainActor
    func artworkSource(pixels: CoverPixelSize, filledCovers: FilledCoverIndex?, colorScheme: ColorScheme,
                       forcesDefaultCover: Bool = GlobalSettings.shared.useDefaultCoverForAllBooks) -> SeriesFanArtwork? {
        guard !forcesDefaultCover else { return nil }
        switch self {
        case .shelf(let book):
            let plan = BookshelfCoverPlan.shelf(for: book, colorScheme: colorScheme, filledCover: filledCovers?.path(for: book),
                                                forcesDefaultCover: forcesDefaultCover)
            let remote = plan.catalogFallback.flatMap { _ in book.coverUrl }.map { url in
                SeriesFanArtwork.Remote(url: url, headers: [:], sourceID: book.bookSourceId,
                                        session: BookCoverLoader.remoteSession(for: book))
            }
            guard plan.ownCover != nil || remote != nil else { return nil }
            return SeriesFanArtwork(file: plan.ownCover.map { CoverImageRequest(source: $0, size: pixels) }, remote: remote)
        case .reference(.remote(let url, let headers), let session):
            return SeriesFanArtwork(remote: .init(url: url.absoluteString, headers: headers, sourceID: nil, session: session))
        case .reference(.copyFile(let path), _):
            return SeriesFanArtwork(file: CoverImageRequest(source: .indexedCover(path: path), size: pixels))
        case .reference(.generated, _), .reference(nil, _), .placeholder:
            return nil
        }
    }
}

/// The fan behind the hero's cover, bottom-aligned with it: on each side the nearer volume a
/// little smaller and further out, the next smaller and further still, each tilted out from its
/// foot. Nothing is drawn until the chosen volumes' artwork has loaded.
struct SeriesCoverFan: View {
    let fan: SeriesFan
    /// The hero's cover, which the fan stands behind.
    let size: CGSize

    @Environment(FilledCoverIndex.self) private var filledCovers: FilledCoverIndex?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.coverImagePipeline) private var pipeline
    @State private var artwork: [SeriesFan.Volume.ID: UIImage] = [:]

    private struct Slot: Identifiable {
        let id: SeriesFan.Volume.ID
        let image: UIImage
        /// 0 next to the cover, 1 behind that.
        let depth: Int
        /// -1 leading, 1 trailing.
        let side: CGFloat
    }

    /// Farthest first, so the nearer covers draw over them.
    private var slots: [Slot] {
        let sides = fan.sides { artwork[$0.id] != nil }
        func placed(_ volumes: [SeriesFan.Volume], side: CGFloat) -> [Slot] {
            volumes.enumerated().compactMap { depth, volume in
                artwork[volume.id].map { Slot(id: volume.id, image: $0, depth: depth, side: side) }
            }
        }
        return (placed(sides.leading, side: -1) + placed(sides.trailing, side: 1)).sorted { $0.depth > $1.depth }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ForEach(slots) { slot in
                SeriesFanCover(image: slot.image, depth: slot.depth, side: slot.side, size: size)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .bottom)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: fan.volumes.map(\.id)) {
            // The size the page's own cover loads at, so the volumes share its cached bitmaps.
            guard let pixels = CoverPixelSize.fitting(pointSize: size, scale: displayScale) else { return }
            let loaded = await fan.artwork(pipeline: pipeline) {
                $0.cover.artworkSource(pixels: pixels, filledCovers: filledCovers, colorScheme: colorScheme)
            }
            if !Task.isCancelled { artwork = loaded }
        }
    }
}

/// One volume's cover in the fan. It opens out from behind the page's cover when it appears;
/// with Reduce Motion it is simply there.
private struct SeriesFanCover: View {
    let image: UIImage
    let depth: Int
    let side: CGFloat
    /// The hero's cover.
    let size: CGSize

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isOpen = false

    var body: some View {
        let scale = DSLayout.bookDetailSeriesFanScales[depth]
        let isOpen = isOpen || reduceMotion
        let shape = RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous)
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: size.width * scale, height: size.height * scale)
            .clipShape(shape)
            .overlay(shape.stroke(DSColor.separator, lineWidth: 0.5))
            .shadow(color: DSColor.bookDetailCoverShadow, radius: DSLayout.bookDetailCoverShadowRadius,
                    y: DSLayout.bookDetailCoverShadowOffsetY)
            .rotationEffect(.degrees(isOpen ? DSLayout.bookDetailSeriesFanAngles[depth] * side : 0), anchor: .bottom)
            .offset(x: isOpen ? size.width * DSLayout.bookDetailSeriesFanOffsets[depth] * side : 0)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(DSAnimation.standard) { self.isOpen = true }
            }
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
            Volume(id: "\(offset)", cover: cover)
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
