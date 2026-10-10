import SwiftUI
import Combine
import UIKit

struct PublicLibrarySheetContext {
    let artworkHeight: CGFloat
    let openReader: (UUID) -> Void
    let openAuthor: (PublicLibraryAuthorDestination) -> Void
}
private struct PublicLibrarySheetContextKey: EnvironmentKey {
    static let defaultValue: PublicLibrarySheetContext? = nil
}

// MARK: - Presentation

/// Where the store's covers are on screen, so each card opens out of its own cover and
/// closes back into it, as Apple Books' cards do. A book can sit on two shelves (the
/// 經典選讀 rows repeat 中文書籍), so covers are kept per shelf (`scope`) and a tap
/// marks the shelf it came from.
///
/// Each cover leaves a UIKit anchor behind itself and its frame is read from that view
/// when a card opens or closes. SwiftUI's reported geometry cannot be used: on the
/// tab's first appearance it reports a layout pass with the shelf's covers at 212pt
/// that never reaches the screen (they are drawn, and found by accessibility, at
/// 180pt), and never reports the real size after it — measured 2026-10-09.
final class PublicLibraryCoverFrames {
    private final class Anchor { weak var view: UIView? }
    private var anchors: [String: Anchor] = [:]
    /// The shelf the last book was opened from.
    var activeScope = ""

    func register(_ view: UIView, scope: String, id: String) {
        let anchor = anchors[scope + "|" + id] ?? Anchor()
        anchor.view = view
        anchors[scope + "|" + id] = anchor
    }

    /// The cover's frame on screen, in window (global) coordinates.
    func frame(for id: String) -> CGRect? {
        guard let view = anchors[activeScope + "|" + id]?.view, view.window != nil else { return nil }
        return view.convert(view.bounds, to: nil)
    }
}

private struct PublicLibraryCoverScopeKey: EnvironmentKey {
    static let defaultValue = ""
}

private struct PublicLibraryCoverFramesKey: EnvironmentKey {
    static let defaultValue: PublicLibraryCoverFrames? = nil
}

private struct OpenPublicLibraryBooksKey: EnvironmentKey {
    static let defaultValue: ((PublicLibraryBookSelection) -> Void)? = nil
}

extension EnvironmentValues {
    var publicLibrarySheet: PublicLibrarySheetContext? {
        get { self[PublicLibrarySheetContextKey.self] }
        set { self[PublicLibrarySheetContextKey.self] = newValue }
    }

    /// The shelf the covers below belong to; see `PublicLibraryCoverFrames`.
    var publicLibraryCoverScope: String {
        get { self[PublicLibraryCoverScopeKey.self] }
        set { self[PublicLibraryCoverScopeKey.self] = newValue }
    }

    var publicLibraryCoverFrames: PublicLibraryCoverFrames? {
        get { self[PublicLibraryCoverFramesKey.self] }
        set { self[PublicLibraryCoverFramesKey.self] = newValue }
    }

    /// Opens the store's book carousel over the nearest host.
    var openPublicLibraryBooks: ((PublicLibraryBookSelection) -> Void)? {
        get { self[OpenPublicLibraryBooksKey.self] }
        set { self[OpenPublicLibraryBooksKey.self] = newValue }
    }
}

extension View {
    /// Shows the book carousel over this view — inside the tab, so the tab bar stays
    /// over it as Apple Books keeps it — and lets every page below open it through
    /// `openPublicLibraryBooks`.
    ///
    /// Apply to the tab's `NavigationStack`, with its path: an author or the reader
    /// opened from a card is pushed on that stack, the card waiting hidden underneath
    /// until the stack comes back to it. The stack's root needs
    /// `publicLibraryDestinations()`.
    /// `request` is for the view applying it, which cannot read the action it puts in
    /// the environment of the pages below it: a selection set there opens at once.
    func publicLibraryBookCarousel(path: Binding<NavigationPath>,
                                   request: Binding<PublicLibraryBookSelection?>,
                                   coverFrames: PublicLibraryCoverFrames) -> some View {
        modifier(PublicLibraryCarouselHost(path: path, request: request, frames: coverFrames))
    }

