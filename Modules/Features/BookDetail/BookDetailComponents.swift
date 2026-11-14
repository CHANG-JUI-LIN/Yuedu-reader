import SwiftUI

// MARK: - Book detail building blocks
//
// The detail pages are laid out as Apple Books' store lays out a book (maintainer,
// 2026-11-12): the artwork, large, on a block of its own colour with the title and author
// under it and a panel that names the source and holds the two actions; then, on the page's
// own ground, the description, the chapter list, what the work is related to and its
// information, each under a bold title, in grey text, with a hairline between sections and
// none between rows, and no accent colour. Every detail page composes these pieces; none
// draws its own copy.

/// One action button on a detail page.
struct BookDetailAction {
    var title: String
    var systemImage: String
    var isBusy = false
    var isEnabled = true
    /// Dims the hero's second button as its unavailable 開始閱讀 is dimmed: 加入書架 on a
    /// work with no source to read. Not for a disabled button that states a fact (已在書架).
    var dimsWhenUnavailable = false
    /// Where reading resumes, in grey after the title: 「第 12 章」 or 「已讀 32%」
    /// (`BookDetailResume`). Read by VoiceOver as the button's value.
    var detail: String? = nil
    /// 移除書架's question, asked from this button so on iOS 26+ its popover points at it:
    /// `action` presents it, and confirming removes the book.
    var removalConfirmation: BookDetailRemovalConfirmation? = nil
    var action: () -> Void
}

struct BookDetailRemovalConfirmation {
    var isPresented: Binding<Bool>
    var onConfirm: () -> Void
}

extension View {
    @ViewBuilder
    fileprivate func removalConfirmation(_ confirmation: BookDetailRemovalConfirmation?) -> some View {
        if let confirmation {
            removeFromShelfConfirmation(isPresented: confirmation.isPresented, onConfirm: confirmation.onConfirm)
        } else {
            self
        }
    }
}

struct BookDetailAuthorAction: Identifiable {
    let id: String
    let name: String
    let action: () -> Void
}

/// A genre, series or subject under the title, as plain text that leads somewhere: the
/// way Apple Books' editorial pages link, not a row of coloured tags.
/// The work in its other form, on the hero under the actions as Apple Books' store has 檢視有聲書
/// (maintainer, 2026-11-14: 「文字和有聲書互相顯示」): a book's audiobook, an audiobook's book, as
/// one source has it. 作品詳情 finds it and puts it in the environment for whichever page shows
/// the work, its own or a book source's; that page opens it (`BookDetailHero.openOtherForm`),
/// through its own one destination. The card was first given an action of 作品詳情's own, which
/// did nothing on a book source's page: 作品詳情's destination is its own page's, not there
/// while a source's page is shown (maintainer's phone, 2026-11-14: 「我怎麼點不過去」).
struct BookDetailOtherForm: Equatable {
    /// The titles the work's pages write. A hero shows the card only under one of them, so a
    /// page pushed from the work's, which inherits its environment, never shows another work's.
    let titles: Set<String>
    /// 「檢視有聲書」 or 「檢視書籍」.
    let title: String
    let cover: HomeCardContent.Cover
    let isSquare: Bool
    /// Who it is by, as its source says (an audiobook's is often its reader), then the source.
    let lines: [String]
    /// The book itself, for the page that shows the card to open.
    let work: WorkDetailRoute

    /// The cover aside, which the book names.
    static func == (lhs: BookDetailOtherForm, rhs: BookDetailOtherForm) -> Bool {
        lhs.titles == rhs.titles && lhs.title == rhs.title && lhs.isSquare == rhs.isSquare && lhs.lines == rhs.lines
            && lhs.work == rhs.work
    }
}

struct BookDetailLink: Identifiable {
    let id: String
    let title: String
    let action: () -> Void
    /// What VoiceOver says the link does; a genre's by default.
    var hint: String? = nil
}

// MARK: - Page scaffold

/// Set by a container that scrolls the detail page itself — the public-library card
/// carousel, where each card's own vertical scroll view is also its expansion gesture.
/// The scaffold then lays its content out without a scroll view of its own, at a
/// fixed width so nothing rewraps while the card widens around it, and puts its
/// buttons in the card's own header instead of the navigation bar.
struct BookDetailEmbedding {
    /// Width the hero's text and the sections keep, however wide the card grows.
    let contentWidth: CGFloat
    /// The book's cover colours. The card's top — header and hero — is painted in
    /// them as Apple Books paints its store card in the cover's colour.
    let tone: BookDetailCardTone
}

/// Colours of a carousel card's top, taken from the book's generated cover.
struct BookDetailCardTone {
    let top: Color
    let bottom: Color
    /// Text and icons on the top; guaranteed to read against it.
    let ink: Color
    /// The cover's frame line: the tint of the header's glass.
    let line: Color

    init(_ tone: GeneratedCoverTone) {
        top = Color(uiColor: tone.top)
        bottom = Color(uiColor: tone.bottom)
        ink = Color(uiColor: tone.ink)
        line = Color(uiColor: tone.line)
    }
}

private struct BookDetailEmbeddingKey: EnvironmentKey {
    static let defaultValue: BookDetailEmbedding? = nil
}

/// Scroll state of the card around an embedded page, for its header: how far the card
/// has scrolled up from rest, the scroll view's top inset (the card's resting
/// distance from the top of the screen) and the margin the card widens across.
///
/// One object per card, put in the environment once. It used to be a struct rebuilt on
/// every frame of the card's scroll — a new `offset`, and a closure that never compares
/// equal — so every frame changed the environment of the whole detail page under it. Now
/// only the views that read `offset` (the card, its header) follow the scroll.
@MainActor
@Observable
final class BookDetailCardChrome {
    var offset: CGFloat = 0
    var inset: CGFloat = 0
    var margin: CGFloat = 0
    @ObservationIgnored var close: () -> Void = {}

    /// 0 at rest, 1 once the card's top has reached the top of the screen.
    var progress: CGFloat { inset > 0 ? min(max(offset / inset, 0), 1) : 0 }
}

private struct BookDetailCardChromeKey: EnvironmentKey {
    static let defaultValue: BookDetailCardChrome? = nil
}

extension EnvironmentValues {
    var bookDetailEmbedding: BookDetailEmbedding? {
        get { self[BookDetailEmbeddingKey.self] }
        set { self[BookDetailEmbeddingKey.self] = newValue }
    }

    var bookDetailCardChrome: BookDetailCardChrome? {
        get { self[BookDetailCardChromeKey.self] }
        set { self[BookDetailCardChromeKey.self] = newValue }
    }

    /// How far the status bar and the navigation bar reach down over a hero laid from the
    /// top edge of the screen (`BookDetailScaffold.heroUnderBars`); 0 for every other hero.
    @Entry var bookDetailHeroBarInset: CGFloat = 0
    /// The work in its other form, for the hero of the page that shows the work (`BookDetailOtherForm`).
    @Entry var bookDetailOtherForm: BookDetailOtherForm? = nil
}

