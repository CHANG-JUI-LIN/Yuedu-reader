import SwiftUI

/// Remote book cover with the headers source CDNs need, falling back to the
/// app's title-card placeholder when there's no cover (or it fails to load).
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
    var sourceBaseURL: String?
    var sourceHeaders: [String: String]
    /// Stable key identifying the book, when this slot may fall back to the
    /// user's 預設封面 library. `nil` keeps the plain title card — only the
    /// surfaces 預設封面 covers (書架, and 探索 when enabled) pass a seed.
    var defaultCoverSeed: String?

    @State private var image: UIImage?
    @Environment(\.colorScheme) private var colorScheme

    init(
        coverURL: String,
        title: String,
        sourceBaseURL: String? = nil,
        sourceHeaders: [String: String] = [:],
        defaultCoverSeed: String? = nil
    ) {
        self.coverURL = coverURL
        self.title = title
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
                TitleCardPlaceholder(title: title)
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
        if forcesDefaultCover, DefaultCoverLibrary.hasImages(for: colorScheme) { return }
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

/// The shared no-cover placeholder: title text on a neutral card, matching the
/// bookshelf. Used wherever a cover is missing.
struct TitleCardPlaceholder: View {
    let title: String

    var body: some View {
        Rectangle()
            .fill(Color(.secondarySystemBackground))
            .overlay(alignment: .topLeading) {
                Text(title)
                    .font(DSFont.fixed(size: 11, weight: .medium))
                    .foregroundColor(DSColor.textSecondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(6)
                    .padding(8)
            }
    }
}

#Preview {
    HStack(spacing: 16) {
        BookCoverImage(coverURL: "", title: "劍燭大荒")
            .frame(width: 104, height: 138)
            .clipShape(RoundedRectangle(cornerRadius: DSRadius.lg))
        TitleCardPlaceholder(title: "宿命之環")
            .frame(width: 104, height: 138)
            .clipShape(RoundedRectangle(cornerRadius: DSRadius.lg))
    }
    .padding()
}