    /// The pages pushed on the store's stack: its own pages (`PublicLibraryRoute`), and from a
    /// carousel card an author's books and the reader.
    func publicLibraryDestinations() -> some View {
        modifier(PublicLibraryDestinations())
    }

    /// Records this cover's frame as the place a card for `id` opens from.
    func publicLibraryCoverFrame(id: String) -> some View {
        modifier(PublicLibraryCoverFrameReporter(id: id))
    }
}

private struct PublicLibraryCoverFrameReporter: ViewModifier {
    let id: String
    @Environment(\.publicLibraryCoverFrames) private var frames
    @Environment(\.publicLibraryCoverScope) private var scope

    func body(content: Content) -> some View {
        content.background {
            if let frames { PublicLibraryCoverAnchorView(frames: frames, scope: scope, id: id) }
        }
    }
}

private struct PublicLibraryCoverAnchorView: UIViewRepresentable {
    let frames: PublicLibraryCoverFrames
    let scope: String
    let id: String

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        frames.register(view, scope: scope, id: id)
    }
}

/// A book pushed from a card into the reader.
struct PublicLibraryReaderRoute: Hashable {
    let bookID: UUID
}

/// A page of the store, pushed by value so every page the store opens is on its stack's
/// path: the carousel ties each open card to the path's depth (`PublicLibraryCarouselHost`),
/// and Explore's home pushes these on the one stack it shares with every source (unified
/// library 5c, decision 5). Catalog values are snapshots; equality is by what the page shows.
enum PublicLibraryRoute: Hashable {
    case categories(AozoraCatalogIndex?)
    /// A bundled list, by `PublicLibraryCollection.id`.
    case collection(id: String)
    case aozoraWorks(title: String, works: [AozoraWork], index: AozoraCatalogIndex)
    case aozoraCatalog(AozoraBrowseMode, AozoraCatalogIndex)

    private var key: [String] {
        switch self {
        case .categories: ["categories"]
        case .collection(let id): ["collection", id]
        case .aozoraWorks(let title, let works, _): ["aozoraWorks", title] + works.map(\.id)
        case .aozoraCatalog(let mode, _): ["aozoraCatalog", mode.rawValue]
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }
    func hash(into hasher: inout Hasher) { hasher.combine(key) }
}

/// What a card pushes on the tab's stack.
enum PublicLibraryCarouselPush {
    case reader(UUID)
    case author(PublicLibraryAuthorDestination)
}

private struct PublicLibraryCarouselHost: ViewModifier {
    @Binding var path: NavigationPath
    @Binding var request: PublicLibraryBookSelection?
    /// Owned by the view applying the host, which taps covers of its own.
    let frames: PublicLibraryCoverFrames
    /// Open carousels, each tied to the stack depth it was opened at; only the one at
    /// the stack's current depth shows. A book opened from an author's page pushed by
    /// a card opens a carousel of its own at that page's depth.
    @State private var entries: [Entry] = []

    private struct Entry: Identifiable {
        let selection: PublicLibraryBookSelection
        let depth: Int
        var id: UUID { selection.id }
    }

    func body(content: Content) -> some View {
        content
            .environment(\.publicLibraryCoverFrames, frames)
            .environment(\.openPublicLibraryBooks) { selection in
                entries.append(Entry(selection: selection, depth: path.count))
            }
            .overlay {
                ZStack {
                    ForEach(entries) { entry in
                        let isShowing = entry.depth == path.count
                        PublicLibraryBookSheet(
                            selection: entry.selection, coverFrames: frames,
                            push: { route in
                                switch route {
                                case .reader(let id): path.append(PublicLibraryReaderRoute(bookID: id))
                                case .author(let author): path.append(author)
                                }
                            },
                            onClosed: { entries.removeAll { $0.id == entry.id } })
                            .opacity(isShowing ? 1 : 0)
                            .allowsHitTesting(isShowing)
                            .accessibilityHidden(!isShowing)
                    }
                }
            }
            // Popping below a carousel's page discards it.
            .onChange(of: path.count) { _, depth in entries.removeAll { $0.depth > depth } }
            .onChange(of: request?.id) { _, _ in
                guard let selection = request else { return }
                entries.append(Entry(selection: selection, depth: path.count))
                request = nil
            }
    }
}

private struct PublicLibraryDestinations: ViewModifier {
    @EnvironmentObject private var store: BookStore