/// Scroll container, background and navigation chrome shared by the detail pages.
///
/// When the hero's actions scroll under the navigation bar, the book's title fades
/// into the bar and the primary action follows it as a compact button — the App
/// Store and Apple Books pattern — so the primary action is never more than one tap
/// away without a bar permanently covering the chapter list.
struct BookDetailScaffold<Hero: View, Content: View, Actions: View>: View {
    let title: String
    let compactAction: BookDetailAction
    var onRefresh: (() async -> Void)?
    var hero: Hero
    var content: Content
    /// Trailing buttons: in the navigation bar, or in the card's header when embedded.
    var actions: Actions
    /// Lays the hero from the top edge of the screen, under the status bar and the
    /// navigation bar, for a hero that is artwork (a video's poster, as plezy and Infuse
    /// show it). The hero keeps its text clear of the bars with `bookDetailHeroBarInset`.
    var heroUnderBars = false
    /// The whole page in one colour taken from its artwork, drawn dark with white text in
    /// light and dark mode alike, as Infuse and VidHub draw a series' page; nil for the
    /// app's page background.
    var pageTint: Color?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.bookDetailEmbedding) private var embedding
    /// Whether the hero has scrolled up under the navigation bar. Stored as the crossing
    /// itself: it used to be the hero's bottom edge, written on every frame of a scroll, and
    /// each write re-ran this scaffold and its toolbar though only the crossing is read.
    @State private var heroScrolledAway = false
    /// Top edge of the visible scroll area (below the navigation bar), in global coordinates.
    @State private var visibleTop: CGFloat = 0
    /// How far the status bar and the navigation bar reach down: the scroll view's top safe
    /// area, which a `heroUnderBars` page lays its hero into.
    @State private var barInset: CGFloat = 0

    init(title: String, compactAction: BookDetailAction, onRefresh: (() async -> Void)? = nil,
         heroUnderBars: Bool = false, pageTint: Color? = nil,
         @ViewBuilder hero: () -> Hero, @ViewBuilder content: () -> Content,
         @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.compactAction = compactAction
        self.onRefresh = onRefresh
        self.heroUnderBars = heroUnderBars
        self.pageTint = pageTint
        self.hero = hero()
        self.content = content()
        self.actions = actions()
    }

    var body: some View {
        if embedding != nil {
            stack.frame(maxWidth: .infinity)
        } else {
            ScrollView {
                stack
                    .environment(\.bookDetailHeroBarInset, heroUnderBars ? barInset : 0)
                    // Only the page: the sheets and dialogs it presents keep the app's appearance.
                    .environment(\.colorScheme, pageTint == nil ? colorScheme : .dark)
            }
                .ignoresSafeArea(.container, edges: heroUnderBars ? .top : [])
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.frame(in: .global).minY + proxy.safeAreaInsets.top
                } action: { visibleTop = $0 }
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.safeAreaInsets.top
                } action: { [heroUnderBars] inset in
                    if heroUnderBars { barInset = inset }
                }
                .modifier(BookDetailRefreshModifier(onRefresh: onRefresh))
                // iOS 26's soft top edge fades whatever scrolls under the navigation bar into
                // the page background — it turned the cover's colour under the bar into a flat
                // band. The cover shows through while it is on screen; once it has scrolled
                // away the edge effect returns to keep the bar's title and button legible.
                .softScrollEdges(hidingTop: !heroScrolledAway)
                .scrollIndicators(.hidden)
                .background {
                    if let pageTint {
                        pageTint.ignoresSafeArea()
                    } else {
                        // A white page, as Apple Books' store draws a book's (maintainer,
                        // 2026-11-14: 「也改成白底」, after 讀者評論's own page): the quiet grey
                        // cards read on it as they do there. A theme's own page colour and
                        // picture still paint it.
                        PageBackgroundView(scope: .global, base: DSColor.background).ignoresSafeArea()
                    }
                }
                .pageBackgroundToolbar(for: .global)
                // The bar's title and buttons over a tinted page are white too, and over the
                // hero's block of colour until it has scrolled away.
                .toolbarColorScheme(pageTint != nil || !heroScrolledAway ? .dark : nil, for: .navigationBar)
                .background { BarItemsOnBlock(isOnBlock: pageTint == nil && !heroScrolledAway) }
                .toolbarTitleDisplayMode(.inline)
                .hidesRootTabBar()
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Text(title)
                            .font(DSFont.headline)
                            .foregroundStyle(DSColor.textPrimary)
                            .lineLimit(1)
                            .opacity(heroScrolledAway ? 1 : 0)
                            .accessibilityHidden(!heroScrolledAway)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        if heroScrolledAway {
                            compactButton
                                .disabled(!compactAction.isEnabled || compactAction.isBusy)
                                .transition(.opacity)
                        }
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) { actions }
                }
                .animation(reduceMotion ? nil : DSAnimation.fast, value: heroScrolledAway)
        }
    }

    /// The hero's capsule, small: neutral, its words alone. From iOS 26 the bar already
    /// draws a glass capsule around each item, so the words go in it bare — a capsule of
    /// our own inside it read as one capsule in another (maintainer, 2026-10-12). Earlier
    /// bars draw no background, so there the button is its own grey capsule.
    @ViewBuilder
    private var compactButton: some View {
        let label = Text(compactAction.title)
            .font(DSFont.subheadline.weight(.semibold))
            .foregroundStyle(DSColor.textPrimary)
        if #available(iOS 26.0, *) {
            Button(action: compactAction.action) { label }
        } else {
            Button(action: compactAction.action) { label }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .tint(DSColor.textSecondary)
        }
    }

    private var stack: some View {
        VStack(spacing: DSSpacing.xl) {
            VStack(spacing: 0) {
                if embedding != nil {
                    BookDetailCardHeader(hasActions: Actions.self != EmptyView.self) { actions }
                        // Over the hero, whose block of colour runs up behind it.
                        .zIndex(1)
                }
                hero
                    // Only the navigation bar's title uses it; a card has no bar, and
                    // tracking it there re-rendered the page on every frame of a scroll.
                    .onGeometryChange(for: Bool.self) { [visibleTop, isCard = embedding != nil] proxy in
                        !isCard && proxy.frame(in: .global).maxY < visibleTop
                    } action: { heroScrolledAway = $0 }
            }
            content
                .frame(maxWidth: embedding?.contentWidth ?? .infinity)
        }
        .padding(.bottom, DSSpacing.xxl)
    }
}

extension BookDetailScaffold where Actions == EmptyView {
    init(title: String, compactAction: BookDetailAction, onRefresh: (() async -> Void)? = nil,
         heroUnderBars: Bool = false, pageTint: Color? = nil,
         @ViewBuilder hero: () -> Hero, @ViewBuilder content: () -> Content) {
        self.init(title: title, compactAction: compactAction, onRefresh: onRefresh,
                  heroUnderBars: heroUnderBars, pageTint: pageTint, hero: hero, content: content,
                  actions: { EmptyView() })
    }
}

// MARK: - Card header

/// The buttons at the top of a carousel card, in the manner of Apple Books' store
/// card: they ride with the card, then stay pinned below the status bar once it has
/// scrolled up. They are drawn as the navigation bar draws its own — glass capsules —
/// tinted with the card's colour.
struct BookDetailCardHeader<Actions: View>: View {
    let hasActions: Bool
    @ViewBuilder var actions: Actions
    @Environment(\.bookDetailCardChrome) private var chrome
    @Environment(\.bookDetailEmbedding) private var embedding

    var body: some View {
        if let chrome, let embedding {
            HStack(spacing: DSSpacing.md) {
                BookDetailCardButtonGroup(tone: embedding.tone) {
                    // Looked up on tap: the card sets `close` when it appears, after this
                    // header's first body.
                    Button { chrome.close() } label: {
                        BookDetailCardIcon(title: localized("關閉"), systemImage: "xmark")
                    }
                    .accessibilityIdentifier("publicLibrary.closeSheet")
                }
                Spacer()
                if hasActions {
                    BookDetailCardButtonGroup(tone: embedding.tone) { actions }
                }
            }
            .padding(.horizontal, DSSpacing.lg)
            .padding(.top, DSSpacing.lg)
            .frame(maxWidth: embedding.contentWidth)
            .padding(.horizontal, -chrome.margin * chrome.progress)
            // Rides with the card for the first stretch, then stays where it is.
            .offset(y: chrome.offset < DSLayout.cardHeaderPinDistance ? 0 : chrome.offset - DSLayout.cardHeaderPinDistance)
        }
    }
}

/// A navigation-bar-sized icon button label.
struct BookDetailCardIcon: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.iconOnly)
            .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
            .contentShape(Rectangle())
    }
}

/// Adjacent buttons on one glass capsule, as the navigation bar groups them.
private struct BookDetailCardButtonGroup<Buttons: View>: View {
    let tone: BookDetailCardTone
    @ViewBuilder var buttons: Buttons

    var body: some View {
        HStack(spacing: 0) { buttons }
            .buttonStyle(.plain)
            .font(DSFont.body.weight(.medium))
            .foregroundStyle(tone.ink)
            .modifier(CardButtonGlass(tint: tone.line))
    }
}

/// The bar's glass capsule on iOS 26 behind a group of buttons, tinted with a card's colour
/// or clear over a page (a video's 加入書架 / 選集 / 換源); older systems have no glass, so
/// the tint lies over `.regularMaterial`. The `#if compiler` guard mirrors
/// `FrostedGlassBackground`.
struct CardButtonGlass: ViewModifier {
    var tint: Color?

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.glassEffect(glass, in: Capsule())
        } else {
            legacy(content)
        }
        #else
        legacy(content)
        #endif
    }

    #if compiler(>=6.2)
    @available(iOS 26.0, *)
    private var glass: Glass {
        guard let tint else { return .regular.interactive() }
        return .regular.tint(tint.opacity(DSLayout.cardHeaderGlassTintOpacity)).interactive()
    }
    #endif

    private func legacy(_ content: Content) -> some View {
        content
            .background(tint?.opacity(DSLayout.cardHeaderGlassTintOpacity) ?? .clear, in: Capsule())
            .background(.regularMaterial, in: Capsule())
    }
}

/// The bar's back button and items in white while the bar is over the hero's block of colour.
/// Before iOS 26 they keep the app's tint, which does not read on a block of any colour (system
/// blue on a dark olive block is under 3:1; seen on the iOS 18.6 simulator, 2026-11-12), and
/// SwiftUI has no modifier that reaches the back button of a pushed page. From iOS 26 each item
/// sits on its own glass, which takes the colour under it, and this does nothing.
///
/// It sets the navigation bar's own tint while the page shows and the hero has not scrolled
/// away, and clears it again (nil inherits the app's tint, as before) when either ends.
private struct BarItemsOnBlock: UIViewControllerRepresentable {
    let isOnBlock: Bool

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.isOnBlock = isOnBlock
    }

    final class Controller: UIViewController {
        var isOnBlock = false {
            didSet { if isOnBlock != oldValue { apply() } }
        }
        private var isShown = false

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            isShown = true
            apply()
        }

        /// Again once it is in the stack: SwiftUI can show the page before this controller has
        /// a parent, and `navigationController` is nil until then (iOS 18.6 simulator).
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            isShown = true
            apply()
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            apply()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            isShown = false
            apply()
        }

        private func apply() {
            if #available(iOS 26.0, *) { return }
            navigationController?.navigationBar.tintColor = isShown && isOnBlock ? UIColor(DSColor.textOnFixedFill) : nil
        }
    }
}

