import SwiftUI

// Unified library 5c: one card for every item on Explore's home, whatever its source.
// The maintainer's brief (settled decision 11): 70% Apple Books' finish (a large 2:3 cover,
// the title in two lines, the author in one, no card chrome), 30% Emby's density (one more
// small line for the copy's status or how far it is read, and a progress bar along a
// 繼續閱讀 cover).
//
// Not `PublicLibraryBookCard`: that card draws generated covers only and was measured frame
// by frame against Apple Books' store, and the home draws every source's covers.

/// What a home card shows of one item, resolved once per row render from the frozen entry
/// and the shelf as it is now.
struct HomeCardContent: Identifiable {
    enum Cover {
        /// A shelf copy, drawn as the shelf draws it (預設封面, 強制使用預設封面).
        case shelf(ReadingBook)
        case reference(CoverReference?, session: URLSession?)
        /// A blank cover while the row loads.
        case placeholder
    }

    let id: SourceItemKey
    let title: String
    private(set) var author: String
    /// The source's plain-text blurb, for the layouts with room for it; none for a shelf copy.
    let blurb: String?
    /// The source's own category, for 精選 (decision 37); none for a shelf copy.
    let category: String?
    let cover: Cover
    /// The Emby line: 已加入書架, 已下載, or a shelf copy's 新增 or how far it is read.
    let detail: String?
    /// Book, comic or audiobook, for 精簡閱讀卡片's 書籍・已讀 42% line.
    let kind: ContentKind
    /// How far a shelf copy is read, for the bar along its cover; nil when unread or finished.
    let progress: Double?
    let accessibilityLabel: String
    private(set) var accessibilityValue: String
    let opening: ItemOpening
    /// 作品詳情's route, the item frozen as the row had it; none for a placeholder.
    let route: WorkDetailRoute?

