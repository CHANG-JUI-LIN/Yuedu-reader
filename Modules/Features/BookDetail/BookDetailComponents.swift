import SwiftUI

// MARK: - Book detail building blocks
//
// The detail pages are laid out as Apple Books lays out a book and Apple Podcasts a
// show: the artwork centred over a faint wash of its hue, the title and author under it,
// the primary action directly beneath, then the description, the chapter list and the
// information strip. Every detail page composes these pieces; none draws its own copy.

/// One action button on a detail page.
struct BookDetailAction {
    var title: String
    var systemImage: String
    var isBusy = false
    var isEnabled = true
    /// Where reading resumes, in grey after the title: 「第 12 章」 or 「已讀 32%」
    /// (`BookDetailResume`). Read by VoiceOver as the button's value.
    var detail: String? = nil
    var action: () -> Void
}

struct BookDetailAuthorAction: Identifiable {
    let id: String
    let name: String
    let action: () -> Void
}

/// A genre, series or subject under the title, as plain text that leads somewhere: the
/// way Apple Books' editorial pages link, not a row of coloured tags.
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.bookDetailEmbedding) private var embedding
    /// Whether the hero has scrolled up under the navigation bar. Stored as the crossing
    /// itself: it used to be the hero's bottom edge, written on every frame of a scroll, and
    /// each write re-ran this scaffold and its toolbar though only the crossing is read.
    @State private var heroScrolledAway = false
    /// Top edge of the visible scroll area (below the navigation bar), in global coordinates.
    @State private var visibleTop: CGFloat = 0

    init(title: String, compactAction: BookDetailAction, onRefresh: (() async -> Void)? = nil,
         @ViewBuilder hero: () -> Hero, @ViewBuilder content: () -> Content,
         @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.compactAction = compactAction
        self.onRefresh = onRefresh
        self.hero = hero()
        self.content = content()
        self.actions = actions()
    }

    var body: some View {
        if embedding != nil {
            stack.frame(maxWidth: .infinity)
        } else {
            ScrollView { stack }
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.frame(in: .global).minY + proxy.safeAreaInsets.top
                } action: { visibleTop = $0 }
                .modifier(BookDetailRefreshModifier(onRefresh: onRefresh))
                // iOS 26's soft top edge fades whatever scrolls under the navigation bar into
                // the page background — it turned the cover wash under the bar into a flat
                // band. The cover shows through while it is on screen; once it has scrolled
                // away the edge effect returns to keep the bar's title and button legible.
                .softScrollEdges(hidingTop: !heroScrolledAway)
                .scrollIndicators(.hidden)
                .background(PageBackgroundView(scope: .global).ignoresSafeArea())
                .pageBackgroundToolbar(for: .global)
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
                        // Over the hero, whose cover wash runs up behind it.
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
         @ViewBuilder hero: () -> Hero, @ViewBuilder content: () -> Content) {
        self.init(title: title, compactAction: compactAction, onRefresh: onRefresh,
                  hero: hero, content: content, actions: { EmptyView() })
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

/// The bar's glass on iOS 26, tinted with the card; older systems have no glass, so
/// the tint lies over `.regularMaterial`. The `#if compiler` guard mirrors
/// `FrostedGlassBackground`.
private struct CardButtonGlass: ViewModifier {
    let tint: Color

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.tint(tint.opacity(DSLayout.cardHeaderGlassTintOpacity)).interactive(), in: Capsule())
        } else {
            legacy(content)
        }
        #else
        legacy(content)
        #endif
    }

    private func legacy(_ content: Content) -> some View {
        content
            .background(tint.opacity(DSLayout.cardHeaderGlassTintOpacity), in: Capsule())
            .background(.regularMaterial, in: Capsule())
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

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.bookDetailEmbedding) private var embedding
    @Bindable private var settings = GlobalSettings.shared
    @ObservedObject private var subscriptions = SubscriptionStore.shared
    /// The hue of the cover on screen, as its view reports it; nil until then, for a cover
    /// with no bitmap (a generated one) and for a grey one (`CoverTint.wash`).
    @State private var wash: CoverTint.Wash?

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
                .padding(.top, isCard ? DSLayout.cardCarouselCoverTitleSpacing : DSSpacing.lg)
            actions
                .padding(.top, DSSpacing.lg)
        }
        .padding(.horizontal, DSSpacing.lg)
        // On a card the cover sits where Apple Books puts it, under the card's header.
        .padding(.top, isCard ? DSLayout.cardCarouselCoverTop - DSSpacing.lg - DSLayout.minimumTapTarget : DSSpacing.lg)
        .padding(.bottom, isCard ? DSLayout.cardCarouselTopBottomPadding : 0)
        // In a widening card the text keeps its width; only the wash grows with it.
        .frame(maxWidth: embedding?.contentWidth ?? .infinity)
        .frame(maxWidth: .infinity)
        .background(alignment: .top) {
            if let tone = embedding?.tone { cardTop(tone) } else { backdrop }
        }
    }

    /// In a carousel card: the cover's colours fill the card's top, running up behind
    /// the header (the card clips it to its rounded top).
    private func cardTop(_ tone: BookDetailCardTone) -> some View {
        GeometryReader { proxy in
            let extensionHeight = DSLayout.bookDetailBackdropTopExtension
            LinearGradient(colors: [tone.top, tone.bottom], startPoint: .top, endPoint: .bottom)
                .frame(width: proxy.size.width, height: proxy.size.height + extensionHeight)
                .offset(y: -extensionHeight)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var isCard: Bool { embedding != nil }

    private var primaryText: Color { embedding?.tone.ink ?? DSColor.textPrimary }
    private var secondaryText: Color {
        embedding.map { $0.tone.ink.opacity(DSLayout.cardSecondaryTextOpacity) } ?? DSColor.textSecondary
    }

    private var artwork: some View {
        let shape = RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous)
        return cover
            .environment(\.coverImageObserver, { image in
                Task {
                    let found = await Task.detached(priority: .utility) {
                        CoverTint.average(of: image).flatMap(CoverTint.wash(for:))
                    }.value
                    if found != wash { wash = found }
                }
            })
            .frame(width: artworkSize.width, height: artworkSize.height)
            .clipShape(shape)
            .overlay(shape.stroke(DSColor.separator, lineWidth: 0.5))
            .shadow(
                color: DSColor.bookDetailCoverShadow,
                radius: DSLayout.bookDetailCoverShadowRadius,
                y: DSLayout.bookDetailCoverShadowOffsetY
            )
            // The title below names the book; the artwork would only repeat it.
            .accessibilityHidden(true)
    }

    private var titleBlock: some View {
        VStack(spacing: DSSpacing.xs) {
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
                    .font(DSFont.subheadline)
                    .foregroundStyle(secondaryText)
                    .lineLimit(1)
                    .sourceGesture(
                        tap: gestures.tapAuthor, longPress: gestures.longPressAuthor,
                        longPressName: localized("長按作者")
                    )
            } else if authorActions.isEmpty {
                Text(author)
                    .font(DSFont.subheadline)
                    .foregroundStyle(secondaryText)
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
                        .font(DSFont.subheadline)
                        .frame(minHeight: DSLayout.minimumTapTarget)
                    }
                    // A card sets the author line as tight under the title as Apple Books
                    // does; the tap target keeps its height, overlapping the text around it.
                    .padding(.vertical, isCard ? -DSSpacing.md : 0)
                    .buttonStyle(.plain)
                    // Quiet, as the author line is when it leads nowhere; the chevron says it does.
                    .foregroundStyle(secondaryText)
                    .accessibilityIdentifier("publicLibrary.author.\(author.id)")
                }
            }
            if let gestures = sourceGestures, !gestures.labels.isEmpty {
                // One tappable label each, so the source learns which one (legado `clickBookLabel`).
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
                .padding(.top, isCard ? DSSpacing.md : 0)
            } else if !links.isEmpty {
                linkLine
                    .padding(.top, isCard ? DSSpacing.md : 0)
            } else if !meta.isEmpty {
                Text(meta)
                    .font(DSFont.footnote)
                    .foregroundStyle(secondaryText)
                    .lineLimit(2)
                    .padding(.top, isCard ? DSSpacing.md : 0)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    /// One action leads (Editorial Minimalism, 2026-10-12): a quiet grey capsule carrying
    /// only its words, and where reading resumes in grey after them; the second thing to do
    /// (the shelf) is plain text beside it, as the maintainer's 方案 A draws them. Always one
    /// row, at every text size: stacking them is what the maintainer rejected. The second
    /// label keeps its width and the capsule's truncates first.
    private var actions: some View {
        HStack(spacing: DSSpacing.lg) {
            primaryButton
            secondaryButton
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        if embedding != nil {
            // Apple Books' 取得: white whatever the card's colour, and the same white
            // while the page loads, so paging between cards never changes it.
            Button(action: primary.action) {
                BookDetailActionLabel(action: primary, progressTint: DSColor.cardPrimaryActionLabel)
            }
            .buttonStyle(BookDetailCardActionStyle(fill: DSColor.cardPrimaryActionFill, label: DSColor.cardPrimaryActionLabel))
            .disabled(!primary.isEnabled || primary.isBusy)
        } else {
            Button(action: primary.action) {
                BookDetailCalmActionLabel(action: primary)
            }
            // Neutral, not the accent: the page's colour belongs to the book.
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .tint(DSColor.textSecondary)
            .disabled(!primary.isEnabled || primary.isBusy)
            .accessibilityLabel(primary.title)
            .accessibilityValue(primary.detail ?? "")
        }
    }

    @ViewBuilder
    private var secondaryButton: some View {
        if let secondary { secondaryButton(secondary) }
    }

    @ViewBuilder
    private func secondaryButton(_ secondary: BookDetailAction) -> some View {
        if let tone = embedding?.tone {
            // Apple Books' card: the card's ink over a light veil of itself.
            Button(action: secondary.action) {
                BookDetailActionIcon(action: secondary, progressTint: tone.ink)
                    .frame(width: DSLayout.cardActionHeight, height: DSLayout.cardActionHeight)
            }
            .buttonStyle(BookDetailCardActionStyle(fill: tone.ink.opacity(DSLayout.cardSecondaryActionFillOpacity), label: tone.ink))
            .disabled(!secondary.isEnabled || secondary.isBusy)
            .accessibilityLabel(secondary.title)
        } else {
            Button(action: secondary.action) {
                HStack(spacing: DSSpacing.xs) {
                    if secondary.isBusy {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(secondary.title)
                        .lineLimit(1)
                }
                .font(DSFont.body)
                .frame(minHeight: DSLayout.minimumTapTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .tint(DSColor.textPrimary)
            .fixedSize()
            .layoutPriority(1)
            .disabled(!secondary.isEnabled || secondary.isBusy)
        }
    }

    /// Genres as centred plain text, each one its own button, wrapping onto more lines.
    private var linkLine: some View {
        // Each link's chevron ends it, so space alone separates them; a separator of its own
        // could be left at the end or start of a wrapped row.
        WrappingFlowLayout(spacing: DSSpacing.md, alignment: .center) {
            ForEach(links) { link in
                // Plain, quiet text with the chevron that says it leads somewhere.
                Button(action: link.action) {
                    HStack(spacing: DSSpacing.xxs) {
                        Text(link.title)
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(DSFont.caption2.weight(.semibold))
                            .accessibilityHidden(true)
                    }
                    .font(DSFont.footnote)
                    .foregroundStyle(secondaryText)
                    .frame(minHeight: DSLayout.minimumTapTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(link.hint ?? localized("顯示這個分類的作品"))
                .accessibilityIdentifier("detail.link.\(link.id)")
            }
        }
        // The 44pt tap targets would push the line apart; the text keeps its rhythm.
        .padding(.vertical, -DSSpacing.md)
    }

    /// The cover's hue as a faint wash behind the hero, fading into the page: never the
    /// cover itself blurred, which turned a dull cover into grey haze. It runs up past the
    /// hero's own top edge, under the navigation and status bars, so the bars float over it
    /// instead of ending it as a band. A cover with no hue — a generated one, a grey one —
    /// leaves the page background as it is, and so do a theme's page picture (it owns the
    /// background), Reduce Transparency and Increase Contrast.
    @ViewBuilder
    private var backdrop: some View {
        if let wash, !reduceTransparency, contrast != .increased,
           PageBackgroundView.slice(for: .global, colorScheme: colorScheme, settings: settings,
                                    subscriptions: subscriptions) == nil {
            GeometryReader { proxy in
                let extensionHeight = DSLayout.bookDetailBackdropTopExtension
                LinearGradient(
                    stops: [
                        .init(color: wash.color(dark: colorScheme == .dark), location: 0),
                        .init(color: wash.color(dark: colorScheme == .dark),
                              location: DSLayout.bookDetailBackdropFadeStart),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(width: proxy.size.width, height: proxy.size.height + extensionHeight)
                .offset(y: -extensionHeight)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// A carousel card's action, as Apple Books draws its store card's: a flat capsule
/// whose colours do not change when the action is unavailable, so a card does not
/// flicker as its page loads. Whether it can be pressed is still announced.
private struct BookDetailCardActionStyle: ButtonStyle {
    let fill: Color
    let label: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(label)
            .frame(minHeight: DSLayout.cardActionHeight)
            .background(fill, in: Capsule())
            .opacity(configuration.isPressed ? DSLayout.cardActionPressedOpacity : 1)
    }
}

private struct BookDetailActionLabel: View {
    let action: BookDetailAction
    let progressTint: Color

    var body: some View {
        // The icon goes first when the title does not fit beside it; the title then truncates.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DSSpacing.sm) {
                leading
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

/// A detail page's primary action as 方案 A draws it: its words alone, no icon, and where
/// reading resumes in grey after them — 「繼續閱讀　第 12 章」. The resume point goes first
/// when both do not fit; the title then truncates. Busy, a spinner takes the icon's place.
private struct BookDetailCalmActionLabel: View {
    let action: BookDetailAction
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(showsDetail: true)
            row(showsDetail: false)
        }
        .frame(maxWidth: .infinity)
    }

    private func row(showsDetail: Bool) -> some View {
        HStack(spacing: DSSpacing.sm) {
            if action.isBusy {
                ProgressView()
                    .controlSize(.small)
            }
            Text(action.title)
                .font(DSFont.body.weight(.semibold))
                .foregroundStyle(isEnabled ? DSColor.textPrimary : DSColor.textTertiary)
            if showsDetail, let detail = action.detail {
                Text(detail)
                    .font(DSFont.body)
                    .foregroundStyle(DSColor.textSecondary)
                    .monospacedDigit()
            }
        }
        .lineLimit(1)
    }
}

/// The icon of a secondary action drawn as a circle; the title is its accessibility label.
private struct BookDetailActionIcon: View {
    let action: BookDetailAction
    let progressTint: Color

    var body: some View {
        Group {
            if action.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .tint(progressTint)
            } else {
                Image(systemName: action.systemImage)
                    .font(DSFont.body.weight(.semibold))
            }
        }
        .accessibilityHidden(true)
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

    /// The current source, opening 換源. 來源 is what the item is, the source name its
    /// value, switching what activating it does; the visible 「換源」 stays reachable
    /// to Voice Control through the input labels.
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

/// 作品資訊: the copy's facts as Apple Books lists a book's Information — a titled section
/// at the foot of the page, one label and value per row, hairlines between. It replaced the
/// strip of columns under the hero (Editorial Minimalism, 2026-10-12), which gave chapter
/// counts and source names the weight of the work itself.
struct BookDetailInfoSection: View {
    let items: [BookDetailInfoItem]

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                BookDetailSectionHeader(title: localized("作品資訊"))
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider() }
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
        HStack(alignment: .firstTextBaseline, spacing: DSSpacing.md) {
            Text(item.label)
                .foregroundStyle(DSColor.textSecondary)
            Spacer(minLength: DSSpacing.md)
            VStack(alignment: .trailing, spacing: 2) {
                // A choice or link without a detail line ends its value with the chevron, on
                // the same line, as a Settings menu row does.
                HStack(alignment: .firstTextBaseline, spacing: DSSpacing.xs) {
                    Text(item.value)
                        .foregroundStyle(DSColor.textPrimary)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
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
                    .foregroundStyle(item.isInteractive ? DSColor.accent : DSColor.textSecondary)
                    .lineLimit(1)
                }
            }
        }
        .font(DSFont.subheadline)
        .padding(.vertical, DSSpacing.sm)
        .frame(minHeight: DSLayout.minimumTapTarget)
    }
}

// MARK: - Section header

/// A section title in Apple's store style, with an optional trailing 「查看全部」.
struct BookDetailSectionHeader<Accessory: View>: View {
    let title: String
    var actionTitle: String?
    var action: (() -> Void)?
    /// Beside the title: 同題材's category menu.
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(DSFont.title3.weight(.bold))
                .foregroundStyle(DSColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
            accessory()
            Spacer(minLength: DSSpacing.sm)
            if let actionTitle, let action {
                Button(action: action) {
                    HStack(spacing: DSSpacing.xs) {
                        Text(actionTitle)
                        Image(systemName: "chevron.right")
                            .font(DSFont.caption.weight(.semibold))
                            .accessibilityHidden(true)
                    }
                    .font(DSFont.subheadline)
                    .foregroundStyle(DSColor.accent)
                    .frame(minHeight: DSLayout.minimumTapTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

extension BookDetailSectionHeader where Accessory == EmptyView {
    init(title: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.init(title: title, actionTitle: actionTitle, action: action, accessory: { EmptyView() })
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
                    .background(DSColor.surfaceTertiary, in: Capsule())
            }
            Text(verbatim: reason)
                .font(DSFont.subheadline)
                .foregroundStyle(DSColor.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, DSSpacing.lg)
    }
}

/// The description, clamped to four lines with Apple's trailing 「更多」.
///
/// Plain intros arrive cleaned by Legado's formatter; `<usehtml>`, `<md>` and
/// `<useweb>` intros keep their markup and render as HTML, Markdown or a web page
/// (`BookIntroContent`). Whether plain text overflows is estimated from its length and
/// line breaks rather than measured: measuring means laying out the full text a second
/// time at its intrinsic height, which `Technotes/iOS17SearchWatchdogPostmortem.md`
/// (guardrail 6) rules out for source-controlled text inside this scroll view on iOS 17.
struct BookDetailIntroSection: View {
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var webContentHeight: CGFloat = 0
    /// Parsed once per intro, never in `body` (guardrail 5).
    @State private var markdown: AttributedString?
    @ScaledMetric(relativeTo: .subheadline) private var collapsedRichHeight: CGFloat = 88

    private static let collapsedLineLimit = 4
    /// Roughly four lines of CJK body text at the default text size on a phone.
    private static let collapsedCharacterEstimate = 80

    private var content: BookIntroContent { readsSourceFormats ? BookIntroContent(text) : .plain(text) }

    private var mayOverflow: Bool {
        switch content {
        case .plain(let plain), .markdown(let plain):
            plain.count > Self.collapsedCharacterEstimate
                || plain.reduce(0) { $1.isNewline ? $0 + 1 : $0 } >= Self.collapsedLineLimit
        case .html, .web:
            webContentHeight > collapsedRichHeight
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            BookDetailSectionHeader(title: localized("簡介"))
            introBody
                .frame(maxWidth: .infinity, alignment: .leading)
            if mayOverflow {
                Button {
                    withAnimation(reduceMotion ? nil : DSAnimation.standard) {
                        isExpanded.toggle()
                    }
                } label: {
                    Text(isExpanded ? localized("收合") : localized("簡介：更多"))
                        .font(DSFont.subheadline.weight(.semibold))
                        .foregroundStyle(DSColor.accent)
                        .frame(minHeight: DSLayout.minimumTapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, DSSpacing.lg)
        .task(id: text) { parseMarkdownIfNeeded() }
    }

    @ViewBuilder
    private var introBody: some View {
        switch content {
        case .plain(let plain):
            Text(plain)
                .font(DSFont.subheadline)
                .foregroundStyle(DSColor.textPrimary)
                .lineLimit(isExpanded ? nil : Self.collapsedLineLimit)
        case .markdown(let source):
            Text(markdown ?? AttributedString(source))
                .font(DSFont.subheadline)
                .foregroundStyle(DSColor.textPrimary)
                .lineLimit(isExpanded ? nil : Self.collapsedLineLimit)
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
            contentHeight: $webContentHeight,
            onAction: onAction
        )
        .frame(height: isExpanded
            ? max(webContentHeight, 1)
            : min(max(webContentHeight, 1), collapsedRichHeight))
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

// MARK: - Chapters

/// One chapter row, used both in the detail preview and in the full chapter list.
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
                        .font(DSFont.body)
                        .foregroundStyle(DSColor.textPrimary)
                        .lineLimit(1)
                }
                Spacer(minLength: DSSpacing.sm)
                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(DSFont.caption)
                        .foregroundStyle(DSColor.warning)
                        .accessibilityHidden(true)
                }
                switch trailing {
                case .disclosure:
                    Image(systemName: "chevron.right")
                        .font(DSFont.caption.weight(.semibold))
                        .foregroundStyle(DSColor.textTertiary)
                        .accessibilityHidden(true)
                case .play:
                    Image(systemName: "play.circle")
                        .font(DSFont.title3)
                        .foregroundStyle(DSColor.accent)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, DSSpacing.md)
            .frame(minHeight: DSLayout.minimumTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isLocked ? localized("付費章節") : "")
    }
}

/// The chapter section: a header with 「查看全部」, the latest chapter, and the first
/// few chapters, with loading, error and empty states in place of the rows.
struct BookDetailChapterSection<Row: View>: View {
    let title: String
    let chapters: [OnlineChapterRef]
    let isLoading: Bool
    let errorMessage: String?
    let latestChapter: String
    let onRetry: () -> Void
    let onShowAll: () -> Void
    @ViewBuilder let row: (_ offset: Int, _ chapter: OnlineChapterRef) -> Row

    /// Enough to show what the list holds; the rest is one tap away, as Podcasts
    /// shows a show's newest few episodes above 「查看全部」.
    static var previewLimit: Int { 5 }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            BookDetailSectionHeader(
                title: title,
                actionTitle: chapters.isEmpty ? nil : localized("查看全部"),
                action: chapters.isEmpty ? nil : onShowAll
            )
            if !latestChapter.isEmpty {
                Label(latestChapter, systemImage: "clock.arrow.circlepath")
                    .font(DSFont.footnote)
                    .foregroundStyle(DSColor.textSecondary)
                    .lineLimit(1)
                    .accessibilityLabel(localized("最新章節"))
                    .accessibilityValue(latestChapter)
            }
            content
        }
        .padding(.horizontal, DSSpacing.lg)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && chapters.isEmpty {
            ProgressView(localized("載入目錄…"))
                .frame(maxWidth: .infinity)
                .padding(.vertical, DSSpacing.xl)
        } else if let errorMessage, chapters.isEmpty {
            VStack(spacing: DSSpacing.sm) {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(DSFont.footnote)
                    .foregroundStyle(DSColor.textSecondary)
                    .multilineTextAlignment(.center)
                Button(localized("重試"), action: onRetry)
                    .buttonStyle(.bordered)
                    .tint(DSColor.accent)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DSSpacing.lg)
        } else if chapters.isEmpty {
            Text(localized("目錄為空"))
                .font(DSFont.subheadline)
                .foregroundStyle(DSColor.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DSSpacing.lg)
        } else {
            let preview = Array(chapters.prefix(Self.previewLimit).enumerated())
            VStack(spacing: 0) {
                ForEach(preview, id: \.element.id) { offset, chapter in
                    if offset > 0 { Divider() }
                    row(offset, chapter)
                }
            }
        }
    }
}

/// The full chapter list, presented from 「查看全部」.
struct BookDetailChapterListSheet: View {
    let chapters: [OnlineChapterRef]
    let trailing: BookDetailChapterRow.Trailing
    /// Called with the chapter's offset in `chapters`.
    let onSelect: (_ offset: Int) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                ForEach(Array(chapters.enumerated()), id: \.element.id) { offset, chapter in
                    BookDetailChapterRow(
                        title: BookDetailChapterTitle.display(chapter, offset: offset),
                        isLocked: chapter.isVip || chapter.isPay,
                        trailing: trailing,
                        action: { onSelect(offset) }
                    )
                    .listRowBackground(Color.clear)
                }
            } header: {
                Text(String(format: localized("共 %d 章"), chapters.count))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(PageBackgroundView(scope: .global).ignoresSafeArea())
        .pageBackgroundToolbar(for: .global)
        .navigationTitle(localized("目錄"))
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Label(localized("關閉"), systemImage: "xmark")
                        .labelStyle(.iconOnly)
                }
            }
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
                secondary: BookDetailAction(title: "移除書架", systemImage: "checkmark", action: {}),
                links: ["玄幻", "東方玄幻", "熱血", "穿越", "系統流", "爽文"].map { BookDetailLink(id: $0, title: $0, action: {}) }
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
                .source(name: "示範來源配置") {},
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
                secondary: BookDetailAction(title: "加入書架", systemImage: "plus", action: {})
            )
        } content: {
            BookDetailInfoSection(items: [.source(name: "示範來源配置") {}])
        }
    }
}