private struct BookDetailRefreshModifier: ViewModifier {
    let onRefresh: (() async -> Void)?

    func body(content: Content) -> some View {
        if let onRefresh {
            content.refreshable { await onRefresh() }
        } else {
            content
        }
    }
}

// MARK: - Hero

/// Artwork, title, author and the two actions at the top of a detail page.
/// The detail page's book name, author and labels, when the book's source takes their taps
/// (`SourceCallBackService`: clickBookName, longClickBookName, clickAuthor, longClickAuthor,
/// clickBookLabel, longClickBookLabel).
struct BookDetailSourceGestures {
    var labels: [String]
    var tapName: () -> Void
    var longPressName: () -> Void
    var tapAuthor: () -> Void
    var longPressAuthor: () -> Void
    var tapLabel: (String) -> Void
    var longPressLabel: (String) -> Void
}

private extension View {
    /// A tap and a long press on a piece of text, with the long press reachable from
    /// VoiceOver as a named action (a tap is the element's own activation).
    @ViewBuilder
    func sourceGesture(
        tap: (() -> Void)?, longPress: (() -> Void)?, longPressName: String
    ) -> some View {
        if let tap, let longPress {
            self
                .contentShape(Rectangle())
                .onTapGesture(perform: tap)
                .onLongPressGesture(perform: longPress)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(.default, tap)
                .accessibilityAction(named: Text(longPressName), longPress)
        } else {
            self
        }
    }
}

/// Where the page reads the book from, on the hero's panel: the source's name, which switches
/// it where the work has another, and what is known of this copy.
struct BookDetailHeroSource {
    var name: String
    /// The work's versions, picked in place from the name's menu (作品詳情).
    var choice: BookDetailInfoChoice?
    /// 換源's sheet, opened from the name (a book source's page). Never an item of `choice`'s
    /// menu: iOS 17 drops a sheet presented while a menu dismisses.
    var switchAction: (() -> Void)?
    /// How the page's search for sources stands, beside the name and read after it:
    /// 「搜尋來源配置中…」, 「找到 2 個來源」.
    var status: String?
    /// How many sources the work has, beside the name when the search has nothing to say:
    /// 「共 3 個來源」. Not read: the name's menu lists them.
    var count: Int?
    /// What the status does where no menu holds it: 重試, 繼續搜索.
    var followUp: (title: String, action: () -> Void)?
    /// What is known of the copy, one line: 線上, 1,432 章, EPUB, 2.1 MB.
    var facts: [String] = []

    var isSwitchable: Bool { choice != nil || switchAction != nil }
}

/// The top of a detail page (maintainer, 2026-11-12, after Apple Books' store page): the
/// artwork, large, on a block of its own colour that runs up under the bars; the title, the
/// author and one line of genres in light text on it; then a panel that names the source the
/// page reads from and holds the two actions, the shelf's and reading, side by side and as
/// tall as each other.
///
/// The block's colour is the cover's, darkened until the text reads on it
/// (`CoverTint.blockGround`), in light and dark mode, under a theme's page picture, with
/// Reduce Transparency and with Increase Contrast, where it is darkened further. A carousel
/// card keeps its generated cover's own colours and ink (`BookDetailEmbedding.tone`).
struct BookDetailHero<Cover: View>: View {
    enum ArtworkShape {
        /// A book jacket, 2:3 like the shelf grid.
        case book
        /// Square audiobook artwork, as Podcasts shows a show.
        case square
    }

    let artworkShape: ArtworkShape
    let cover: Cover
    let title: String
    let author: String
    let meta: String
    let primary: BookDetailAction
    /// None when the page has no second thing to do (作品詳情 of a book-source result).
    let secondary: BookDetailAction?
    var authorActions: [BookDetailAuthorAction] = []
    var artworkHeight: CGFloat? = nil
    /// Taps a book source handles through its `callBackJs` (legado `SourceCallBack`); nil
    /// for every book whose source does not listen, which keeps the title block as it was.
    var sourceGestures: BookDetailSourceGestures? = nil
    /// Genres under the title that lead somewhere; replaces `meta` when present. A source
    /// that listens for label taps (`sourceGestures`) keeps them instead.
    var links: [BookDetailLink] = []
    /// The series' other volumes, fanned behind the cover (`SeriesCoverFan`); nil for a book
    /// alone. Drawn behind the artwork's frame, so the hero's size never changes with it.
    var seriesFan: SeriesFan? = nil
    /// Draws `primary` as the second action is drawn, quiet on the block with its icon, and
    /// alone: the series page's one button, which leads to a volume and reads nothing itself
    /// (Apple Books' 「免費試讀第 1 冊」).
    var quietPrimary = false
    /// Opens the work in its other form (`BookDetailOtherForm`, 檢視有聲書) through the page's own
    /// destination; the card is drawn only where the page can.
    var openOtherForm: ((WorkDetailRoute) -> Void)? = nil
    /// The source the page reads from, on the panel over the actions; nil where the page has
    /// one place only and nothing to say of it.
    var source: BookDetailHeroSource? = nil

    @Environment(\.bookDetailEmbedding) private var embedding
    @Environment(\.bookDetailOtherForm) private var otherForm
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The average colour of the cover on screen, as its view reports it; nil until then.
    @State private var coverColor: CoverTint.RGB?

    private var artworkSize: CGSize {
        switch artworkShape {
        case .book:
            CGSize(width: artworkHeight.map { $0 * DSLayout.discoverCoverAspectRatio } ?? DSLayout.bookDetailCoverWidth,
                   height: artworkHeight ?? DSLayout.bookDetailCoverHeight)
        case .square:
            CGSize(width: DSLayout.bookDetailSquareArtworkSide, height: DSLayout.bookDetailSquareArtworkSide)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            artwork
            titleBlock
                .padding(.top, isCard ? DSLayout.cardCarouselCoverTitleSpacing : DSSpacing.xl)
            panel
                .padding(.top, DSSpacing.lg)
            if let otherForm, let openOtherForm, otherForm.titles.contains(title) {
                otherFormCard(otherForm, open: openOtherForm)
                    .padding(.top, DSSpacing.md)
            }
        }
        .padding(.horizontal, DSSpacing.lg)
        // On a card the cover sits where Apple Books puts it, under the card's header.
        .padding(.top, isCard ? DSLayout.cardCarouselCoverTop - DSSpacing.lg - DSLayout.minimumTapTarget : DSSpacing.sm)
        .padding(.bottom, isCard ? DSLayout.cardCarouselTopBottomPadding : DSSpacing.xl)
        // In a widening card the text keeps its width; only the block grows with it.
        .frame(maxWidth: embedding?.contentWidth ?? .infinity)
        .frame(maxWidth: .infinity)
        .background(alignment: .top) { block }
        .animation(reduceMotion ? nil : DSAnimation.standard, value: coverColor)
    }