    /// - Parameters:
    ///   - status: the item's copies on this device (`CopyLookup.status(for:)`). Book-source
    ///     items find none: `CopyLookup` leaves book-source copies out, so their cards show
    ///     no status.
    ///   - shelfBooks: the shelf records of this row's `.copy` items, read live so progress
    ///     is current.
    @MainActor
    init?(_ entry: CollectionEntry, status: (SourceItemKey) -> CopyLookup.Status?,
          shelfBooks: [UUID: ReadingBook], connections: RemoteLibraryConnectionStore = .shared) {
        guard case .item(let record, let summary, let opening) = entry else { return nil }
        id = record.key
        self.opening = opening
        route = WorkDetailRoute(record: record, summary: summary, opening: opening)
        kind = record.contentKind
        title = summary.title
        author = summary.authors.joined(separator: "、")
        if case .copy(let bookID) = opening, let book = shelfBooks[bookID] {
            cover = .shelf(book)
            blurb = nil
            category = nil
            let read = book.currentPosition
            detail = BookshelfAccessibility.readingStatus(for: book)
            progress = read > 0 && read < 0.99 ? read : nil
            // Read exactly as the shelf reads the book, how far it is read included.
            accessibilityLabel = BookshelfAccessibility.description(for: book)
            accessibilityValue = ""
            return
        }
        cover = .reference(summary.cover, session: Self.session(for: opening, connections: connections))
        blurb = summary.blurb
        category = summary.category
        let status = status(record.key)
        detail = status?.title
        progress = nil
        accessibilityLabel = summary.title
        // No source, as on screen: the home names none (5d-3b, decision 19).
        accessibilityValue = [author, status?.title ?? ""].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// The card in a series' row (同系列): its number in place of the author the series
    /// shares, on screen and to VoiceOver. A volume with no number keeps its author.
    func inSeries(_ number: String?) -> HomeCardContent {
        guard let number else { return self }
        var card = self
        card.author = number
        // A shelf copy's label already reads its title, author and progress.
        if case .shelf = cover {
            card.accessibilityValue = number
        } else {
            card.accessibilityValue = [number, detail ?? ""].filter { !$0.isEmpty }.joined(separator: ", ")
        }
        return card
    }

    /// One of the blank cards a loading row shows, as long as a real one's text.
    static func placeholder(_ index: Int) -> HomeCardContent {
        HomeCardContent(placeholder: index)
    }

    private init(placeholder index: Int) {
        id = SourceItemKey(instance: SourceInstanceKey(type: .library, id: "placeholder"), item: "\(index)")
        title = "Placeholder title"
        author = "Author"
        blurb = "A blurb as long as a source's, over two lines of a card."
        category = "Category"
        cover = .placeholder
        detail = nil
        kind = .text
        progress = nil
        accessibilityLabel = ""
        accessibilityValue = ""
        opening = .copy(UUID())
        route = nil
    }

    /// A library's covers come through its connection's session, which carries its sign-in;
    /// Gutenberg's through the built-in connection's, as the store and a shelf copy load them.
    @MainActor
    static func session(for opening: ItemOpening, connections: RemoteLibraryConnectionStore) -> URLSession? {
        switch opening {
        case .opdsEntry(_, let connectionID), .webDAVFile(_, let connectionID):
            return connections.connection(id: connectionID).map { connections.httpClient(for: $0).session }
        case .gutenberg:
            return connections.connection(id: PublicLibraryID.gutenberg.rawValue).map { connections.httpClient(for: $0).session }
        default:
            return nil
        }
    }

    /// The shelf copy the card shows, whose ••• acts on it (5d-3c).
    var shelfBook: ReadingBook? {
        if case .shelf(let book) = cover { book } else { nil }
    }

    /// 精簡閱讀卡片's line: the kind, then the Emby line, as Apple Books' 書籍・12%.
    var kindAndDetail: String {
        let kindName = switch kind {
        case .text: localized("書籍")
        case .comic: localized("漫畫")
        case .audio: localized("有聲書")
        }
        return [kindName, detail].compactMap { $0 }.joined(separator: "・")
    }

    /// The store book a Gutenberg or Aozora card opens in the carousel, whose cover it grows from.
    var publicLibraryBookID: String? {
        switch opening {
        case .gutenberg(let book): PublicLibraryBook.gutenberg(book).id
        case .aozora(let work): PublicLibraryBook.aozoraID(work)
        default: nil
        }
    }
}

struct HomeBookCard: View {
    let content: HomeCardContent
    let coverWidth: CGFloat
    /// Keeps two title lines and the status line even when the text is shorter, so cards
    /// stacked in 多行橫向輪播 and 固定封面網格 line up row by row.
    var reservesTextSpace = false

    private var coverSize: CGSize {
        CGSize(width: coverWidth, height: coverWidth / DSLayout.discoverCoverAspectRatio)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xxs) {
            HomeCardCover(cover: content.cover, title: content.title, author: content.author, size: coverSize)
                .overlay(alignment: .bottom) {
                    if let progress = content.progress { HomeProgressBar(progress: progress) }
                }
                .modifier(PublicLibraryCoverAnchor(id: content.publicLibraryBookID))
                .padding(.bottom, DSSpacing.sm)
            if reservesTextSpace {
                // The tallest text a card can have, unseen, holds the room; the card's own
                // text sits at its top, so short text leaves the space below, not between lines.
                ZStack(alignment: .topLeading) {
                    text(title: "\n", author: " ", detail: " ").hidden()
                    text(title: content.title, author: content.author, detail: content.detail)
                }
            } else {
                text(title: content.title, author: content.author, detail: content.detail)
            }
        }
        // Cards in a row align at the top, as Apple Books' do, whatever each one's text runs to.
        .frame(width: coverWidth, alignment: .topLeading)
        .contentShape(Rectangle())
    }

