import SwiftUI

/// Remote book cover with the headers source CDNs need, falling back to the
/// user's 預設封面 library and then to `GeneratedBookCover` when there's no cover
/// (or it fails to load). While it loads, the slot is a grey skeleton (maintainer,
/// 2026-10-27: 「要加載封面都可以改成骨架屏佔位」), not a cover that would read as
/// this book's and then change.
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
    /// Set by the shelf and discover initializers instead of `sourceBaseURL`/`sourceHeaders`:
    /// the source is looked up, and its header rule (possibly JavaScript) evaluated, only when
    /// the cover actually has to be fetched, off the main thread. See `init(readingBook:)`.
    var sourceID: UUID?
    var session: URLSession?
    /// Stable key identifying the book, when this slot may fall back to the
    /// user's 預設封面 library. `nil` goes straight to `GeneratedBookCover` — only
    /// the surfaces 預設封面 covers (書架, and 探索 when enabled) pass a seed.
    var defaultCoverSeed: String?

    /// The cover this slot fetched, with the cache key it was fetched for. Held by
    /// the slot, not just the pipeline's memory, so a slot whose view lives on while
    /// its task runs again (it reappears) does not read an eviction as "no cover" and
    /// blank its bitmap until a refetch lands. It does not outlive the view: a lazy
    /// stack discards rows scrolled far away (seen on iOS 27 with the 發現頁's sections
    /// and 查看全部's rows), and those come back to whatever the pipeline still has.
    @State private var loaded: HeldRemoteCover?
    /// The cache key whose fetch came back with nothing: the slot shows its fallback, not
    /// the skeleton. A cancelled fetch is not a failure.
    @State private var failedKey: String?
    /// The 預設封面 this slot falls back to, once decoded off the main thread.
    @State private var loadedDefaultCover: LoadedDefaultCover?
    @Environment(\.colorScheme) private var colorScheme

    init(
        coverURL: String,
        title: String,
        author: String? = nil,
        sourceBaseURL: String? = nil,
        sourceHeaders: [String: String] = [:],
        defaultCoverSeed: String? = nil,
        session: URLSession? = nil,
        sourceID: UUID? = nil
    ) {
        self.coverURL = coverURL
        self.title = title
        self.author = author
        self.sourceBaseURL = sourceBaseURL
        self.sourceHeaders = sourceHeaders
        self.sourceID = sourceID
        self.defaultCoverSeed = defaultCoverSeed
        self.session = session
        // Cache hits paint on the first layout pass — no placeholder flash and
        // no extra state publish per cell while a list scrolls.
        let key = BookCoverLoader.cacheKey(for: coverURL, session: session)
        _loaded = State(initialValue: BookCoverLoader.cachedImage(for: coverURL, session: session)
            .map { HeldRemoteCover(key: key, image: $0) })
    }

    private var cacheKey: String { BookCoverLoader.cacheKey(for: coverURL, session: session) }

    /// The fetched cover for the address this slot shows now; a slot reused for
    /// another address never shows the previous one's cover.
    private var image: UIImage? { loaded?.image(for: cacheKey) }

    /// Fetching the cover: an address, not forced to the 預設封面, nothing fetched for it yet and
    /// no failure. An empty address goes straight to the fallback.
    private var isLoading: Bool {
        !forcesDefaultCover && !coverURL.isEmpty && image == nil && failedKey != cacheKey
    }

    var body: some View {
        ZStack {
            if let image, !forcesDefaultCover {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if isLoading {
                Rectangle()
                    .fill(DSColor.neutralControlFill)
            } else if let defaultCover = resolvedDefaultCover {
                Image(uiImage: defaultCover)
                    .resizable()
                    .scaledToFill()
            } else {
                GeneratedBookCover(title: title, author: author)
            }
        }
        // Nothing while the skeleton shows: a colour taken from it would be the grey's.
        .reportsCoverImage(image.flatMap { forcesDefaultCover ? nil : $0 } ?? (isLoading ? nil : resolvedDefaultCover))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: LoadID(
            cover: cacheKey,
            defaultCover: defaultCoverRequest
        )) { await load() }
    }

    private struct LoadID: Hashable {
        var cover: String
        var defaultCover: CoverImageRequest?
    }

    private struct LoadedDefaultCover {
        let request: CoverImageRequest
        let image: UIImage
    }

    /// 強制使用預設封面: the book's own artwork is ignored everywhere it is drawn,
    /// exactly like Legado's `useDefaultCover` short-circuit in `BookCover.load`.
    private var forcesDefaultCover: Bool {
        GlobalSettings.shared.useDefaultCoverForAllBooks
    }

    /// The 預設封面 this slot falls back to, if any. Forcing applies to every book,
    /// so it also supplies a seed to slots that opted out of the library. Pure: which
    /// file, not its pixels.
    private var defaultCoverRequest: CoverImageRequest? {
        guard let seed = defaultCoverSeed ?? (forcesDefaultCover ? title : nil),
              let fileName = DefaultCoverLibrary.fileName(seed: seed, colorScheme: colorScheme) else {
            return nil
        }
        return DefaultCoverLibrary.request(fileName: fileName)
    }

    /// The default cover this slot should show, from memory only. One not decoded
    /// yet is loaded by `load()`, never read here: this runs in `body`.
    private var resolvedDefaultCover: UIImage? {
        guard let request = defaultCoverRequest else { return nil }
        if let loadedDefaultCover, loadedDefaultCover.request == request {
            return loadedDefaultCover.image
        }
        return CoverImagePipeline.shared.cachedImage(for: request)
    }

    // Runs on the MainActor (`.task` inherits the view's actor), so state
    // assignments need no explicit hop.
    private func load() async {
        // Nothing on screen would use it: the default cover wins for every book.
        // Not conditional on the library having images any more — an empty
        // library now lands on `GeneratedBookCover` rather than on the book's own
        // artwork, so downloading it would be wasted either way.
        if forcesDefaultCover {
            await loadDefaultCover()
            return
        }
        let key = cacheKey
        if let cached = BookCoverLoader.cachedImage(for: coverURL, session: session) {
            if loaded?.image(for: key) !== cached { loaded = HeldRemoteCover(key: key, image: cached) }
            return
        }
        // Memory let go of its copy; this slot did not. Nothing to fetch.
        if loaded?.image(for: key) != nil { return }
        // The 預設封面 is the fallback when the network cover fails, decoded first so a
        // failure lands on it, not on the generated cover. The skeleton shows meanwhile.
        await loadDefaultCover()
        guard !Task.isCancelled else { return }
        let fetched = await Self.fetchCover(coverURL: coverURL, sourceBaseURL: sourceBaseURL,
                                            sourceHeaders: sourceHeaders, sourceID: sourceID, session: session)
        guard !Task.isCancelled else { return }
        loaded = fetched.map { HeldRemoteCover(key: key, image: $0) }
        if fetched == nil { failedKey = key }
    }

    /// The cover at `coverURL`, from memory or fetched with the headers its CDN needs: the
    /// source's base URL and header rule when `sourceID` names one (looked up only now), else
    /// those given. Nil when it fails, or when the task is cancelled. 作品詳情's series fan
    /// loads its volumes' covers through this too, before it draws any of them.
    static func fetchCover(coverURL: String, sourceBaseURL: String?, sourceHeaders: [String: String],
                           sourceID: UUID?, session: URLSession?) async -> UIImage? {
        if let cached = BookCoverLoader.cachedImage(for: coverURL, session: session) { return cached }
        var baseURL = sourceBaseURL
        var sourceHeaders = sourceHeaders
        if let sourceID, let resolved = await resolveSource(sourceID) {
            guard !Task.isCancelled else { return nil }
            baseURL = resolved.baseURL
            sourceHeaders = resolved.headers
        }
        let headers = BookCoverLoader.headers(sourceBaseURL: baseURL, sourceHeaders: sourceHeaders)
        return await BookCoverLoader.loadImage(urlString: coverURL, headers: headers, session: session)
    }

    /// Decodes this slot's 預設封面 off the main thread when memory does not have
    /// it, and holds it while the slot is alive.
    private func loadDefaultCover() async {
        guard let request = defaultCoverRequest else { return }
        let decoded: UIImage
        if let cached = CoverImagePipeline.shared.cachedImage(for: request) {
            decoded = cached
        } else {
            guard let loaded = await CoverImagePipeline.shared.image(for: request).image,
                  !Task.isCancelled else { return }
            decoded = loaded
        }
        if loadedDefaultCover?.request != request || loadedDefaultCover?.image !== decoded {
            loadedDefaultCover = LoadedDefaultCover(request: request, image: decoded)
        }
    }
}

