import SwiftUI

// MARK: - Book detail building blocks
//
// The online-book and audiobook detail pages are laid out as Apple Books lays out a
// book and Apple Podcasts a show: the artwork large and centred over a wash of
// itself, the title and author under it, the primary action directly beneath, then
// an information strip, the description, and the chapter list. Both pages compose
// these pieces; neither draws its own copy.

/// One action button on a detail page.
struct BookDetailAction {
    var title: String
    var systemImage: String
    var isBusy = false
    var isEnabled = true
    var action: () -> Void
}

struct BookDetailAuthorAction: Identifiable {
    let id: String
    let name: String
    let action: () -> Void
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
                            Button(action: compactAction.action) {
                                Text(compactAction.title)
                                    .font(DSFont.subheadline.weight(.semibold))
                            }
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.capsule)
                            .controlSize(.small)
                            .tint(DSColor.accent)
                            .disabled(!compactAction.isEnabled || compactAction.isBusy)
                            .transition(.opacity)
                        }
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) { actions }
                }
                .animation(reduceMotion ? nil : DSAnimation.fast, value: heroScrolledAway)
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
    let secondary: BookDetailAction
    var authorActions: [BookDetailAuthorAction] = []
    var artworkHeight: CGFloat? = nil
    /// Taps a book source handles through its `callBackJs` (legado `SourceCallBack`); nil
    /// for every book whose source does not listen, which keeps the title block as it was.
    var sourceGestures: BookDetailSourceGestures? = nil

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.bookDetailEmbedding) private var embedding

    private var artworkSize: CGSize {
        switch artworkShape {
        case .book:
            CGSize(width: artworkHeight.map { $0 * DSLayout.discoverCoverAspectRatio } ?? DSLayout.bookCoverHeroWidth,
                   height: artworkHeight ?? DSLayout.bookCoverHeroHeight)
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
            .frame(width: artworkSize.width, height: artworkSize.height)
            .clipShape(shape)
            .overlay(shape.stroke(DSColor.separator, lineWidth: 0.5))
            .shadow(
                color: DSColor.coverHeroShadow,
                radius: DSLayout.bookCoverHeroShadowRadius,
                y: DSLayout.bookCoverHeroShadowOffsetY
            )
            // The title below names the book; the artwork would only repeat it.
            .accessibilityHidden(true)
    }

    private var titleBlock: some View {
        VStack(spacing: DSSpacing.xs) {
            Text(title)
                .font(DSFont.title2.weight(.bold))
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
                    .foregroundStyle(embedding?.tone.ink ?? DSColor.accent)
                    .accessibilityIdentifier("publicLibrary.author.\(author.id)")
                }
            }
            if let gestures = sourceGestures, !gestures.labels.isEmpty {
                // One tappable label each, so the source learns which one (legado `clickBookLabel`).
                WrappingFlowLayout(spacing: DSSpacing.sm) {
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

    /// Side by side as Apple Books shows them; stacked once the text size no longer
    /// leaves room for both labels on one line.
    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DSSpacing.md) {
                primaryButton
                secondaryButton
            }
            VStack(spacing: DSSpacing.sm) {
                primaryButton
                secondaryButton
            }
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
                BookDetailActionLabel(action: primary, progressTint: DSColor.textOnAccent)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .tint(DSColor.accent)
            .disabled(!primary.isEnabled || primary.isBusy)
        }
    }

    @ViewBuilder
    private var secondaryButton: some View {
        if let tone = embedding?.tone {
            // Apple Books' 試讀: the card's ink over a light veil of itself.
            Button(action: secondary.action) {
                BookDetailActionLabel(action: secondary, progressTint: tone.ink)
            }
            .buttonStyle(BookDetailCardActionStyle(fill: tone.ink.opacity(DSLayout.cardSecondaryActionFillOpacity), label: tone.ink))
            .disabled(!secondary.isEnabled || secondary.isBusy)
        } else {
            Button(action: secondary.action) {
                BookDetailActionLabel(action: secondary, progressTint: DSColor.textPrimary)
            }
            // Neutral, so the accent belongs to the one primary action beside it.
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .tint(DSColor.textPrimary)
            .disabled(!secondary.isEnabled || secondary.isBusy)
        }
    }

    /// The artwork blurred into a wash behind the hero, as Apple Books does. It runs
    /// up past the hero's own top edge, under the navigation and status bars, so the
    /// bars float over the wash instead of the page background showing through them
    /// as a band. Purely decorative; Reduce Transparency drops it and the page
    /// background shows instead.
    @ViewBuilder
    private var backdrop: some View {
        if !reduceTransparency {
            GeometryReader { proxy in
                let extensionHeight = DSLayout.bookDetailBackdropTopExtension
                cover
                    .frame(width: proxy.size.width, height: proxy.size.height + extensionHeight)
                    .blur(radius: DSLayout.bookCoverHeroBackdropBlur, opaque: true)
                    .clipped()
                    .saturation(DSLayout.bookCoverHeroBackdropSaturation)
                    .opacity(DSLayout.bookCoverHeroBackdropOpacity)
                    .mask {
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0),
                                .init(color: .black, location: 0.55),
                                .init(color: .clear, location: 1),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
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
        HStack(spacing: DSSpacing.sm) {
            if action.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .tint(progressTint)
            } else {
                Image(systemName: action.systemImage)
                    .accessibilityHidden(true)
            }
            Text(action.title)
                .lineLimit(1)
        }
        .font(DSFont.body.weight(.semibold))
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Information strip

/// One column of the information strip.
struct BookDetailInfoItem: Identifiable {
    let id: String
    let label: String
    let value: String
    /// A second line under the value. Shown in the accent colour when the item acts.
    var detail: String?
    var action: (() -> Void)?
    var accessibilityHint: String?
    var accessibilityInputLabels: [String] = []

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

/// Apple Books' strip of short facts under the hero: equal columns separated by
/// hairlines, scrolling sideways only once the text size no longer fits them.
struct BookDetailInfoStrip: View {
    let items: [BookDetailInfoItem]

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            ViewThatFits(in: .horizontal) {
                row(equalWidths: true)
                ScrollView(.horizontal) {
                    row(equalWidths: false)
                }
                .scrollIndicators(.hidden)
            }
            .padding(.vertical, DSSpacing.md)
            Divider()
        }
        .padding(.horizontal, DSSpacing.lg)
    }

    private func row(equalWidths: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Divider()
                }
                cell(item)
                    .frame(maxWidth: equalWidths ? .infinity : nil)
                    .padding(.horizontal, DSSpacing.sm)
            }
        }
        .fixedSize(horizontal: !equalWidths, vertical: true)
    }

    @ViewBuilder
    private func cell(_ item: BookDetailInfoItem) -> some View {
        if let action = item.action {
            Button(action: action) {
                cellContent(item)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.label)
            .accessibilityValue(item.value)
            .accessibilityHint(item.accessibilityHint ?? "")
            .accessibilityInputLabels(item.accessibilityInputLabels + [item.label])
            .accessibilityAddTraits(.isButton)
        } else {
            cellContent(item)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(item.label)
                .accessibilityValue(item.value)
        }
    }

    private func cellContent(_ item: BookDetailInfoItem) -> some View {
        VStack(spacing: DSSpacing.xs) {
            Text(item.label)
                .font(DSFont.caption)
                .foregroundStyle(DSColor.textSecondary)
            Text(item.value)
                .font(DSFont.headline)
                .foregroundStyle(DSColor.textPrimary)
                .lineLimit(1)
            if let detail = item.detail {
                HStack(spacing: DSSpacing.xs) {
                    Text(detail)
                    if item.action != nil {
                        Image(systemName: "chevron.right")
                            .font(DSFont.caption2.weight(.semibold))
                    }
                }
                .font(DSFont.caption)
                .foregroundStyle(item.action == nil ? DSColor.textSecondary : DSColor.accent)
                .lineLimit(1)
            }
        }
        .frame(minHeight: DSLayout.minimumTapTarget)
    }
}