    func body(content: Content) -> some View {
        content
            .navigationDestination(for: PublicLibraryRoute.self) { route in
                switch route {
                case .categories(let index):
                    PublicLibraryCategoriesView(index: index)
                case .collection(let id):
                    if let collection = PublicLibraryCollection.all.first(where: { $0.id == id }) {
                        PublicLibraryCollectionView(collection: collection)
                    }
                case .aozoraWorks(let title, let works, let index):
                    AozoraWorksView(index: index, works: works, title: title)
                case .aozoraCatalog(let mode, let index):
                    AozoraCatalogView(index: index, mode: mode)
                }
            }
            .navigationDestination(for: PublicLibraryReaderRoute.self) { route in
                BookReaderView(bookId: route.bookID).environmentObject(store)
                    .environment(\.readerNavigator, nil)
                    .environment(\.readerUsesParentNavigationStack, true)
                    .navigationBarBackButtonHidden(true)
                    .reservingNavigationBackSwipe()
            }
            .navigationDestination(for: PublicLibraryAuthorDestination.self) { destination in
                switch destination {
                case .gutenberg(let author):
                    PublicLibraryFeedView(route: OPDSFeedRoute(catalogID: PublicLibraryID.gutenberg.rawValue,
                        url: author.url.absoluteString, title: author.name, presentation: .storefront))
                case .aozora(let author, let index):
                    AozoraWorksView(index: index, works: index.works(forPerson: author.id), title: author.name)
                }
            }
    }
}

/// Apple Books' store card, over the store inside its tab. The cards open out of the
/// tapped cover over a dimming store; each rests just below the status bar, and
/// scrolling it up widens it to the screen edges as its top reaches the top of the
/// screen. The card's own vertical scroll view is the expansion gesture and the
/// horizontal scroll view pages between books — no drag gesture competes with either;
/// paging is locked while a card is scrolled. Pulling a resting card down and letting
/// go, or its close button, drops it back to the cover's height and shrinks it into
/// the cover.
struct PublicLibraryBookSheet: View {
    let selection: PublicLibraryBookSelection
    let coverFrames: PublicLibraryCoverFrames
    let push: (PublicLibraryCarouselPush) -> Void
    let onClosed: () -> Void

    private enum Phase { case cover, presented, dropped, closed }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var phase = Phase.cover
    /// Apart from the phase: Apple Books' card turns solid within its first 0.1 s,
    /// long before the spring that carries it settles.
    @State private var isOpaque = false
    /// How far the row was pulled down when it was let go to close. The row takes it
    /// over and the selected card cancels its scroll view's bounce back (see
    /// `PublicLibraryPullFollow`), so the close runs from where the finger left it on
    /// one animation, not the bounce and the drop added together.
    @State private var carriedPull: CGFloat = 0
    @State private var isClosing = false
    @State private var selectedID: String?
    @State private var scrolledID: String?
    /// Kept as plain state, not `@StateObject`: the carousel must not observe it, or
    /// every frame of a pull re-renders every card (measured at 100–230 card bodies
    /// a second). Only the dim and the cards beside the pulled one observe it.
    @State private var pull = PublicLibraryCardPull()

    init(selection: PublicLibraryBookSelection, coverFrames: PublicLibraryCoverFrames,
         push: @escaping (PublicLibraryCarouselPush) -> Void, onClosed: @escaping () -> Void) {
        self.selection = selection
        self.coverFrames = coverFrames
        self.push = push
        self.onClosed = onClosed
        _selectedID = State(initialValue: selection.selectedID)
    }

    var body: some View {
        // Read inside the safe area for its insets; everything is drawn across the screen.
        GeometryReader { proxy in
            let layout = PublicLibraryCarouselLayout(proxy: proxy)
            ZStack(alignment: .topLeading) {
                PublicLibraryCarouselDim(pull: pull, carried: carriedPull, level: dimLevel, height: layout.size.height)
                carousel(layout)
                    .frame(width: layout.size.width, height: layout.size.height)
                    .opacity(isOpaque ? 1 : 0)
            }
            .frame(width: layout.size.width, height: layout.size.height)
            .ignoresSafeArea()
        }
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { close() }
        .onAppear {
            withAnimation(reduceMotion ? DSAnimation.standard : DSAnimation.cardCarouselOpen) { phase = .presented }
            withAnimation(reduceMotion ? DSAnimation.standard : DSAnimation.cardCarouselFadeIn) { isOpaque = true }
        }
    }

