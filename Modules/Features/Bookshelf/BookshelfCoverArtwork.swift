import SwiftUI
import UIKit

// MARK: - Cover style

/// Cover styling the bookshelf shares between its list rows, its grid cells,
/// 書籍資訊's preview and the open-book transition.
enum BookshelfCoverStyle {
    /// 外觀主題 → 介面 → 預設封面 → 封面圓角. Read unobserved: `HomeView` observes
    /// `GlobalSettings`, so a change there rebuilds every row with the new value.
    static var cornerRadius: CGFloat {
        CGFloat(GlobalSettings.shared.bookshelfCoverCornerRadius)
    }

    /// What a card shows. Always something: the book's own cover, the user's
    /// 預設封面, one generated from the title, or, for the moment a saved cover takes
    /// to decode off the main thread, a neutral placeholder.
    ///
    /// Fills the frame the caller gives it; `displaySize` is that frame, and picks
    /// the decode size. The row, the grid cell and the transition snapshot all resolve
    /// through `BookshelfCoverPlan.shelf`, so 強制使用預設封面 cannot end up honored in
    /// one of them and ignored in another — a mismatch there shows as the cover
    /// swapping mid-animation. Each used to inline its own grey title card, which is
    /// how a local TXT with no artwork kept the old placeholder after the generated
    /// covers landed.
    @MainActor
    static func artwork(for book: ReadingBook, colorScheme: ColorScheme, displaySize: CGSize) -> some View {
        ShelfCoverSlot(book: book, colorScheme: colorScheme, displaySize: displaySize)
    }

    /// The bitmap a card is drawing, from memory only: the largest decoded size of
    /// the artwork the card resolves to. Nil when that is the generated cover, a
    /// catalog cover, or a saved cover that has not been decoded yet. Never reads a file.
    static func image(for book: ReadingBook, colorScheme: ColorScheme, filledCover: String? = nil) -> UIImage? {
        guard case .bitmap(let image, _) = cachedArtwork(for: .shelf(for: book, colorScheme: colorScheme, filledCover: filledCover)) else {
            return nil
        }
        return image
    }

    /// Bitmap form for the open-book transition, which lifts a picture rather than
    /// a view and so cannot take `artwork(for:)`.
    ///
    /// Memory only, never the disk: the transition starts from the tap, on the main
    /// thread. What the card shows is what gets lifted, so a card still showing its
    /// placeholder lifts a plain card (nil) rather than a cover it has not drawn.
    /// `snapshotUpgrade` supplies a sharper rendering of the same artwork once ready.
    @MainActor
    static func snapshot(
        for book: ReadingBook,
        colorScheme: ColorScheme,
        filledCover: String? = nil,
        sourceSize: CGSize? = nil
    ) -> UIImage? {
        switch cachedArtwork(for: .shelf(for: book, colorScheme: colorScheme, filledCover: filledCover)) {
        case .bitmap(let image, _):
            return image
        case .pending:
            return nil
        case .catalog(let catalog):
            // What `BookCoverImage` draws: the catalog cover once fetched, otherwise
            // its own placeholder, the 預設封面 or the generated cover.
            if let cover = book.coverUrl.flatMap({
                BookCoverLoader.cachedImage(for: $0, session: BookCoverLoader.remoteSession(for: book))
            }) {
                return cover
            }
            if let seed = catalog.defaultCoverSeed,
               let defaultCover = DefaultCoverLibrary.cachedImage(seed: seed, colorScheme: colorScheme) {
                return defaultCover
            }
            return generatedSnapshot(for: book, colorScheme: colorScheme, sourceSize: sourceSize)
        case .generated:
            return generatedSnapshot(for: book, colorScheme: colorScheme, sourceSize: sourceSize)
        }
    }

    /// Starts preparing the transition-size rendering of the bitmap the card is
    /// drawing and returns a memory-only lookup for it. The transition asks when it
    /// builds and again when it starts moving, and swaps it in only once it is ready;
    /// it never waits for it.
    ///
    /// Nil when the card is not drawing a pipeline bitmap: generated covers are
    /// rendered at transition size already, and catalog covers exist at one size only.
    @MainActor
    static func snapshotUpgrade(
        for book: ReadingBook,
        colorScheme: ColorScheme,
        filledCover: String? = nil
    ) -> (@MainActor () -> UIImage?)? {
        guard case .bitmap(_, let source) = cachedArtwork(for: .shelf(for: book, colorScheme: colorScheme, filledCover: filledCover)) else {
            return nil
        }
        let pipeline = CoverImagePipeline.shared
        let request = CoverImageRequest(source: source, size: .largest)
        if pipeline.cachedImage(for: request) == nil {
            // One bounded decode of the file just tapped, ahead of queued shelf
            // loads. Nobody awaits it: it finishes and publishes, so the reader's
            // 現代 chrome and Now Playing find it in memory as well.
            Task.detached(priority: .userInitiated) {
                _ = await pipeline.image(for: request, priority: .veryHigh)
            }
        }
        return { pipeline.cachedImage(for: request) }
    }