    private func text(title: String, author: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.xxs) {
            Text(title)
                .font(DSFont.subheadline.weight(.semibold))
                .foregroundStyle(DSColor.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if !author.isEmpty {
                Text(author)
                    .font(DSFont.footnote)
                    .foregroundStyle(DSColor.textSecondary)
                    .lineLimit(1)
            }
            if let detail {
                Text(detail)
                    .font(DSFont.caption)
                    .foregroundStyle(DSColor.textSecondary)
                    .lineLimit(1)
            }
        }
    }

}

/// How far a shelf copy is read, along its cover or under 大型閱讀卡片's text. Hidden from
/// VoiceOver: the card's label already says it.
struct HomeProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(DSColor.neutralControlFill)
                Rectangle().fill(DSColor.accent).frame(width: proxy.size.width * progress)
            }
        }
        .frame(height: DSLayout.homeCardProgressHeight)
        .accessibilityHidden(true)
    }
}

/// Registers a store book's cover, so its carousel card opens out of it; other covers have none.
struct PublicLibraryCoverAnchor: ViewModifier {
    let id: String?

    func body(content: Content) -> some View {
        if let id { content.publicLibraryCoverFrame(id: id) } else { content }
    }
}

/// A home cover, from whichever view already draws that kind: the shelf's artwork for a
/// copy, `BookCoverImage` for an address, the cover pipeline for a file the app keeps, and
/// `GeneratedBookCover` when there is none.
struct HomeCardCover: View {
    let cover: HomeCardContent.Cover
    let title: String
    let author: String
    let size: CGSize

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DSRadius.searchListCover, style: .continuous)
        HomeCoverArtwork(cover: cover, title: title, author: author, size: size)
            .frame(width: size.width, height: size.height)
            .clipShape(shape)
            .shadow(color: DSColor.searchListCoverShadow, radius: DSLayout.searchListCoverShadowRadius,
                    y: DSLayout.searchListCoverShadowY)
            .accessibilityHidden(true)
    }
}

/// The artwork alone, filling whatever frame it is given, for a hero that frames, clips and
/// blurs it itself (作品詳情). `size` is the size it is mostly drawn at, which the shelf's
/// artwork and the cover pipeline size their images for.
struct HomeCoverArtwork: View {
    let cover: HomeCardContent.Cover
    let title: String
    let author: String
    let size: CGSize
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        switch cover {
        case .shelf(let book):
            BookshelfCoverArtwork(book: book, plan: .shelf(for: book, colorScheme: colorScheme), displaySize: size)
        case .reference(.remote(let url, let headers), let session):
            BookCoverImage(coverURL: url.absoluteString, title: title, author: author, sourceHeaders: headers,
                           session: session)
        case .reference(.copyFile(let path), _):
            HomeFileCover(path: path, title: title, author: author, size: size)
        case .reference(.generated, _), .reference(nil, _):
            GeneratedBookCover(title: title, author: author)
        case .placeholder:
            DSColor.neutralControlFill
        }
    }
}

/// A cover file another store keeps (the WebDAV index's), read off the main thread by the
/// cover pipeline; the generated cover stands in until it is read, and when it cannot be.
private struct HomeFileCover: View {
    let path: String
    let title: String
    let author: String
    let size: CGSize
    @Environment(\.displayScale) private var displayScale
    @Environment(\.coverImagePipeline) private var pipeline
    @State private var image: UIImage?

    private var request: CoverImageRequest? {
        CoverPixelSize.fitting(pointSize: size, scale: displayScale)
            .map { CoverImageRequest(source: .indexedCover(path: path), size: $0) }
    }

    var body: some View {
        Group {
            if let image = image ?? request.flatMap(pipeline.cachedImage(for:)) {
                Image(uiImage: image).resizable().scaledToFill().reportsCoverImage(image)
            } else {
                GeneratedBookCover(title: title, author: author)
            }
        }
        .task(id: request) {
            guard let request, pipeline.cachedImage(for: request) == nil else { return }
            image = await pipeline.image(for: request).image
        }
    }
}