    private func carousel(_ layout: PublicLibraryCarouselLayout) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: layout.spacing) {
                ForEach(Array(selection.books.enumerated()), id: \.element.id) { index, book in
                    PublicLibraryExpandingCard(
                        margin: layout.margin, isSelected: selectedID == book.id, pull: pull,
                        close: { close() }, closeFromPull: { close(fromPull: $0, velocity: $1, layout: layout) }, onScrolledChange: { scrolled in
                            if scrolled { scrolledID = book.id }
                            else if scrolledID == book.id { scrolledID = nil }
                        }
                    ) {
                        PublicLibraryDetailPage(book: book, isSelected: selectedID == book.id)
                    }
                    .environment(\.bookDetailEmbedding, BookDetailEmbedding(
                        contentWidth: layout.cardWidth,
                        tone: BookDetailCardTone(GeneratedCoverPalette.tone(seed: book.title, colorScheme: colorScheme))))
                    .accessibilityHidden(selectedID != book.id)
                    .frame(width: layout.cardWidth)
                    // The cards beside the one being pulled down follow it: the row moves as one.
                    .modifier(PublicLibraryPullFollow(pull: pull, mode: pullMode(selected: selectedID == book.id)))
                    .modifier(transform(layout, index: index, book: book))
                    // The widened card grows past its slot; it has to draw over its neighbours.
                    .zIndex(selectedID == book.id ? 1000 : 1)
                    .id(book.id)
                }
            }.scrollTargetLayout()
        }
        .safeAreaPadding(.horizontal, layout.margin)
        .safeAreaPadding(.top, layout.cardTop)
        .safeAreaPadding(.bottom, layout.bottomInset)
        .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
        // Equal-width pages let the native initial anchor place the
        // chosen book before the lazy carousel has laid out its children.
        .defaultScrollAnchor(initialAnchor)
        .scrollPosition(id: $selectedID, anchor: .center)
        .scrollDisabled(scrolledID != nil)
        .scrollIndicators(.hidden)
        .environment(\.publicLibrarySheet, PublicLibrarySheetContext(
            artworkHeight: DSLayout.cardCarouselCoverHeight,
            openReader: { id in push(.reader(id)) },
            openAuthor: { author in push(.author(author)) }))
        .accessibilityIdentifier("publicLibrary.carousel")
    }

    private var initialAnchor: UnitPoint {
        let index = selection.books.prefix { $0.id != selection.selectedID }.count
        return UnitPoint(x: CGFloat(index) / CGFloat(max(selection.books.count - 1, 1)), y: 0)
    }

    private var dimLevel: Double {
        switch phase {
        case .cover, .closed: 0
        case .presented: 1
        // Apple Books' store is a fifth dimmed when the card reaches the cover's height.
        case .dropped: 0.2
        }
    }

    private func pullMode(selected: Bool) -> PublicLibraryPullFollow.Mode {
        if isClosing { return selected ? .cancel : .ignore }
        return selected ? .ignore : .follow
    }

    private var selectedIndex: Int {
        let id = selectedID ?? selection.selectedID
        return selection.books.firstIndex { $0.id == id } ?? 0
    }

    /// The card at `index`'s top-leading corner once presented, in the screen's space:
    /// the selected card at the margin, the others a card's width and spacing apart.
    private func restingOrigin(_ layout: PublicLibraryCarouselLayout, index: Int) -> CGPoint {
        CGPoint(x: layout.margin + CGFloat(index - selectedIndex) * (layout.cardWidth + layout.spacing), y: layout.cardTop)
    }

    /// Where the card at `index` comes out of and goes back into: its own cover on the
    /// shelf the book was opened from. A card whose cover is not on screen sits beside
    /// the selected one's at the cover's scale. With no cover on screen at all — a
    /// search result row — the row rises from below the screen instead.
    private func coverRect(_ layout: PublicLibraryCarouselLayout, index: Int, id: String) -> CGRect {
        let local = { (frame: CGRect) in frame.offsetBy(dx: -layout.origin.x, dy: -layout.origin.y) }
        if let frame = coverFrames.frame(for: id) { return local(frame) }
        let selectedID = selection.books[selectedIndex].id
        let anchor = coverFrames.frame(for: selectedID).map(local)
            ?? CGRect(x: layout.margin, y: layout.size.height, width: layout.cardWidth, height: layout.size.height)
        let scale = anchor.width / layout.cardWidth
        return CGRect(x: anchor.minX + CGFloat(index - selectedIndex) * (layout.cardWidth + layout.spacing) * scale,
                      y: anchor.minY, width: anchor.width, height: anchor.height)
    }

    private func transform(_ layout: PublicLibraryCarouselLayout, index: Int, book: PublicLibraryBook) -> PublicLibraryCarouselTransform {
        let id = book.id
        var transform = PublicLibraryCarouselTransform(book: book, cardWidth: layout.cardWidth)
        transform.visibleHeight = layout.size.height
        transform.cornerRadius = DSRadius.carouselCard
        switch phase {
        case .presented:
            transform.offset = CGSize(width: 0, height: carriedPull)
            return transform
        case .dropped:
            // The whole row drops together to the selected cover's height.
            let cover = coverRect(layout, index: selectedIndex, id: selection.books[selectedIndex].id)
            transform.offset = CGSize(width: 0, height: max(cover.minY - layout.cardTop, 0))
            return transform
        case .cover, .closed:
            if reduceMotion { return transform }
            let cover = coverRect(layout, index: index, id: id)
            let origin = restingOrigin(layout, index: index)
            // Scaled about the card's own top-leading corner, which then lands on the
            // cover's; masked to the cover's shape, as Apple Books' card turns into its
            // cover — at the card's width alone it ran past the cover onto the titles.
            let scale = cover.width / layout.cardWidth
            transform.scale = scale
            transform.offset = CGSize(width: cover.minX - origin.x, height: cover.minY - origin.y)
            transform.visibleHeight = cover.height / scale
            transform.cornerRadius = DSRadius.searchListCover / scale
            // By the time it sits on the cover the card shows the cover itself, so what
            // is left when it fades is exactly what is under it — nothing flashes.
            transform.coverOpacity = 1
            return transform
        }
    }

    /// - Parameter pull: how far the card was pulled down when let go, or 0 for the
    ///   close button. The row takes over that distance at once, so it drops from
    ///   where the finger left it.
    /// Let go of a pull far or fast enough to close: every card goes straight from
    /// where it was let go into its own cover, on one spring that starts at the
    /// finger's speed — no stop at the cover's height on the way, which read as the
    /// card running past the cover and coming back.
    private func close(fromPull pull: CGFloat, velocity: CGFloat, layout: PublicLibraryCarouselLayout) {
        guard phase == .presented, !isClosing else { return }
        handOver(pull)
        if reduceMotion {
            withAnimation(DSAnimation.standard, completionCriteria: .removed) {
                phase = .closed
                isOpaque = false
            } completion: { onClosed() }
            return
        }
        let selected = selection.books[selectedIndex]
        let remaining = coverRect(layout, index: selectedIndex, id: selected.id).minY
            - restingOrigin(layout, index: selectedIndex).y - pull
        // A spring's initial velocity is in units of the whole change per second.
        let initialVelocity = remaining > 1 ? Double(velocity / remaining) : 0
        // Fades as it arrives, not after the spring's last fraction of a point settles.
        withAnimation(.interpolatingSpring(DSAnimation.cardCarouselReturn, initialVelocity: initialVelocity),
                      completionCriteria: .logicallyComplete) {
            phase = .closed
        } completion: {
            withAnimation(DSAnimation.cardCarouselFadeOut, completionCriteria: .removed) {
                isOpaque = false
            } completion: {
                onClosed()
            }
        }
    }

    /// The row takes over how far the selected card was pulled, at once, so whatever
    /// runs next starts where the finger left it.
    private func handOver(_ pull: CGFloat) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            carriedPull = pull
            isClosing = true
        }
    }

    /// The close button: Apple Books' measured close — the row drops to the cover's
    /// height, then shrinks into the covers.
    private func close() {
        guard phase == .presented, !isClosing else { return }
        handOver(0)
        if reduceMotion {
            withAnimation(DSAnimation.standard, completionCriteria: .removed) {
                phase = .closed
                isOpaque = false
            } completion: { onClosed() }
            return
        }
        withAnimation(DSAnimation.cardCarouselDrop, completionCriteria: .removed) {
            phase = .dropped
        } completion: {
            withAnimation(DSAnimation.cardCarouselCollapse, completionCriteria: .removed) {
                phase = .closed
                isOpaque = false
            } completion: {
                onClosed()
            }
        }
    }
}