    /// The block of colour behind the hero. It runs up past the hero's own top edge, under the
    /// navigation and status bars (a card clips it to its rounded top), and stays inside the
    /// safe area at the sides: a colour's own `.background` ran out under iPadOS 26's sidebar
    /// (FB-136).
    private var block: some View {
        GeometryReader { proxy in
            let extensionHeight = DSLayout.bookDetailBackdropTopExtension
            Group {
                if let tone = embedding?.tone {
                    LinearGradient(colors: [tone.top, tone.bottom], startPoint: .top, endPoint: .bottom)
                } else {
                    CoverTint.blockGround(for: coverColor, increasedContrast: contrast == .increased).color
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height + extensionHeight)
            .offset(y: -extensionHeight)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var isCard: Bool { embedding != nil }

    /// 檢視有聲書, or 檢視書籍: a panel like the source's under it, the whole of it one button to
    /// the work in its other form.
    private func otherFormCard(_ other: BookDetailOtherForm, open: @escaping (WorkDetailRoute) -> Void) -> some View {
        Button { open(other.work) } label: {
            VStack(alignment: .leading, spacing: DSSpacing.md) {
                HStack(spacing: DSSpacing.xs) {
                    Text(other.title)
                        .font(DSFont.headline)
                    Image(systemName: "chevron.right")
                        .font(DSFont.subheadline.weight(.semibold))
                        .accessibilityHidden(true)
                }
                .foregroundStyle(primaryText)
                HStack(spacing: DSSpacing.md) {
                    HomeCardCover(cover: other.cover, title: title, author: author,
                                  size: CGSize(width: DSLayout.bookDetailOtherFormCoverHeight
                                                * (other.isSquare ? 1 : DSLayout.discoverCoverAspectRatio),
                                               height: DSLayout.bookDetailOtherFormCoverHeight))
                    VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                        ForEach(Array(other.lines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(DSFont.subheadline)
                                .foregroundStyle(index == 0 ? primaryText : secondaryText)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DSSpacing.lg)
            .background(veil(DSLayout.bookDetailSourcePanelOpacity),
                        in: RoundedRectangle(cornerRadius: DSLayout.bookDetailSourcePanelRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, DSLayout.bookDetailSourcePanelInset)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(other.title)
        .accessibilityValue(other.lines.joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("detail.otherForm")
    }

    /// White on the block; a card's own ink on its paper.
    private var primaryText: Color { embedding?.tone.ink ?? DSColor.textOnFixedFill }
    /// The cover's hue made light, which the block is darkened for (`CoverTint.blockLine`).
    private var secondaryText: Color {
        embedding.map { $0.tone.ink.opacity(DSLayout.cardSecondaryTextOpacity) } ?? CoverTint.blockLine(for: coverColor).color
    }

    /// A veil over the block for the panel and the second action: dark on the block, so the
    /// light text on it reads better still; the card's ink, light, on its paper.
    private func veil(_ opacity: Double) -> Color {
        (embedding?.tone.ink ?? Color.black).opacity(opacity)
    }

    private var artwork: some View {
        let shape = RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous)
        return cover
            .environment(\.coverImageObserver, Self.observer(reportingTo: $coverColor))
            .frame(width: artworkSize.width, height: artworkSize.height)
            .clipShape(shape)
            .overlay(shape.stroke(DSColor.separator, lineWidth: 0.5))
            .shadow(
                color: DSColor.bookDetailCoverShadow,
                radius: DSLayout.bookDetailCoverShadowRadius,
                y: DSLayout.bookDetailCoverShadowOffsetY
            )
            .background(alignment: .bottom) {
                if let seriesFan { SeriesCoverFan(fan: seriesFan, size: artworkSize) }
            }
            // The title below names the book; the artwork would only repeat it.
            .accessibilityHidden(true)
    }

    /// Takes the average colour of the image the cover draws, off the main thread.
    private static func observer(reportingTo color: Binding<CoverTint.RGB?>) -> @MainActor (UIImage) -> Void {
        { image in
            Task {
                let found = await Task.detached(priority: .utility) { CoverTint.average(of: image) }.value
                if found != color.wrappedValue { color.wrappedValue = found }
            }
        }
    }

    /// The series the book belongs to, the link `series` among `links`.
    private var seriesLink: BookDetailLink? { links.first { $0.id == "series" } }
    /// The links of the line under the author: every one but the series'.
    private var genreLinks: [BookDetailLink] { links.filter { $0.id != "series" } }

    /// The series over the title, as Apple Books' store names a book's (maintainer, 2026-11-14,
    /// from its page: 「第 4 冊, 6:20 MAN ›」): small capitals over a rule, the whole a button to
    /// the series' page.
    private func seriesButton(_ link: BookDetailLink) -> some View {
        Button(action: link.action) {
            HStack(spacing: DSSpacing.xs) {
                Text(link.title)
                    .textCase(.uppercase)
                    .tracking(DSLayout.bookDetailSeriesLinkTracking)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .imageScale(.small)
                    .accessibilityHidden(true)
            }
            .font(DSFont.footnote.weight(.semibold))
            .foregroundStyle(primaryText)
            .padding(.bottom, DSSpacing.xs)
            .overlay(alignment: .bottom) {
                Rectangle().fill(secondaryText).frame(height: 1)
            }
            .frame(minHeight: DSLayout.minimumTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(link.title)
        .accessibilityHint(link.hint ?? "")
        .accessibilityIdentifier("detail.link.\(link.id)")
    }

    private var titleBlock: some View {
        VStack(spacing: DSSpacing.xs) {
            if let seriesLink {
                seriesButton(seriesLink)
            }
            Text(title)
                .font(DSFont.title2.weight(.semibold))
                .foregroundStyle(primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .sourceGesture(
                    tap: sourceGestures?.tapName, longPress: sourceGestures?.longPressName,
                    longPressName: localized("長按書名")
                )
            if let gestures = sourceGestures, authorActions.isEmpty {
                Text(author)
                    .font(DSFont.callout)
                    .foregroundStyle(primaryText)
                    .lineLimit(1)
                    .sourceGesture(
                        tap: gestures.tapAuthor, longPress: gestures.longPressAuthor,
                        longPressName: localized("長按作者")
                    )
            } else if authorActions.isEmpty {
                Text(author)
                    .font(DSFont.callout)
                    .foregroundStyle(primaryText)
                    .lineLimit(1)
            } else {
                ForEach(authorActions) { author in
                    Button(action: author.action) {
                        HStack(spacing: DSSpacing.xs) {
                            Text(author.name)
                            Image(systemName: "chevron.right")
                                .font(DSFont.caption.weight(.semibold))
                                .accessibilityHidden(true)
                        }
                        .font(DSFont.callout)
                        .frame(minHeight: DSLayout.minimumTapTarget)
                    }
                    // The author line sits as tight under the title as Apple Books sets it; the
                    // tap target keeps its height, overlapping the text around it.
                    .padding(.vertical, -DSSpacing.md)
                    .buttonStyle(.plain)
                    .foregroundStyle(primaryText)
                    .accessibilityIdentifier("publicLibrary.author.\(author.id)")
                }
            }
            if let gestures = sourceGestures, !gestures.labels.isEmpty {
                // One tappable label each, so the source learns which one (legado `clickBookLabel`),
                // and every one on the page: a long press is not offered from a menu.
                WrappingFlowLayout(spacing: DSSpacing.sm, alignment: .center) {
                    ForEach(gestures.labels, id: \.self) { label in
                        Text(label)
                            .font(DSFont.footnote)
                            .foregroundStyle(secondaryText)
                            .sourceGesture(
                                tap: { gestures.tapLabel(label) },
                                longPress: { gestures.longPressLabel(label) },
                                longPressName: localized("長按標籤")
                            )
                    }
                }
                .padding(.top, DSSpacing.sm)
            } else if !genreLinks.isEmpty {
                genreLine
                    .padding(.top, DSSpacing.sm)
            } else if links.isEmpty, !meta.isEmpty {
                // Links replace it, the series' over the title among them.
                Text(meta)
                    .font(DSFont.footnote)
                    .foregroundStyle(secondaryText)
                    .lineLimit(1)
                    .padding(.top, DSSpacing.sm)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    /// Genres on one line (maintainer, 2026-11-12: many of them, wrapped, were what was wrong
    /// with the page): the first few, each its own button, and the rest in a 「+N」 menu. Fewer
    /// are shown where they do not fit the line.
    private var genreLine: some View {
        ViewThatFits(in: .horizontal) {
            genreRow(shown: min(genreLinks.count, DSLayout.bookDetailGenreLimit))
            genreRow(shown: min(genreLinks.count, DSLayout.bookDetailGenreLimit - 1))
            genreRow(shown: 1)
        }
        // The 44pt tap targets would push the line away from the author; the text keeps its rhythm.
        .padding(.vertical, -DSSpacing.md)
    }

    private func genreRow(shown: Int) -> some View {
        HStack(spacing: DSSpacing.sm) {
            ForEach(Array(genreLinks.prefix(shown).enumerated()), id: \.element.id) { index, link in
                if index > 0 {
                    Text(verbatim: "·")
                        .accessibilityHidden(true)
                }
                Button(action: link.action) {
                    Text(link.title)
                        .lineLimit(1)
                        .frame(minHeight: DSLayout.minimumTapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(link.hint ?? localized("顯示這個分類的作品"))
                .accessibilityIdentifier("detail.link.\(link.id)")
            }
            if genreLinks.count > shown {
                Menu {
                    ForEach(genreLinks.dropFirst(shown)) { link in
                        Button(link.title, action: link.action)
                    }
                } label: {
                    Text(verbatim: "+\(genreLinks.count - shown)")
                        .monospacedDigit()
                        .frame(minWidth: DSLayout.minimumTapTarget, minHeight: DSLayout.minimumTapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(localized("其他分類"))
                .accessibilityValue((genreLinks.count - shown).formatted())
                .accessibilityIdentifier("detail.link.more")
            }
        }
        .font(DSFont.footnote)
        .foregroundStyle(secondaryText)
    }

    // MARK: Panel

    /// The source, what is known of the copy, and the two actions, on one panel. A page with no
    /// source to name and nothing to say draws the actions alone.
    @ViewBuilder
    private var panel: some View {
        // Where reading resumes is a fact of the copy, on its line; the action keeps its words.
        let facts = (source?.facts ?? []) + [primary.detail].compactMap { $0 }.filter { !$0.isEmpty }
        if source != nil || !facts.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                if let source { sourceRow(source) }
                if !facts.isEmpty {
                    Text(facts.joined(separator: " · "))
                        .font(DSFont.footnote)
                        .foregroundStyle(secondaryText)
                        .monospacedDigit()
                        .lineLimit(1)
                        .accessibilityIdentifier("detail.source.facts")
                }
                actions
                    .padding(.top, DSSpacing.md)
            }
            .padding(DSSpacing.lg)
            .background(veil(DSLayout.bookDetailSourcePanelOpacity),
                        in: RoundedRectangle(cornerRadius: DSLayout.bookDetailSourcePanelRadius, style: .continuous))
            // Narrower than the page's text, as Apple Books sets its panel in from the edges
            // (maintainer, 2026-11-12: edge to edge, it was too wide).
            .padding(.horizontal, DSLayout.bookDetailSourcePanelInset)
        } else {
            actions
                .padding(.horizontal, DSLayout.bookDetailSourcePanelInset)
        }
    }

    private func sourceRow(_ source: BookDetailHeroSource) -> some View {
        HStack(alignment: .center, spacing: DSSpacing.md) {
            sourceName(source)
            Spacer(minLength: DSSpacing.sm)
            if let followUp = source.followUp {
                Button(action: followUp.action) {
                    Text([source.status, followUp.title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(DSFont.footnote)
                        .lineLimit(1)
                        .frame(minHeight: DSLayout.minimumTapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(primaryText)
                .accessibilityIdentifier("detail.source.followUp")
            } else if let status = source.status.flatMap({ $0.isEmpty ? nil : $0 })
                        ?? source.count.map({ String(format: localized("共 %d 個來源"), $0) }) {
                Text(status)
                    .font(DSFont.footnote)
                    .foregroundStyle(secondaryText)
                    .lineLimit(1)
                    // Read with the name, as 來源's value.
                    .accessibilityHidden(true)
            }
        }
        // The name's 44pt tap target would push the line of facts away from it.
        .padding(.vertical, -DSSpacing.sm)
    }

    /// The source's name: a menu of the work's versions, the button that opens 換源, or plain
    /// text where there is one place only. 來源 is what it is, the name its value, switching what
    /// activating it does; 「換源」 stays reachable to Voice Control through the input labels.
    @ViewBuilder
    private func sourceName(_ source: BookDetailHeroSource) -> some View {
        let label = HStack(spacing: DSSpacing.xs) {
            Text(source.name)
                .font(DSFont.body.weight(.semibold))
                .lineLimit(1)
            if source.isSwitchable {
                Image(systemName: "chevron.up.chevron.down")
                    .font(DSFont.caption.weight(.semibold))
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(primaryText)
        .frame(minHeight: DSLayout.minimumTapTarget)
        .contentShape(Rectangle())
        let spoken = [source.name, source.followUp == nil ? source.status : nil]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "，")

        if let choice = source.choice {
            Menu {
                Picker(localized("來源"), selection: choice.selection) {
                    ForEach(choice.options) { Text($0.title).tag($0.id) }
                }
                if let extra = choice.extra {
                    Divider()
                    Button(extra.title, action: extra.action)
                }
            } label: {
                label
            }
            .buttonStyle(.plain)
            .accessibilityLabel(localized("來源"))
            .accessibilityValue(spoken)
            .accessibilityHint(localized("點兩下切換來源配置"))
            .accessibilityInputLabels([localized("換源"), localized("來源")])
            .accessibilityIdentifier("detail.info.source")
        } else if let action = source.switchAction {
            Button(action: action) { label }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(localized("來源"))
                .accessibilityValue(spoken)
                .accessibilityHint(localized("點兩下切換來源配置"))
                .accessibilityInputLabels([localized("換源"), localized("來源")])
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("detail.info.source")
        } else {
            label
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(localized("來源"))
                .accessibilityValue(spoken)
                .accessibilityIdentifier("detail.info.source")
        }
    }

    /// The shelf's action and reading, side by side and as tall as each other, reading the
    /// white one, as Apple Books sets 試讀 beside 取得. Always one row, at every text size:
    /// stacking them is what the maintainer rejected (2026-10-12); a title truncates instead.
    private var actions: some View {
        HStack(spacing: DSSpacing.md) {
            if quietPrimary {
                secondaryButton(primary)
            } else {
                if let secondary { secondaryButton(secondary) }
                primaryButton
            }
        }
    }

    private var primaryButton: some View {
        Button(action: primary.action) {
            BookDetailActionLabel(action: primary, progressTint: DSColor.cardPrimaryActionLabel, showsIcon: false)
        }
        .buttonStyle(BookDetailCardActionStyle(fill: DSColor.cardPrimaryActionFill, label: DSColor.cardPrimaryActionLabel))
        .disabled(!primary.isEnabled || primary.isBusy)
        // A page with nothing to read says so; a card keeps its white while its page loads, so
        // paging between cards never changes it.
        .opacity(isCard || primary.isEnabled || primary.isBusy ? 1 : DSLayout.bookDetailUnavailableActionOpacity)
        .accessibilityLabel(primary.title)
        .accessibilityValue(primary.detail ?? "")
    }

    private func secondaryButton(_ secondary: BookDetailAction) -> some View {
        Button(action: secondary.action) {
            BookDetailActionLabel(action: secondary, progressTint: primaryText)
        }
        .buttonStyle(BookDetailCardActionStyle(fill: veil(DSLayout.bookDetailSecondaryActionOpacity), label: primaryText))
        .disabled(!secondary.isEnabled || secondary.isBusy)
        .opacity(secondary.dimsWhenUnavailable && !secondary.isEnabled ? DSLayout.bookDetailUnavailableActionOpacity : 1)
        .accessibilityLabel(secondary.title)
        .removalConfirmation(secondary.removalConfirmation)
    }
}

/// A carousel card's action, as Apple Books draws its store card's, and a video page's
/// white play button: a flat capsule whose colours do not change when the action is
/// unavailable, so a card does not flicker as its page loads. Whether it can be pressed is
/// still announced.
struct BookDetailCardActionStyle: ButtonStyle {
    let fill: Color
    let label: Color
    var minHeight = DSLayout.cardActionHeight

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(label)
            .frame(minHeight: minHeight)
            .background(fill, in: Capsule())
            .opacity(configuration.isPressed ? DSLayout.cardActionPressedOpacity : 1)
    }
}

private struct BookDetailActionLabel: View {
    let action: BookDetailAction
    let progressTint: Color
    /// False for reading: its words alone. Busy, a spinner still shows.
    var showsIcon = true

    var body: some View {
        // The icon goes first when the title does not fit beside it; the title then truncates.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DSSpacing.sm) {
                if showsIcon || action.isBusy { leading }
                title
            }
            HStack(spacing: DSSpacing.sm) {
                if action.isBusy { leading }
                title
            }
        }
        .font(DSFont.body.weight(.semibold))
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var leading: some View {
        if action.isBusy {
            ProgressView()
                .controlSize(.small)
                .tint(progressTint)
        } else {
            Image(systemName: action.systemImage)
                .accessibilityHidden(true)
        }
    }

    private var title: some View {
        Text(action.title)
            .lineLimit(1)
    }
}

// MARK: - 作品資訊

/// One column of the information strip.
struct BookDetailInfoItem: Identifiable {
    let id: String
    let label: String
    let value: String
    /// A second line under the value. Shown in the accent colour when the item acts.
    var detail: String?
    var action: (() -> Void)?
    /// A choice made in place, from the item's own menu: 作品詳情's version and format.
    var choice: BookDetailInfoChoice?
    var accessibilityHint: String?
    var accessibilityInputLabels: [String] = []
    /// A detail line that is news, not a verb (「搜尋來源配置中…」): VoiceOver reads it after
    /// the value.
    var spokenDetail: String?

    var isInteractive: Bool { action != nil || choice != nil }

    var spokenValue: String { [value, spokenDetail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "，") }

    /// The current source, opening 換源, where a page keeps it among its information (a video's;
    /// a book's is on its hero's panel, `BookDetailHeroSource`). 來源 is what the item is, the
    /// source name its value, switching what activating it does; the visible 「換源」 stays
    /// reachable to Voice Control through the input labels.
    static func source(name: String, action: @escaping () -> Void) -> BookDetailInfoItem {
        BookDetailInfoItem(
            id: "source",
            label: localized("來源"),
            value: name,
            detail: localized("換源"),
            action: action,
            accessibilityHint: localized("點兩下切換來源配置"),
            accessibilityInputLabels: [localized("換源")]
        )
    }
}

/// The options an information item picks among, shown as a native menu of one `Picker`.
struct BookDetailInfoChoice {
    struct Option: Identifiable {
        let id: String
        let title: String
    }

    let options: [Option]
    let selection: Binding<String>
    /// One more thing the menu does, under the options (來源's 重試 or 繼續搜索).
    var extra: (title: String, action: () -> Void)? = nil
}

/// 作品資訊: the copy's facts as Apple Books' store lists a book's 系統需求 and 版本 — a titled
/// section at the foot of the page, each fact its label in bold over its value in grey, no
/// hairline between them (maintainer, 2026-11-12: rows with a line and a chevron each read
/// as a settings page). It replaced the strip of columns under the hero (Editorial
/// Minimalism, 2026-10-12), which gave chapter counts and source names the weight of the
/// work itself.
struct BookDetailInfoSection: View {
    let items: [BookDetailInfoItem]

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                BookDetailSectionHeader(title: localized("作品資訊"))
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        cell(item)
                    }
                }
            }
            .padding(.horizontal, DSSpacing.lg)
        }
    }

    @ViewBuilder
    private func cell(_ item: BookDetailInfoItem) -> some View {
        if let action = item.action {
            Button(action: action) {
                row(item)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.label)
            .accessibilityValue(item.spokenValue)
            .accessibilityHint(item.accessibilityHint ?? "")
            .accessibilityInputLabels(item.accessibilityInputLabels + [item.label])
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("detail.info.\(item.id)")
        } else if let choice = item.choice {
            Menu {
                Picker(item.label, selection: choice.selection) {
                    ForEach(choice.options) { Text($0.title).tag($0.id) }
                }
                if let extra = choice.extra {
                    Divider()
                    Button(extra.title, action: extra.action)
                }
            } label: {
                row(item)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.label)
            .accessibilityValue(item.spokenValue)
            .accessibilityHint(item.accessibilityHint ?? "")
            .accessibilityInputLabels(item.accessibilityInputLabels + [item.label])
            .accessibilityIdentifier("detail.info.\(item.id)")
        } else {
            row(item)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(item.label)
                .accessibilityValue(item.spokenValue)
                .accessibilityIdentifier("detail.info.\(item.id)")
        }
    }

    private func row(_ item: BookDetailInfoItem) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.xxs) {
            Text(item.label)
                .fontWeight(.semibold)
                .foregroundStyle(DSColor.textPrimary)
            // A choice or link without a detail line ends its value with the chevron, on
            // the same line, as a Settings menu row does.
            HStack(alignment: .firstTextBaseline, spacing: DSSpacing.xs) {
                Text(item.value)
                    .foregroundStyle(DSColor.textSecondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                if item.detail == nil, item.isInteractive {
                    Image(systemName: item.choice == nil ? "chevron.right" : "chevron.up.chevron.down")
                        .font(DSFont.caption2.weight(.semibold))
                        .foregroundStyle(DSColor.textSecondary)
                        .accessibilityHidden(true)
                }
            }
            if let detail = item.detail {
                HStack(spacing: DSSpacing.xs) {
                    Text(detail)
                    if item.isInteractive {
                        Image(systemName: item.choice == nil ? "chevron.right" : "chevron.up.chevron.down")
                            .font(DSFont.caption2.weight(.semibold))
                            .accessibilityHidden(true)
                    }
                }
                .font(DSFont.footnote)
                .foregroundStyle(item.isInteractive ? DSColor.textPrimary : DSColor.textSecondary)
                .lineLimit(1)
            }
        }
        .font(DSFont.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, DSSpacing.sm)
        .frame(minHeight: item.isInteractive ? DSLayout.minimumTapTarget : nil)
    }
}

// MARK: - Section header

/// A section title in Apple's store style. One that leads to the rest of what it shows is a
/// button, its chevron after its name, as the store's 讀者評論 › is (maintainer, 2026-11-12: no
/// accent-coloured 「查看全部」 at the far end); `trailing` is a quiet count there (「100 章」).
struct BookDetailSectionHeader<Accessory: View>: View {
    let title: String
    /// What the title does, as VoiceOver's hint and a Voice Control name: 「查看全部」.
    var actionTitle: String?
    var action: (() -> Void)?
    var trailing: String?
    /// Beside the title: 同題材's category menu.
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            if let action {
                Button(action: action) {
                    HStack(alignment: .firstTextBaseline, spacing: DSSpacing.sm) {
                        titleText
                        Image(systemName: "chevron.right")
                            .font(DSFont.subheadline.weight(.semibold))
                            .foregroundStyle(DSColor.textTertiary)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: DSLayout.minimumTapTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title)
                .accessibilityHint(actionTitle ?? "")
                .accessibilityInputLabels([title] + [actionTitle].compactMap { $0 })
                .accessibilityAddTraits(.isHeader)
            } else {
                titleText
                    .accessibilityAddTraits(.isHeader)
            }
            accessory()
            Spacer(minLength: DSSpacing.sm)
            if let trailing {
                Text(trailing)
                    .font(DSFont.footnote)
                    .foregroundStyle(DSColor.textSecondary)
                    .monospacedDigit()
            }
        }
    }

    private var titleText: some View {
        Text(title)
            .font(DSFont.title3.weight(.bold))
            .foregroundStyle(DSColor.textPrimary)
    }
}

/// The hairline that ends a section, as Apple Books' store separates its sections: under the
/// section's own content, so a section with nothing to show leaves no line.
struct BookDetailSectionRule: View {
    var body: some View {
        Divider()
            .padding(.top, DSSpacing.md)
    }
}

extension BookDetailSectionHeader where Accessory == EmptyView {
    init(title: String, actionTitle: String? = nil, action: (() -> Void)? = nil, trailing: String? = nil) {
        self.init(title: title, actionTitle: actionTitle, action: action, trailing: trailing, accessory: { EmptyView() })
    }
}

// MARK: - Description

/// 「推薦理由」 (AI 推薦 8e): why the reader's AI service suggested the work, marked AI 產生.
/// The reason is the model's own text, drawn as it is: never looked up as a string key or read
/// as Markdown.
struct BookDetailRecommendationSection: View {
    let reason: String

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            BookDetailSectionHeader(title: localized("推薦理由")) {
                Text(localized("AI 產生"))
                    .font(DSFont.caption)
                    .foregroundStyle(DSColor.textSecondary)
                    .padding(.horizontal, DSSpacing.sm)
                    .padding(.vertical, DSSpacing.xs)
                    // On the white page a system-background capsule would not show.
                    .background(DSColor.quietCardFill, in: Capsule())
            }
            Text(verbatim: reason)
                .font(DSFont.subheadline)
                .foregroundStyle(DSColor.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            BookDetailSectionRule()
        }
        .padding(.horizontal, DSSpacing.lg)
    }
}

/// The description, clamped to four lines with Apple's 「更多」 under it: grey text, and the
/// button in the text's own colour at its leading edge, never the accent (maintainer,
/// 2026-11-12). 「更多」 opens the whole description on a page of its own, as Apple Books'
/// store does, with every genre under it (the hero shows a few on one line); the page itself
/// keeps its four lines, so nothing under them moves.
///
/// The whole description is the text the page already had, bounded before it reached the
/// view (guardrail 4), laid out in the sheet's scroll view as the page laid it out expanded:
/// never measured, never forced to its intrinsic height (guardrail 6).
///
/// Plain intros arrive cleaned by Legado's formatter; `<usehtml>`, `<md>` and
/// `<useweb>` intros keep their markup and render as HTML, Markdown or a web page
/// (`BookIntroContent`). Whether plain text overflows is estimated from its length and
/// line breaks rather than measured: measuring means laying out the full text a second
/// time at its intrinsic height, which `Technotes/iOS17SearchWatchdogPostmortem.md`
/// (guardrail 6) rules out for source-controlled text inside this scroll view on iOS 17.
struct BookDetailIntroSection: View {
    /// A section of its own, or under a video's play button as Infuse and VidHub show a
    /// series' overview: no 簡介 header, two small lines that open when tapped, in the
    /// hero's margins; or the whole of it, on the page 「更多」 opens.
    enum Placement {
        case section
        case hero
        case full
    }

    let text: String
    @Binding var isExpanded: Bool
    /// Base for relative links and images in a rich intro (the book's detail URL).
    var baseURL: String?
    /// Runs a `<usehtml>` intro's button or image script.
    var onAction: ((BookIntroAction) -> Void)?
    /// Whether `text` is a book source's own description, whose Legado formats (`<usehtml>`,
    /// `<md>`, `<useweb>`) are read. Any other text, such as the reader's own or a library's,
    /// is shown as it is (decision 33).
    var readsSourceFormats = true
    /// Whether `text` says there is no description in the reader's language (沒有繁體中文簡介):
    /// secondary, as the card draws it.
    var isUnavailable = false
    var placement = Placement.section
    /// Every genre that leads somewhere, listed under the whole description.
    var links: [BookDetailLink] = []

    /// What was tapped on the whole description's page, run once that page is gone: a sheet
    /// or a push begun while it dismisses is dropped on iOS 17
    /// (`Technotes/iOS17MenuModalPresentation.md`).
    @State private var pendingAction: BookIntroAction?
    @State private var pendingLink: BookDetailLink?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var webLayout = BookIntroLayout()
    /// Parsed once per intro, never in `body` (guardrail 5).
    @State private var markdown: AttributedString?
    /// About one line of the intro's text: a rich intro collapses to its last whole line above
    /// the collapsed lines.
    @ScaledMetric(relativeTo: .subheadline) private var richLineHeight: CGFloat = 22
    @ScaledMetric(relativeTo: .caption) private var heroLineHeight = DSLayout.videoIntroLineHeight

    private var collapsedLineLimit: Int { placement == .hero ? 2 : 4 }
    /// Roughly that many lines of CJK text at the default text size across a phone.
    private var collapsedCharacterEstimate: Int { placement == .hero ? 66 : 80 }
    private var collapsedRichLimit: CGFloat { richLineHeight * CGFloat(collapsedLineLimit) }
    private var textFont: Font {
        switch placement {
        case .hero: DSFont.caption
        case .section: DSFont.subheadline
        case .full: DSFont.body
        }
    }

    /// Whether the text is drawn whole: a section never is, its 「更多」 opens the page of it.
    private var isOpen: Bool {
        switch placement {
        case .hero: isExpanded
        case .section: false
        case .full: true
        }
    }

    private var textColor: Color {
        isUnavailable || placement != .hero ? DSColor.textSecondary : DSColor.textPrimary
    }

    private var isRich: Bool {
        switch content {
        case .plain, .markdown: false
        case .html, .web: true
        }
    }

    private var content: BookIntroContent { readsSourceFormats ? BookIntroContent(text) : .plain(text) }

    private var mayOverflow: Bool {
        switch content {
        case .plain(let plain), .markdown(let plain):
            plain.count > collapsedCharacterEstimate
                || plain.reduce(0) { $1.isNewline ? $0 + 1 : $0 } >= collapsedLineLimit
        case .html, .web:
            webLayout.height > collapsedRichHeight + 0.5
        }
    }

    private var collapsedRichHeight: CGFloat {
        webLayout.collapsedHeight(limit: collapsedRichLimit)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            if placement == .section {
                BookDetailSectionHeader(title: localized("簡介"))
            }
            if placement == .hero, !isRich, mayOverflow {
                // The lines themselves open, with no 更多 under them; a web intro takes its
                // own taps, so it keeps the button.
                Button(action: toggle) {
                    introBody
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(isOpen ? localized("收合") : localized("簡介：更多"))
            } else {
                introBody
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if mayOverflow, placement == .section || (placement == .hero && isRich) {
                Button(action: toggle) {
                    Text(isOpen ? localized("收合") : localized("簡介：更多"))
                        .font(DSFont.subheadline.weight(.semibold))
                        .foregroundStyle(DSColor.textPrimary)
                        .frame(minHeight: DSLayout.minimumTapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: placement == .section ? .leading : .trailing)
            }
            if placement == .section { BookDetailSectionRule() }
        }
        .padding(.horizontal, placement == .hero ? 0 : DSSpacing.lg)
        .task(id: text) { parseMarkdownIfNeeded() }
        .sheet(isPresented: placement == .section ? $isExpanded : .constant(false), onDismiss: runPending) {
            whole
        }
    }

    private func toggle() {
        // A section opens its page; a video's lines open where they are.
        guard placement == .hero else {
            isExpanded = true
            return
        }
        withAnimation(reduceMotion ? nil : DSAnimation.standard) {
            isExpanded.toggle()
        }
    }

    private func runPending() {
        if let action = pendingAction {
            pendingAction = nil
            onAction?(action)
        }
        if let link = pendingLink {
            pendingLink = nil
            link.action()
        }
    }

    /// The whole description, and the genres under it, on a page of its own.
    private var whole: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DSSpacing.xl) {
                    BookDetailIntroSection(
                        text: text, isExpanded: .constant(true), baseURL: baseURL,
                        onAction: onAction == nil ? nil : { action in
                            pendingAction = action
                            isExpanded = false
                        },
                        readsSourceFormats: readsSourceFormats, isUnavailable: isUnavailable, placement: .full
                    )
                    if !links.isEmpty { genres }
                }
                .padding(.vertical, DSSpacing.lg)
            }
            .background(PageBackgroundView(scope: .global).ignoresSafeArea())
            .pageBackgroundToolbar(for: .global)
            .navigationTitle(localized("簡介"))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        isExpanded = false
                    } label: {
                        Label(localized("關閉"), systemImage: "xmark")
                            .labelStyle(.iconOnly)
                    }
                    .accessibilityIdentifier("detail.intro.close")
                }
            }
        }
    }

    private var genres: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
                .padding(.bottom, DSSpacing.lg)
            Text(localized("分類"))
                .font(DSFont.subheadline.weight(.semibold))
                .foregroundStyle(DSColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
            ForEach(links) { link in
                Button {
                    pendingLink = link
                    isExpanded = false
                } label: {
                    HStack(spacing: DSSpacing.sm) {
                        Text(link.title)
                            .font(DSFont.body)
                            .foregroundStyle(DSColor.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: DSSpacing.sm)
                        Image(systemName: "chevron.right")
                            .font(DSFont.caption.weight(.semibold))
                            .foregroundStyle(DSColor.textTertiary)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: DSLayout.minimumTapTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(link.hint ?? localized("顯示這個分類的作品"))
                .accessibilityIdentifier("detail.intro.link.\(link.id)")
            }
        }
        .padding(.horizontal, DSSpacing.lg)
    }

    @ViewBuilder
    private var introBody: some View {
        switch content {
        case .plain(let plain):
            Text(plain)
                .font(textFont)
                .foregroundStyle(textColor)
                .lineLimit(isOpen ? nil : collapsedLineLimit)
                .modifier(IntroLineHeight(points: placement == .hero ? heroLineHeight : nil))
        case .markdown(let source):
            Text(markdown ?? AttributedString(source))
                .font(textFont)
                .foregroundStyle(textColor)
                .lineLimit(isOpen ? nil : collapsedLineLimit)
                .modifier(IntroLineHeight(points: placement == .hero ? heroLineHeight : nil))
        case .html(let markup):
            richBody(markup, mode: .fragment)
        case .web(let markup):
            richBody(markup, mode: .page)
        }
    }

    private func richBody(_ markup: String, mode: BookIntroWebView.Mode) -> some View {
        BookIntroWebView(
            markup: markup,
            mode: mode,
            baseURL: baseURL.flatMap(URL.init(string:)),
            layout: $webLayout,
            onAction: onAction
        )
        .frame(height: max(isOpen ? webLayout.height : collapsedRichHeight, 1))
        .clipped()
    }

    /// `<md>` intros: inline Markdown (emphasis, links, code) with the source's line
    /// breaks kept. SwiftUI's `Text` draws no block elements, so headings and lists
    /// read as their text.
    private func parseMarkdownIfNeeded() {
        guard case .markdown(let source) = content else {
            markdown = nil
            return
        }
        do {
            markdown = try AttributedString(
                markdown: source,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )
        } catch {
            AppLogger.parse("⟐ <md> intro is not valid Markdown", error: error)
            markdown = AttributedString(source)
        }
    }
}

/// VidHub's tight lines under a video's buttons: CJK at its font's own line height spreads
/// them apart. `Text` takes a line height from iOS 26 on; earlier systems keep the font's.
/// The `#if compiler` guard mirrors `CardButtonGlass`.
private struct IntroLineHeight: ViewModifier {
    let points: CGFloat?

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), let points {
            content.lineHeight(.exact(points: points))
        } else {
            content
        }
        #else
        content
        #endif
    }
}

// MARK: - Chapters

/// One of 目錄's few rows on a detail page: quiet, grey, with no chevron and no hairline
/// (maintainer, 2026-11-12). The whole list is the reader's (`ReaderTOCView`).
struct BookDetailChapterRow: View {
    enum Trailing {
        /// Opens the reader at the chapter.
        case disclosure
        /// Plays the chapter, as an episode row in Podcasts.
        case play
    }

    let title: String
    var caption: String?
    let isLocked: Bool
    let trailing: Trailing
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DSSpacing.md) {
                VStack(alignment: .leading, spacing: DSSpacing.xs) {
                    if let caption {
                        Text(caption)
                            .font(DSFont.caption)
                            .foregroundStyle(DSColor.textSecondary)
                    }
                    Text(title)
                        .font(DSFont.subheadline)
                        .foregroundStyle(DSColor.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: DSSpacing.sm)
                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(DSFont.caption)
                        .foregroundStyle(DSColor.warning)
                        .accessibilityHidden(true)
                }
                if trailing == .play {
                    Image(systemName: "play.circle")
                        .font(DSFont.title3)
                        .foregroundStyle(DSColor.textSecondary)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: DSLayout.minimumTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isLocked ? localized("付費章節") : "")
    }
}

/// The chapter section: its title, which opens the whole list, with the count at the far end,
/// and a few rows under it, with loading, error and empty states in place of the rows.
struct BookDetailChapterSection<Row: View>: View {
    /// Which rows the page lists (maintainer, 2026-11-12, by option).
    enum Preview {
        /// The first few: a file's chapters, which has no newest one.
        case first
        /// 最新, then where reading stands, or 開頭 for a book not read yet: a book read online,
        /// whose newest chapter is what a reader following it looks for.
        case latestAndResume(resumeIndex: Int?)
    }

    let title: String
    let chapters: [OnlineChapterRef]
    let isLoading: Bool
    let errorMessage: String?
    /// The newest chapter as the source's own page names it, shown as 最新 until the list is read.
    let latestChapter: String
    let onRetry: () -> Void
    let onShowAll: () -> Void
    /// Said with no chapter to list; 「目錄為空」 by default.
    var emptyText: String?
    var preview = Preview.first
    @ViewBuilder let row: (_ offset: Int, _ chapter: OnlineChapterRef) -> Row

    /// Enough to show what the list holds; the rest is one tap away.
    static var previewLimit: Int { 3 }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            BookDetailSectionHeader(
                title: title,
                actionTitle: chapters.isEmpty ? nil : localized("查看全部"),
                action: chapters.isEmpty ? nil : onShowAll,
                trailing: chapters.isEmpty ? nil : String(format: localized("%d 章"), chapters.count)
            )
            content
            BookDetailSectionRule()
        }
        .padding(.horizontal, DSSpacing.lg)
    }

    private var showsLatest: Bool {
        if case .latestAndResume = preview { true } else { false }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && chapters.isEmpty {
            if showsLatest, !latestChapter.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: DSSpacing.md, verticalSpacing: 0) {
                    labelled(localized("最新")) {
                        Text(latestChapter)
                            .font(DSFont.subheadline)
                            .foregroundStyle(DSColor.textSecondary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: DSLayout.minimumTapTarget, alignment: .leading)
                    }
                }
            }
            ProgressView(localized("載入目錄…"))
                .frame(maxWidth: .infinity)
                .padding(.vertical, DSSpacing.lg)
        } else if let errorMessage, chapters.isEmpty {
            VStack(spacing: DSSpacing.sm) {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(DSFont.footnote)
                    .foregroundStyle(DSColor.textSecondary)
                    .multilineTextAlignment(.center)
                Button(localized("重試"), action: onRetry)
                    .buttonStyle(.bordered)
                    .tint(DSColor.textPrimary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DSSpacing.lg)
        } else if chapters.isEmpty {
            Text(emptyText ?? localized("目錄為空"))
                .font(DSFont.subheadline)
                .foregroundStyle(DSColor.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DSSpacing.lg)
        } else {
            VStack(spacing: 0) {
                switch preview {
                case .first:
                    ForEach(Array(chapters.prefix(Self.previewLimit).enumerated()), id: \.element.id) { offset, chapter in
                        row(offset, chapter)
                    }
                case .latestAndResume(let resumeIndex):
                    let last = chapters.count - 1
                    // One column of labels as wide as the widest (「Latest」, 「Last Read」), so the
                    // titles line up in every language.
                    Grid(alignment: .leading, horizontalSpacing: DSSpacing.md, verticalSpacing: 0) {
                        labelled(localized("最新")) { row(last, chapters[last]) }
                        if last > 0 {
                            // Read up to the newest already, the second row is the start: 最新 says the rest.
                            let resume = resumeIndex.flatMap { (0..<last).contains($0) ? $0 : nil }
                            labelled(localized(resume == nil ? "目錄預覽：開頭" : "目錄預覽：讀到")) {
                                row(resume ?? 0, chapters[resume ?? 0])
                            }
                        }
                    }
                }
            }
        }
    }

    /// A grid row: a small label of what the row is (最新, 讀到, 開頭), on one line, then the row.
    private func labelled(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        GridRow(alignment: .center) {
            Text(label)
                .font(DSFont.footnote)
                .foregroundStyle(DSColor.textSecondary)
                .lineLimit(1)
                .fixedSize()
            content()
        }
    }
}

enum BookDetailChapterTitle {
    /// A chapter's title, or 「第 N 章」 for a source that leaves it empty.
    static func display(_ chapter: OnlineChapterRef, offset: Int) -> String {
        let title = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? String(format: localized("第 %d 章"), offset + 1) : title
    }
}

// MARK: - Remove-from-shelf confirmation

extension View {
    /// Removing a book also deletes its reading record, so it asks first, as Apple
    /// Books asks before removing a book from the library.
    func removeFromShelfConfirmation(
        isPresented: Binding<Bool>,
        onConfirm: @escaping () -> Void
    ) -> some View {
        confirmationDialog(
            localized("要把這本書移出書架嗎？"),
            isPresented: isPresented,
            titleVisibility: .visible
        ) {
            Button(localized("移除書架"), role: .destructive, action: onConfirm)
            Button(localized("取消"), role: .cancel) {}
        } message: {
            Text(localized("這本書的閱讀進度和快取會一起刪除。"))
        }
    }
}

#Preview("詳情頁元件") {
    NavigationStack {
        BookDetailScaffold(
            title: "斗羅大陸",
            compactAction: BookDetailAction(title: "立即閱讀", systemImage: "book.fill", action: {})
        ) {
            BookDetailHero(
                artworkShape: .book,
                cover: BookCoverImage(coverURL: "", title: "斗羅大陸", author: "唐家三少"),
                title: "斗羅大陸",
                author: "唐家三少",
                meta: "",
                primary: BookDetailAction(title: "繼續閱讀", systemImage: "book.fill", detail: "第 12 章", action: {}),
                secondary: BookDetailAction(title: "已在書架", systemImage: "checkmark", action: {}),
                links: ["玄幻", "東方玄幻", "熱血", "穿越", "系統流", "爽文"].map { BookDetailLink(id: $0, title: $0, action: {}) },
                source: BookDetailHeroSource(name: "示範來源配置", switchAction: {}, count: 12,
                                             facts: ["線上", "1,450 章"])
            )
        } content: {
            BookDetailIntroSection(
                text: "唐門外門弟子唐三，因偷學內門絕學為唐門所不容，跳崖明志卻來到了另一個世界——斗羅大陸。這裡沒有魔法，沒有鬥氣，沒有武術，卻有神奇的武魂。",
                isExpanded: .constant(false)
            )
            BookDetailInfoSection(items: [
                BookDetailInfoItem(id: "wordCount", label: "字數", value: "298萬字"),
                BookDetailInfoItem(id: "chapters", label: "章節", value: "1,450"),
                BookDetailInfoItem(id: "format", label: "格式", value: "EPUB", choice: BookDetailInfoChoice(
                    options: [.init(id: "epub", title: "EPUB"), .init(id: "pdf", title: "PDF")],
                    selection: .constant("epub"))),
            ])
        }
    }
}

