import SwiftUI

/// Remote book cover with the headers source CDNs need, falling back to the
/// user's 預設封面 library and then to `GeneratedBookCover` when there's no cover
/// (or it fails to load).
///
/// Fills whatever frame the caller gives it (`scaledToFill`, clipped). Apply the
/// frame + `clipShape` outside:
/// ```swift
/// BookCoverImage(onlineBook: book)
///     .frame(width: 104, height: 138)
///     .clipShape(RoundedRectangle(cornerRadius: DSRadius.lg))
/// ```
struct BookCoverImage: View {
    let coverURL: String
    let title: String
    /// Drawn down the right edge of the generated cover when there's no artwork.
    /// Optional because plenty of slots (cover pickers, OPDS rows) genuinely have
    /// no author to show.
    var author: String?
    var sourceBaseURL: String?
    var sourceHeaders: [String: String]
    /// Stable key identifying the book, when this slot may fall back to the
    /// user's 預設封面 library. `nil` goes straight to `GeneratedBookCover` — only
    /// the surfaces 預設封面 covers (書架, and 探索 when enabled) pass a seed.
    var defaultCoverSeed: String?

    @State private var image: UIImage?
    @Environment(\.colorScheme) private var colorScheme

    init(
        coverURL: String,
        title: String,
        author: String? = nil,
        sourceBaseURL: String? = nil,
        sourceHeaders: [String: String] = [:],
        defaultCoverSeed: String? = nil
    ) {
        self.coverURL = coverURL
        self.title = title
        self.author = author
        self.sourceBaseURL = sourceBaseURL
        self.sourceHeaders = sourceHeaders
        self.defaultCoverSeed = defaultCoverSeed
        // Cache hits paint on the first layout pass — no placeholder flash and
        // no extra state publish per cell while a list scrolls.
        _image = State(initialValue: BookCoverLoader.cachedImage(for: coverURL))
    }

    var body: some View {
        ZStack {
            if let image, !forcesDefaultCover {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if let defaultCover = resolvedDefaultCover {
                Image(uiImage: defaultCover)
                    .resizable()
                    .scaledToFill()
            } else {
                GeneratedBookCover(title: title, author: author)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: coverURL) { await load() }
    }

    /// 強制使用預設封面: the book's own artwork is ignored everywhere it is drawn,
    /// exactly like Legado's `useDefaultCover` short-circuit in `BookCover.load`.
    private var forcesDefaultCover: Bool {
        GlobalSettings.shared.useDefaultCoverForAllBooks
    }

    /// The default cover this slot should show, if any. Forcing applies to every
    /// book, so it also supplies a seed to slots that opted out of the library.
    private var resolvedDefaultCover: UIImage? {
        guard let seed = defaultCoverSeed ?? (forcesDefaultCover ? title : nil) else { return nil }
        return DefaultCoverLibrary.image(seed: seed, colorScheme: colorScheme)
    }

    // Runs on the MainActor (`.task` inherits the view's actor), so state
    // assignments need no explicit hop.
    private func load() async {
        // Nothing on screen would use it: the default cover wins for every book.
        // Not conditional on the library having images any more — an empty
        // library now lands on `GeneratedBookCover` rather than on the book's own
        // artwork, so downloading it would be wasted either way.
        if forcesDefaultCover { return }
        if let cached = BookCoverLoader.cachedImage(for: coverURL) {
            if image !== cached { image = cached }
            return
        }
        if image != nil { image = nil }  // avoid showing a reused cell's old cover
        let headers = BookCoverLoader.headers(sourceBaseURL: sourceBaseURL, sourceHeaders: sourceHeaders)
        let loaded = await BookCoverLoader.loadImage(urlString: coverURL, headers: headers)
        if !Task.isCancelled { image = loaded }
    }
}

extension BookCoverImage {
    /// Convenience for online/discover books — resolves the source's base URL and
    /// header rule from `BookSourceStore` so covers carry the right Referer/UA.
    @MainActor
    init(onlineBook: OnlineBook) {
        let source = BookSourceStore.shared.sources.first { $0.id == onlineBook.sourceId }
        self.init(
            coverURL: onlineBook.coverUrl,
            title: onlineBook.name,
            author: onlineBook.author,
            sourceBaseURL: source?.bookSourceUrl,
            sourceHeaders: source?.parsedHeaders ?? [:]
        )
    }
}

/// Headphones badge marking an audiobook cover, matching the audiobook detail page.
/// Overlay it at a cover's `.bottomTrailing` (after the cover's own `clipShape`) so
/// audiobooks are distinguishable wherever covers are listed.
struct AudiobookCoverBadge: View {
    var glyphSize: CGFloat = 9

    var body: some View {
        Image(systemName: "headphones")
            .font(DSFont.fixed(size: glyphSize, weight: .bold))
            .foregroundStyle(.white)
            .padding(glyphSize * 0.5)
            .background(DSColor.accent, in: Circle())
            .overlay(Circle().stroke(Color.white.opacity(0.85), lineWidth: 0.5))
            .padding(2)
    }
}

#Preview {
    HStack(spacing: 16) {
        BookCoverImage(coverURL: "", title: "劍燭大荒", author: "青山鶴")
            .frame(width: 104, height: 138)
            .clipShape(RoundedRectangle(cornerRadius: DSRadius.lg))
        GeneratedBookCover(title: "宿命之環", author: "愛潛水的烏賊")
            .frame(width: 104, height: 138)
            .clipShape(RoundedRectangle(cornerRadius: DSRadius.lg))
    }
    .padding()
}