/// The carousel across the whole screen, measured off Apple Books' store card: 16pt
/// margins, cards 4pt apart (the next one peeks 12pt), a resting card's top 13pt
/// below the status bar.
private struct PublicLibraryCarouselLayout {
    /// The whole screen.
    let size: CGSize
    /// The screen's top-leading corner, in global (window) coordinates.
    let origin: CGPoint
    let margin = DSSpacing.lg
    let spacing = DSSpacing.xs
    /// Where a resting card's top sits.
    let cardTop: CGFloat
    /// The tab bar and home indicator: the card's content scrolls clear of them.
    let bottomInset: CGFloat
    var cardWidth: CGFloat { size.width - margin * 2 }

    init(proxy: GeometryProxy) {
        let insets = proxy.safeAreaInsets
        size = CGSize(width: proxy.size.width + insets.leading + insets.trailing,
                      height: proxy.size.height + insets.top + insets.bottom)
        let frame = proxy.frame(in: .global)
        origin = CGPoint(x: frame.minX - insets.leading, y: frame.minY - insets.top)
        cardTop = insets.top + DSLayout.cardCarouselTopGap
        bottomInset = insets.bottom
    }
}

private struct PublicLibraryCarouselTransform: ViewModifier {
    let book: PublicLibraryBook
    let cardWidth: CGFloat
    var scale: CGFloat = 1
    var offset: CGSize = .zero
    /// How much of the card shows, from its top, before scaling.
    var visibleHeight: CGFloat = .greatestFiniteMagnitude
    var cornerRadius: CGFloat = 0
    /// The book's cover laid over the card: 0 while it is a card, 1 once it has
    /// turned back into the cover on the shelf.
    var coverOpacity: Double = 0

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                // The shelf's own cover artwork at the card's width; scaled with the
                // card it lands exactly on the shelf's cover.
                GeneratedBookCover(title: book.title, author: book.author)
                    .frame(width: cardWidth, height: cardWidth / DSLayout.discoverCoverAspectRatio)
                    .opacity(coverOpacity)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .mask(alignment: .top) {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .frame(height: min(visibleHeight, 10_000))
            }
            .scaleEffect(scale, anchor: .topLeading)
            .offset(offset)
    }
}