#Preview("詳情頁・書源接手點擊") {
    NavigationStack {
        BookDetailScaffold(
            title: "沒錢修什麼仙",
            compactAction: BookDetailAction(title: "立即閱讀", systemImage: "book.fill", action: {})
        ) {
            BookDetailHero(
                artworkShape: .book,
                cover: BookCoverImage(coverURL: "", title: "沒錢修什麼仙", author: "熊狼狗"),
                title: "沒錢修什麼仙",
                author: "熊狼狗",
                meta: "仙俠 · 修真文明",
                primary: BookDetailAction(title: "立即閱讀", systemImage: "book.fill", action: {}),
                secondary: BookDetailAction(title: "加入書架", systemImage: "plus", action: {}),
                sourceGestures: BookDetailSourceGestures(
                    labels: ["仙俠", "修真文明"],
                    tapName: {}, longPressName: {}, tapAuthor: {}, longPressAuthor: {},
                    tapLabel: { _ in }, longPressLabel: { _ in }
                )
            )
        } content: {
            EmptyView()
        }
    }
}

/// 作品詳情 with no version to read: its 目錄 says so (maintainer, 2026-10-22).
#Preview("詳情頁・目錄・沒有可閱讀的來源") {
    BookDetailChapterSection(
        title: localized("目錄"), chapters: [], isLoading: false, errorMessage: nil, latestChapter: "",
        onRetry: {}, onShowAll: {}, emptyText: localized("目前沒有可閱讀的來源")
    ) { _, _ in EmptyView() }
}