/// A fetched remote cover and the cache key (address and session) it belongs to.
struct HeldRemoteCover {
    let key: String
    let image: UIImage

    func image(for key: String) -> UIImage? {
        self.key == key ? image : nil
    }
}

extension BookCoverImage {
    /// Saved remote books use the same authenticated catalog transport as browsing.
    /// Local/custom cover selection stays with the caller's existing artwork route.
    ///
    /// Cheap on purpose: it runs for every shelf cover on every render of the shelf. It used
    /// to scan the whole source library for the book's source and evaluate its header rule
    /// here — 15 ms a cover at 50 000 sources, and a `@js` rule waited synchronously on the
    /// source's JavaScript queue, on the main thread. Both now happen in `load()`, only when
    /// the cover is not cached.
    init(readingBook book: ReadingBook, defaultCoverSeed: String? = nil) {
        self.init(coverURL: book.coverUrl ?? "", title: book.title, author: book.author,
                  defaultCoverSeed: defaultCoverSeed, session: BookCoverLoader.remoteSession(for: book),
                  sourceID: book.bookSourceId)
    }

    /// Convenience for online/discover books; the source's base URL and header rule are
    /// resolved the same way, when the cover is fetched.
    init(onlineBook: OnlineBook) {
        self.init(coverURL: onlineBook.coverUrl, title: onlineBook.name, author: onlineBook.author,
                  sourceID: onlineBook.sourceId)
    }

    /// The source's base URL and evaluated header rule. Waits for the library read, looks the
    /// source up by id, and resolves the rule on the source's host if it has not yet.
    static func resolveSource(_ id: UUID) async -> (baseURL: String, headers: [String: String])? {
        let store = BookSourceStore.shared
        await store.waitUntilLoaded()
        guard let source = store.source(id: id) else { return nil }
        let headers = await source.resolvedHeaders()
        return (source.bookSourceUrl, headers)
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
            .foregroundStyle(DSColor.textOnAccent)
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