/// How far the selected card is pulled down past its resting place. Only the dim
/// reads it, so the pull does not re-render the carousel.
final class PublicLibraryCardPull: ObservableObject {
    @Published var distance: CGFloat = 0
}

/// The selected card is pulled by its own scroll view; the cards beside it follow that
/// pull so the row moves as one. Once a pull closes the carousel the row carries the
/// distance itself, and the selected card cancels its scroll view's bounce back.
private struct PublicLibraryPullFollow: ViewModifier {
    enum Mode { case follow, cancel, ignore }

    @ObservedObject var pull: PublicLibraryCardPull
    let mode: Mode

    func body(content: Content) -> some View {
        switch mode {
        case .follow: content.offset(y: pull.distance)
        case .cancel: content.offset(y: -pull.distance)
        case .ignore: content
        }
    }
}

private struct PublicLibraryCarouselDim: View {
    @ObservedObject var pull: PublicLibraryCardPull
    let carried: CGFloat
    let level: Double
    let height: CGFloat

    var body: some View {
        DSColor.cardCarouselDim
            .opacity(DSLayout.cardCarouselDimOpacity * level * max(0, 1 - (carried > 0 ? carried : pull.distance) / max(height, 1)))
            .contentShape(Rectangle())
            .accessibilityHidden(true)
    }
}