// MARK: - Section header

/// A section title in Apple's store style, with an optional trailing 「查看全部」.
struct BookDetailSectionHeader: View {
    let title: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(DSFont.title3.weight(.bold))
                .foregroundStyle(DSColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
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

// MARK: - Description

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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var webContentHeight: CGFloat = 0
    /// Parsed once per intro, never in `body` (guardrail 5).
    @State private var markdown: AttributedString?
    @ScaledMetric(relativeTo: .subheadline) private var collapsedRichHeight: CGFloat = 88

    private static let collapsedLineLimit = 4
    /// Roughly four lines of CJK body text at the default text size on a phone.
    private static let collapsedCharacterEstimate = 80

    private var content: BookIntroContent { BookIntroContent(text) }

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
                    Text(isExpanded ? localized("收合") : localized("更多"))
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
                meta: "玄幻 · 東方玄幻 · 熱血",
                primary: BookDetailAction(title: "立即閱讀", systemImage: "book.fill", action: {}),
                secondary: BookDetailAction(title: "加入書架", systemImage: "plus", action: {})
            )
        } content: {
            BookDetailInfoStrip(items: [
                BookDetailInfoItem(id: "wordCount", label: "字數", value: "298萬字"),
                BookDetailInfoItem(id: "chapters", label: "章節", value: "1,450"),
                .source(name: "示範來源配置") {},
            ])
            BookDetailIntroSection(
                text: "唐門外門弟子唐三，因偷學內門絕學為唐門所不容，跳崖明志卻來到了另一個世界——斗羅大陸。這裡沒有魔法，沒有鬥氣，沒有武術，卻有神奇的武魂。",
                isExpanded: .constant(false)
            )
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
