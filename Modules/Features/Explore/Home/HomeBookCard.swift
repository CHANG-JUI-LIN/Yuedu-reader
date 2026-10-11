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
    }

    let id: SourceItemKey
    let title: String
    let author: String
    let cover: Cover
    /// The Emby line: 已加入書架, 已下載, or a shelf copy's 新增 or how far it is read.
    let detail: String?
    /// How far a shelf copy is read, for the bar along its cover; nil when unread or finished.
    let progress: Double?
    let accessibilityLabel: String
    let accessibilityValue: String
    let opening: ItemOpening

    /// - Parameters:
    ///   - status: the item's copies on this device (`CopyLookup.status(for:)`). Book-source
    ///     items find none: `CopyLookup` leaves book-source copies out, so their cards show
    ///     no status.
    ///   - shelfBooks: the shelf records of this row's `.copy` items, read live so progress
    ///     is current.
    @MainActor
    init?(_ entry: CollectionEntry, sourceName: String, status: (SourceItemKey) -> CopyLookup.Status?,
          shelfBooks: [UUID: ReadingBook], connections: RemoteLibraryConnectionStore = .shared) {
        guard case .item(let record, let summary, let opening) = entry else { return nil }
        id = record.key
        self.opening = opening
        title = summary.title
        author = summary.authors.joined(separator: "、")
        if case .copy(let bookID) = opening, let book = shelfBooks[bookID] {
            cover = .shelf(book)
            let read = book.currentPosition
            detail = BookshelfAccessibility.readingStatus(for: book)
            progress = read > 0 && read < 0.99 ? read : nil
            // Read exactly as the shelf reads the book, how far it is read included.
            accessibilityLabel = BookshelfAccessibility.description(for: book)
            accessibilityValue = ""
            return
        }
        cover = .reference(summary.cover, session: Self.session(for: opening, connections: connections))
        let status = status(record.key)
        detail = status?.title
        progress = nil
        accessibilityLabel = summary.title
        accessibilityValue = [author, sourceName, status?.title ?? ""].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// A library's covers come through its connection's session, which carries its sign-in;
    /// Gutenberg's through the built-in connection's, as the store and a shelf copy load them.
    @MainActor
    private static func session(for opening: ItemOpening, connections: RemoteLibraryConnectionStore) -> URLSession? {
        switch opening {
        case .opdsEntry(_, let connectionID), .webDAVFile(_, let connectionID):
            return connections.connection(id: connectionID).map { connections.httpClient(for: $0).session }
        case .gutenberg:
            return connections.connection(id: PublicLibraryID.gutenberg.rawValue).map { connections.httpClient(for: $0).session }
        default:
            return nil
        }
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

    private var coverSize: CGSize {
        CGSize(width: coverWidth, height: coverWidth / DSLayout.discoverCoverAspectRatio)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xxs) {
            HomeCardCover(cover: content.cover, title: content.title, author: content.author, size: coverSize)
                .overlay(alignment: .bottom) {
                    if let progress = content.progress { progressBar(progress) }
                }
                .modifier(PublicLibraryCoverAnchor(id: content.publicLibraryBookID))
                .padding(.bottom, DSSpacing.sm)
            Text(content.title)
                .font(DSFont.subheadline.weight(.semibold))
                .foregroundStyle(DSColor.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if !content.author.isEmpty {
                Text(content.author)
                    .font(DSFont.footnote)
                    .foregroundStyle(DSColor.textSecondary)
                    .lineLimit(1)
            }
            if let detail = content.detail {
                Text(detail)
                    .font(DSFont.caption)
                    .foregroundStyle(DSColor.textSecondary)
                    .lineLimit(1)
            }
        }
        // Cards in a row align at the top, as Apple Books' do, whatever each one's text runs to.
        .frame(width: coverWidth, alignment: .topLeading)
        .contentShape(Rectangle())
    }

    /// Hidden from VoiceOver: the card's label already says how far the book is read.
    private func progressBar(_ progress: Double) -> some View {
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
private struct PublicLibraryCoverAnchor: ViewModifier {
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
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DSRadius.searchListCover, style: .continuous)
        artwork
            .frame(width: size.width, height: size.height)
            .clipShape(shape)
            .shadow(color: DSColor.searchListCoverShadow, radius: DSLayout.searchListCoverShadowRadius,
                    y: DSLayout.searchListCoverShadowY)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var artwork: some View {
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
                Image(uiImage: image).resizable().scaledToFill()
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