    private enum CachedArtwork {
        case bitmap(UIImage, CoverImageSource)
        /// A saved cover or 預設封面 not decoded yet: the card shows the placeholder.
        case pending
        case catalog(BookshelfCoverPlan.CatalogFallback)
        case generated
    }

    /// The same resolution `BookshelfCoverArtwork` makes, from memory alone.
    private static func cachedArtwork(for plan: BookshelfCoverPlan) -> CachedArtwork {
        let pipeline = CoverImagePipeline.shared
        if let own = plan.ownCover {
            if let image = pipeline.largestCachedImage(for: own) { return .bitmap(image, own) }
            if !pipeline.isKnownUnavailable(own) { return .pending }
        }
        if let catalog = plan.catalogFallback { return .catalog(catalog) }
        if let fallback = plan.defaultCover {
            if let image = pipeline.largestCachedImage(for: fallback) { return .bitmap(image, fallback) }
            if !pipeline.isKnownUnavailable(fallback) { return .pending }
        }
        return .generated
    }

    /// Keep the shelf's logical size so thumbnail typography and ornaments do not
    /// change at handoff; increase only pixel density for the lifted cover's expansion.
    @MainActor
    private static func generatedSnapshot(
        for book: ReadingBook,
        colorScheme: ColorScheme,
        sourceSize: CGSize?
    ) -> UIImage? {
        let settings = GlobalSettings.shared
        // Opens without a visible shelf source have no thumbnail to match.
        // Keep their existing full-cover canvas; remove this default if every
        // opening entry point eventually supplies source geometry.
        let layoutSize = sourceSize ?? CGSize(width: 300, height: 400)
        // Preserve at least the previous 800-pixel long edge. An integer scale
        // keeps pixel rounding from changing the bitmap's logical dimensions.
        let scale = max(2, ceil(800 / max(layoutSize.width, layoutSize.height, 1)))
        return GeneratedBookCoverRenderer.image(
            title: book.title,
            author: book.author,
            size: layoutSize,
            colorScheme: colorScheme,
            drawsName: settings.defaultCoverDrawsBookName,
            drawsAuthor: settings.defaultCoverDrawsBookAuthor,
            scale: scale
        )
    }
}

// MARK: - Plan

/// Which artwork a cover slot draws, decided from the book and the cover settings
/// alone: no file is opened to decide it. The shelf's order, unchanged:
///
/// 1. The book's own saved cover (`coverImagePath`, downloaded or user-picked),
///    unless 強制使用預設封面 is on.
/// 2. When there is none, or it turns out missing or unusable: a remote-library
///    book's catalog cover, drawn by `BookCoverImage` with the catalog's session.
/// 3. For a book with neither, the cover the filler gave it (unified library 3a-2,
///    `FilledCoverIndex`), in the own cover's slot.
/// 4. Otherwise the user's 預設封面 for this book.
/// 5. Otherwise `GeneratedBookCover`.
///
/// A step that has to be read from disk is only known to be unavailable once its
/// load finishes. Until then the slot shows a placeholder instead of skipping
/// ahead: starting the catalog download, or settling on the 預設封面, for a file
/// that is merely not decoded yet would be wrong.
struct BookshelfCoverPlan: Equatable {
    /// Draw `BookCoverImage` once the saved cover is known to be absent. It brings
    /// its own placeholder chain (預設封面 by `defaultCoverSeed`, then generated).
    struct CatalogFallback: Hashable {
        var defaultCoverSeed: String?
    }

    var ownCover: CoverImageSource?
    var catalogFallback: CatalogFallback?
    var defaultCover: CoverImageSource?
    var title: String
    var author: String

    /// A shelf row or grid cell, and the transition that lifts it.
    /// - `filledCover`: the filler's cover for this book (`FilledCoverIndex.path(for:)`).
    static func shelf(
        for book: ReadingBook,
        colorScheme: ColorScheme,
        filledCover: String? = nil,
        forcesDefaultCover: Bool = GlobalSettings.shared.useDefaultCoverForAllBooks
    ) -> BookshelfCoverPlan {
        let seed = book.id.uuidString
        let savedCover = book.coverImagePath.flatMap { $0.isEmpty ? nil : $0 }
        let hasCatalogCover = book.remoteSource != nil && book.coverUrl?.isEmpty == false
        let ownCover: CoverImageSource? = savedCover.map { .bookCover(filename: $0) }
            ?? (hasCatalogCover ? nil : filledCover.map { .indexedCover(path: $0) })
        return BookshelfCoverPlan(
            // 強制使用預設封面: the book's own artwork is never drawn, even when the
            // library is empty; that case falls through to the generated cover, as
            // Legado's built-in default cover does.
            ownCover: forcesDefaultCover ? nil : ownCover,
            catalogFallback: !forcesDefaultCover && hasCatalogCover
                ? CatalogFallback(defaultCoverSeed: seed)
                : nil,
            defaultCover: DefaultCoverLibrary.fileName(seed: seed, colorScheme: colorScheme)
                .map { .defaultCover(fileName: $0) },
            title: book.title,
            author: book.author
        )
    }