/// One book in the carousel: a vertical scroll view whose content rests as a card, its
/// top `inset` below the top of the screen (status bar plus margin). Scrolling that
/// inset away widens the card by its margins — a negative horizontal padding growing
/// with the scroll — so by the time its top reaches the top of the screen it fills the
/// width. `CardRestingTarget` keeps a release inside the inset from leaving the card
/// half expanded.
private struct PublicLibraryExpandingCard<Content: View>: View {
    let margin: CGFloat
    let isSelected: Bool
    let pull: PublicLibraryCardPull
    let close: () -> Void
    /// Closes from a pull let go at the given distance and downward speed.
    let closeFromPull: (_ distance: CGFloat, _ velocity: CGFloat) -> Void
    let onScrolledChange: (Bool) -> Void
    @ViewBuilder var content: Content

    /// The card's scroll — top inset (status bar plus margin) and how far it has scrolled up
    /// from rest, negative while pulled down — shared with the header through the environment.
    @State private var chrome = BookDetailCardChrome()
    /// The scroll view's height inside its insets. The content is at least this plus
    /// the top inset tall, so the card can always scroll its whole inset away and stay
    /// expanded, however short the page.
    @State private var height: CGFloat = 0

    private static var space: String { "publicLibrary.card" }

    private var offset: CGFloat { chrome.offset }
    private var inset: CGFloat { chrome.inset }
    private var progress: CGFloat { chrome.progress }

    var body: some View {
        ScrollView(.vertical) {
            content
                .environment(\.bookDetailCardChrome, chrome)
                .frame(minHeight: height + inset, alignment: .top)
                // Clipped to the card's rounded top before it widens: clipping after the
                // negative padding cut the widened card back to its resting width.
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: DSRadius.carouselCard, topTrailingRadius: DSRadius.carouselCard))
                .padding(.horizontal, -margin * progress)
                // The content's top in the scroll view's own space sits at 0 at rest.
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.frame(in: .named(Self.space)).minY
                } action: { chrome.offset = -$0 }
                .background { ScrollPanReleaseObserver(onRelease: released) }
        }
        .coordinateSpace(.named(Self.space))
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { chrome.inset = $0 }
        .onChange(of: margin, initial: true) { _, margin in chrome.margin = margin }
        .onAppear { chrome.close = close }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        // The widened card has to draw past the scroll view's own frame.
        .scrollClipDisabled()
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(CardRestingTarget(inset: inset))
        .background {
            UnevenRoundedRectangle(topLeadingRadius: DSRadius.carouselCard, topTrailingRadius: DSRadius.carouselCard)
                .fill(DSColor.background)
                .ignoresSafeArea(.all, edges: .bottom)
                // Follows the card down while it is pulled past its resting place, and
                // reaches up to the top of the screen as the card expands.
                .offset(y: offset > 0 ? 0 : -offset)
                .padding(.top, -inset * progress)
                .padding(.horizontal, -margin * progress)
        }
        .onChange(of: offset > 0) { _, scrolled in onScrolledChange(scrolled) }
        .onChange(of: offset) { _, value in
            guard isSelected else { return }
            let distance = max(-value, 0)
            if pull.distance != distance { pull.distance = distance }
        }
    }

    private func released(pulledBy distance: CGFloat, velocity: CGFloat) {
        guard isSelected, distance > 0,
              distance > DSLayout.cardCarouselDismissPull || velocity > DSLayout.cardCarouselDismissVelocity
        else { return }
        closeFromPull(distance, max(velocity, 0))
    }
}

/// A release that would come to rest inside the card's top inset returns to the
/// resting card instead; past the inset the scroll ends where it ends.
private struct CardRestingTarget: ScrollTargetBehavior {
    let inset: CGFloat

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        if target.rect.minY < inset {
            target.rect.origin = .zero
        }
    }
}