/// The design's baseline (maintainer, 2026-10-12): a book with nothing but its title and author —
/// no cover, no genres, no description — must still look finished.
#Preview("詳情頁・最少資料") {
    NavigationStack {
        BookDetailScaffold(
            title: "無名之書",
            compactAction: BookDetailAction(title: "開始閱讀", systemImage: "book", action: {})
        ) {
            BookDetailHero(
                artworkShape: .book,
                cover: GeneratedBookCover(title: "無名之書", author: "佚名"),
                title: "無名之書",
                author: "佚名",
                meta: "",
                primary: BookDetailAction(title: "開始閱讀", systemImage: "book", action: {}),
                secondary: BookDetailAction(title: "加入書架", systemImage: "plus", action: {}),
                source: BookDetailHeroSource(name: "示範來源配置", facts: ["線上"])
            )
        } content: {
            BookDetailChapterSection(
                title: localized("目錄"), chapters: [], isLoading: true, errorMessage: nil, latestChapter: "第 3 章",
                onRetry: {}, onShowAll: {}, preview: .latestAndResume(resumeIndex: nil)
            ) { _, _ in EmptyView() }
            BookDetailInfoSection(items: [BookDetailInfoItem(id: "language", label: "語言", value: "中文")])
        }
    }
}

/// #57: a source's own CSS spaces its lines apart from ours; collapsed, the intro ends on a whole line.
#Preview("詳情頁・HTML 簡介收合") {
    @Previewable @State var isExpanded = false
    ScrollView {
        BookDetailIntroSection(
            text: """
            <usehtml><h4 style="margin:0 0 10px;font-size:20px;line-height:36px;border-left:4px solid #e33;padding-left:8px">作品簡介</h4>\
            <p style="margin:0;line-height:30px">標籤：系統+穿越+爽文+癲+單女主+序列收容+克系+群像+輕鬆+日常+腦洞+無敵流+種田+經營+搞笑+熱血</p></usehtml>
            """,
            isExpanded: $isExpanded
        )
    }
}