    /// 書籍資訊's preview: the saved cover as it is, even with 強制使用預設封面 on,
    /// because it is the cover being edited; otherwise `BookCoverImage` for the
    /// book's own address.
    static func bookInfo(for book: ReadingBook, filledCover: String? = nil) -> BookshelfCoverPlan {
        BookshelfCoverPlan(
            ownCover: book.coverImagePath.flatMap { $0.isEmpty ? nil : .bookCover(filename: $0) }
                ?? filledCover.map { .indexedCover(path: $0) },
            catalogFallback: CatalogFallback(defaultCoverSeed: nil),
            defaultCover: nil,
            title: book.title,
            author: book.author
        )
    }
}

// MARK: - Artwork view

/// A shelf cover slot with the cover the filler gave the book, if any (unified library 3a-2):
/// reads `FilledCoverIndex` from the environment, so a filled cover arriving redraws the
/// slots alone.
struct ShelfCoverSlot: View {
    let book: ReadingBook
    let colorScheme: ColorScheme
    let displaySize: CGSize
    @Environment(FilledCoverIndex.self) private var filledCovers: FilledCoverIndex?

    var body: some View {
        BookshelfCoverArtwork(
            book: book,
            plan: .shelf(for: book, colorScheme: colorScheme, filledCover: filledCovers?.path(for: book)),
            displaySize: displaySize
        )
    }
}

/// One cover slot. Its body only composes what memory already has (a decoded
/// bitmap, the placeholder, or a fallback that needs no file); the disk is read by
/// the slot's task, off the main thread, through `CoverImagePipeline`.
///
/// - A load finishing updates this slot's own state and nothing else: no
///   notification reaches the rest of the shelf.
/// - An image memory already has paints in the same pass, so scrolling back does
///   not flash the placeholder.
/// - A file changing on disk arrives as a `CoverInvalidation`; a slot drawing that
///   source drops its bitmap and loads again.
struct BookshelfCoverArtwork: View {
    let book: ReadingBook
    let plan: BookshelfCoverPlan
    /// The slot's frame in points. `.zero` until it is known (a grid before its
    /// first layout): the slot shows its placeholder and loads nothing yet.
    let displaySize: CGSize

    @Environment(\.displayScale) private var displayScale
    @Environment(\.coverImagePipeline) private var pipeline
    @State private var own = CoverSlotState()
    @State private var fallback = CoverSlotState()
    /// Bumped when a file this slot draws changes on disk, to restart its task.
    @State private var reloadGeneration = 0

    var body: some View {
        let requests = currentRequests
        artwork(for: resolvedContent(requests))
            .task(id: LoadID(requests: requests, catalog: plan.catalogFallback, generation: reloadGeneration)) {
                await load(requests)
            }
            .onReceive(pipeline.invalidations) { invalidation in
                reloadIfAffected(by: invalidation)
            }
            .onDisappear {
                // Off screen, the pipeline's budget decides what stays decoded; a slot
                // must not pin its bitmap for as long as SwiftUI keeps its state.
                own = CoverSlotState()
                fallback = CoverSlotState()
            }
    }

    // MARK: Composition

    private enum Content {
        case bitmap(UIImage)
        case placeholder
        case catalog(BookshelfCoverPlan.CatalogFallback)
        case generated
    }

    @ViewBuilder
    private func artwork(for content: Content) -> some View {
        switch content {
        case .bitmap(let image):
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .reportsCoverImage(image)
        case .placeholder:
            // Only while a file is being read. A neutral slot, not the generated
            // cover: that would read as this book's cover and then change.
            Rectangle()
                .fill(DSColor.neutralControlFill)
        case .catalog(let catalog):
            BookCoverImage(readingBook: book, defaultCoverSeed: catalog.defaultCoverSeed)
        case .generated:
            GeneratedBookCover(title: plan.title, author: plan.author)
        }
    }

    private struct Requests: Hashable {
        var own: CoverImageRequest?
        var fallback: CoverImageRequest?
    }

    private struct LoadID: Hashable {
        var requests: Requests
        var catalog: BookshelfCoverPlan.CatalogFallback?
        var generation: Int
    }