/// Tells when a drag that began with the content at rest (not scrolled up) lets go,
/// with how far the content is pulled past the top and the downward speed. A drag
/// that began on an expanded card and ran past the top is a scroll back, not a pull.
/// SwiftUI reports a scroll view's phase
/// only from iOS 18, so this listens to the scroll view's own pan recognizer — as an
/// added target, so it never competes with the scroll.
private struct ScrollPanReleaseObserver: UIViewRepresentable {
    let onRelease: (_ pulledBy: CGFloat, _ velocity: CGFloat) -> Void

    func makeUIView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.isUserInteractionEnabled = false
        view.onRelease = onRelease
        return view
    }

    func updateUIView(_ uiView: ObserverView, context: Context) {
        uiView.onRelease = onRelease
    }

    final class ObserverView: UIView {
        var onRelease: ((CGFloat, CGFloat) -> Void)?
        private weak var scrollView: UIScrollView?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            scrollView?.panGestureRecognizer.removeTarget(self, action: #selector(panned(_:)))
            var ancestor = superview
            while let view = ancestor, !(view is UIScrollView) { ancestor = view.superview }
            scrollView = ancestor as? UIScrollView
            scrollView?.panGestureRecognizer.addTarget(self, action: #selector(panned(_:)))
        }

        private var beganAtRest = false

        @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
            guard let scrollView else { return }
            let pulled = -(scrollView.contentOffset.y + scrollView.adjustedContentInset.top)
            switch recognizer.state {
            case .began: beganAtRest = pulled >= 0
            case .ended where beganAtRest: onRelease?(pulled, recognizer.velocity(in: scrollView).y)
            default: break
            }
        }
    }
}

private struct PublicLibraryDetailPage: View {
    let book: PublicLibraryBook
    let isSelected: Bool

    var body: some View {
        switch book {
        case .gutenberg(let book): GutenbergBookDetailPage(book: book, isSelected: isSelected)
        case .aozora(let work, let index):
            AozoraWorkDetailView(work: work, index: index)
        }
    }
}

private struct GutenbergBookDetailPage: View {
    let book: GutenbergBook
    let isSelected: Bool
    @StateObject private var model: GutenbergBookPageModel
    @Environment(\.publicLibrarySheet) private var sheet

    init(book: GutenbergBook, isSelected: Bool) {
        self.book = book
        self.isSelected = isSelected
        _model = StateObject(wrappedValue: GutenbergBookPageModel(book: book))
    }

    var body: some View {
        Group {
            if let detail = model.detail, isSelected {
                RemoteLibraryBookDetailView(item: detail.item, storefront: true, authors: detail.authors,
                                            artworkTitle: book.title, artworkAuthor: book.author)
            } else {
                // The same card top the loaded page shows, so the card does not change
                // shape when the catalog entry arrives.
                BookDetailScaffold(title: book.title, compactAction: loadingAction) {
                    BookDetailHero(artworkShape: .book, cover: GeneratedBookCover(title: book.title, author: book.author),
                        title: book.title, author: book.author, meta: localized("Project Gutenberg"),
                        primary: loadingAction,
                        secondary: BookDetailAction(title: localized("下載"), systemImage: "arrow.down.circle",
                                                    isEnabled: false, action: {}),
                        artworkHeight: sheet?.artworkHeight)
                } content: {
                    VStack(spacing: DSSpacing.lg) {
                        if model.isLoading { ProgressView(localized("正在載入書庫")) }
                        if let error = model.errorMessage, isSelected {
                            Text(error).foregroundStyle(DSColor.textSecondary)
                            Button(localized("重試")) { Task { await model.load(force: true) } }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .task(id: isSelected) { if isSelected { await model.load() } }
    }

    private var loadingAction: BookDetailAction {
        BookDetailAction(title: localized("開始閱讀"), systemImage: "book",
                         isBusy: model.isLoading, isEnabled: false, action: {})
    }
}

#Preview("書籍卡片輪播") {
    PublicLibraryBookSheet(selection: PublicLibraryBookSelection(
        books: PublicLibraryCollection.chinese.books.map(PublicLibraryBook.gutenberg),
        selectedID: PublicLibraryBook.gutenberg(PublicLibraryCollection.chinese.books[0]).id)!,
        coverFrames: PublicLibraryCoverFrames(), push: { _ in }, onClosed: {})
        .environmentObject(BookStore())
}