    private var currentRequests: Requests {
        guard let size = CoverPixelSize.fitting(pointSize: displaySize, scale: displayScale) else {
            return Requests()
        }
        return Requests(
            own: plan.ownCover.map { CoverImageRequest(source: $0, size: size) },
            fallback: plan.catalogFallback == nil
                ? plan.defaultCover.map { CoverImageRequest(source: $0, size: size) }
                : nil
        )
    }

    private func resolvedContent(_ requests: Requests) -> Content {
        if plan.ownCover != nil {
            guard let request = requests.own else { return .placeholder }
            switch phase(of: request, in: own) {
            case .image(let image): return .bitmap(image)
            case .pending: return .placeholder
            case .unavailable: break
            }
        }
        if let catalog = plan.catalogFallback { return .catalog(catalog) }
        if plan.defaultCover != nil {
            guard let request = requests.fallback else { return .placeholder }
            switch phase(of: request, in: fallback) {
            case .image(let image): return .bitmap(image)
            case .pending: return .placeholder
            case .unavailable: break
            }
        }
        return .generated
    }

    /// What this slot can draw for `request` right now: what it already loaded,
    /// else what memory holds. Never the disk.
    private func phase(of request: CoverImageRequest, in slot: CoverSlotState) -> CoverSlotState.Phase {
        if slot.request == request, slot.phase != .pending { return slot.phase }
        switch pipeline.cachedResult(for: request) {
        case .image(let image)?: return .image(image)
        case .unavailable?: return .unavailable
        default: break
        }
        // The same artwork at another size (rotation, a new column count): keep
        // drawing it until this size is ready instead of flashing the placeholder.
        if slot.request?.source == request.source, case .image(let image) = slot.phase {
            return .image(image)
        }
        return .pending
    }

    // MARK: Loading

    private enum Slot {
        case own
        case fallback
    }

    private func load(_ requests: Requests) async {
        // Let go of bitmaps for artwork this slot no longer shows.
        if own.request?.source != plan.ownCover { own = CoverSlotState() }
        if fallback.request?.source != plan.defaultCover { fallback = CoverSlotState() }

        if plan.ownCover != nil {
            guard let request = requests.own else { return }
            let result = await resolve(request, into: .own)
            // Only a cover known to be unusable falls through; a load that was
            // superseded or cancelled leaves the placeholder for the reload.
            guard case .unavailable = result else { return }
        }
        guard let request = requests.fallback else { return }
        _ = await resolve(request, into: .fallback)
    }

    private func resolve(_ request: CoverImageRequest, into slot: Slot) async -> CoverImageResult {
        let result = await pipeline.image(for: request)
        guard !Task.isCancelled else { return .cancelled }
        let phase: CoverSlotState.Phase
        switch result {
        case .image(let image):
            phase = .image(image)
        case .unavailable:
            phase = .unavailable
        case .superseded, .cancelled:
            return result
        }
        let state = CoverSlotState(request: request, phase: phase)
        switch slot {
        case .own:
            if own != state { own = state }
        case .fallback:
            if fallback != state { fallback = state }
        }
        return result
    }

    private func reloadIfAffected(by invalidation: CoverInvalidation) {
        let ownAffected = plan.ownCover.map(invalidation.affects) ?? false
        let fallbackAffected = plan.defaultCover.map(invalidation.affects) ?? false
        guard ownAffected || fallbackAffected else { return }
        if ownAffected { own = CoverSlotState() }
        if fallbackAffected { fallback = CoverSlotState() }
        reloadGeneration &+= 1
    }
}

extension EnvironmentValues {
    /// The pipeline cover slots load through. The app always uses `.shared`; tests
    /// hand a slot one reading a temporary directory, to watch what its body does.
    @Entry var coverImagePipeline: CoverImagePipeline = .shared
}

/// What one slot has loaded. Holding the bitmap here, while the slot is on screen,
/// is what keeps memory-pressure eviction in the pipeline from blanking a cover
/// someone is looking at.
private struct CoverSlotState: Equatable {
    enum Phase: Equatable {
        case pending
        case image(UIImage)
        case unavailable
    }

    var request: CoverImageRequest?
    var phase: Phase = .pending
}

#Preview("書架封面 – 無封面／生成封面") {
    HStack(spacing: DSSpacing.lg) {
        BookshelfCoverStyle.artwork(
            for: ReadingBook(title: "宿命之環", author: "愛潛水的烏賊", contentFilename: "x.txt"),
            colorScheme: .light,
            displaySize: CGSize(width: 45, height: 65)
        )
        .frame(width: 45, height: 65)
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.sm))

        BookshelfCoverStyle.artwork(
            for: ReadingBook(title: "劍燭大荒", author: "青山鶴", contentFilename: "y.txt"),
            colorScheme: .light,
            displaySize: CGSize(width: 110, height: 165)
        )
        .frame(width: 110, height: 165)
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.md))
    }
    .padding()
}
