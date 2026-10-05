import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: BookStore
    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Bold Text: `.bold` while it is on. The global font needs telling; the system font
    /// follows it by itself.
    @Environment(\.legibilityWeight) private var legibilityWeight
    @ObservedObject private var gs = GlobalSettings.shared
    @StateObject private var rssStore = RSSStore.shared
    @ObservedObject private var importDrainer = SharedImportQueueDrainer.shared
    @StateObject private var nowPlaying = NowPlayingHub.shared
    /// Whether any screen is hiding the tab bar — answered from every tab, not only the
    /// screen's own (`RootTabBarVisibility`).
    @StateObject private var rootTabBar = RootTabBarVisibility()
    @State private var selectedRootTab: RootTabItem = .bookshelf
    /// A keyword a book source's discover page handed back via `java.searchBook`.
    /// Presented as a sheet rather than by switching to the 搜尋 tab: that tab is
    /// user-hideable (`gs.visibleRootTabs`), so selecting it would do nothing at all
    /// for anyone who turned it off — and a fresh sheet also lets `initialQuery` run
    /// on appear, which an already-visited tab would not.
    @State private var sourceSearchRequest: SourceSearchRequest?

    struct SourceSearchRequest: Identifiable {
        let id = UUID()
        let keyword: String
    }

    private var rssUnreadCount: Int {
        rssStore.totalUnreadCount()
    }

    private var effectiveColorScheme: ColorScheme {
        gs.effectiveAppearanceColorScheme(systemColorScheme: colorScheme)
    }

    /// The one `.preferredColorScheme` in the app: an outer one overrides any a screen sets
    /// for itself, so 外觀主題's preview has to come through here too.
    private var preferredAppearanceColorScheme: ColorScheme? {
        gs.appearanceWindowColorScheme
    }

    /// The theme on screen, nil for 默認: the surfaces and the tint wear the same one.
    /// (The tint used to skip the launch-time optimism the surfaces had, so a Pro
    /// theme's colours came up under 默認's accent until StoreKit answered.)
    private var appearanceTheme: AppearanceThemePreset? {
        resolvedAppTheme(for: effectiveColorScheme)
    }

    /// The theme whose surface colors should retint the whole app, or nil for
    /// system colors. Both appearances retint: `appearanceTheme(for:)` hands back
    /// the theme's light palette in light mode and its derived dark palette in
    /// dark mode, so dark mode is the theme's dark version rather than plain
    /// system black. Classic = no override.
    ///
    /// On cold launch the entitlement is still being read, and a Pro user's theme is
    /// worn optimistically until it is — see `GlobalSettings.appThemeOnScreen`. The
    /// optimism used to last as long as `hasAccess` was false, so a user without Pro
    /// kept a Pro theme for good (2026-09-29).
    private func resolvedAppTheme(for scheme: ColorScheme) -> AppearanceThemePreset? {
        gs.appThemeOnScreen(
            for: scheme,
            isProActive: subscriptionStore.hasAccess(.readerThemePacks),
            hasResolvedEntitlements: subscriptionStore.hasResolvedEntitlements
        )
    }

    /// Both appearances, resolved together. `DSColor` turns these into dynamic colors, so
    /// the palette is chosen by the trait collection at draw time rather than by whichever
    /// appearance happened to be current the last time this ran.
    private var resolvedAppThemes: ActiveAppThemes {
        ActiveAppThemes(
            light: resolvedAppTheme(for: .light),
            dark: resolvedAppTheme(for: .dark)
        )
    }

    private var isBoldTextOn: Bool { legibilityWeight == .bold }

    /// Where the tab bar sits: at the bottom on iPhone, and on iPad before iOS 18 or in a
    /// compact width — `.sidebarAdaptable` puts it at the top of a regular-width iPad.
    private var isTabBarAtBottom: Bool {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return true }
        if #available(iOS 18.0, *) { return horizontalSizeClass == .compact }
        return true
    }

    /// The global font as drawn: while Bold Text is on, a font with no bold face gives
    /// way to the system font (`GlobalAppTypography.effectivePostScriptName`).
    private var drawnGlobalFont: String? {
        GlobalAppTypography.effectivePostScriptName(gs.resolvedGlobalFontPostScript, boldText: isBoldTextOn)
    }

    private var typographyRefreshID: String {
        "\(drawnGlobalFont ?? "system")|\(dynamicTypeSize)|\(isBoldTextOn)"
    }

    var body: some View {
        // For what reads the themes outside a view's colours (whether a page background
        // hides the bar material, the 光暈 tint) — `DSColor` reads the environment value
        // set at the end of this chain. A plain global, not SwiftUI state, so assigning
        // it here is side-effect free as far as invalidation goes.
        AppearanceThemePreset.activeAppThemes = resolvedAppThemes
        GlobalAppTypography.activate(postScriptName: drawnGlobalFont, boldText: isBoldTextOn)
        return tabView
        .environment(\.rootTabBarVisibility, rootTabBar)
        // The tab bar shows on the selected tab's root page only, where it sits at the
        // bottom (`RootTabBarVisibility`).
        .onChange(of: selectedRootTab, initial: true) { _, tab in
            rootTabBar.setSelectedTab(tab.rawValue)
            // 外觀主題's 淺色／深色 preview is for 外觀主題; another tab is not previewing.
            gs.endAppearanceSlotPreview()
        }
        .onChange(of: isTabBarAtBottom, initial: true) { _, atBottom in
            rootTabBar.setHidesOverCoveredRoot(atBottom)
        }
        // Classic (默認) = the app's original look: no tint override at all.
        .tint(appearanceTheme?.accentColor)
        .accentColor(appearanceTheme?.accentColor)
        .preferredColorScheme(preferredAppearanceColorScheme)
        // While 單獨設定深色主題 is on, the appearance on screen picks whose theme is worn.
        // Not in the background, where the light／dark is the app-switcher snapshots';
        // the scene coming back hands over the appearance it comes back to.
        .onChange(of: effectiveColorScheme, initial: true) { _, scheme in
            gs.noteAppearanceOnScreen(scheme, in: scenePhase)
        }
        .onChange(of: scenePhase) { _, phase in
            gs.noteAppearanceOnScreen(effectiveColorScheme, in: phase)
        }
        .font(DSFont.body)
        .overlay {
            // App-wide audiobook mini-player: controls the long-lived audiobook session
            // from any tab. Naturally hidden while a full-screen reader/player is presented.
            // No reader toolbar here, so allow dragging down to just above the tab bar.
            NowPlayingMiniPlayer(placement: .global, minBottomClearance: 90)
        }
        .iPadAdaptiveRootTabStyle()
        .rootTabBarMinimizeStyle()
        .background {
            ImportedBookPresentation(
                request: importDrainer.lastOutcome == nil ? importDrainer.readerRequest : nil,
                store: store,
                subscriptionStore: subscriptionStore,
                didPresent: importDrainer.didPresentReader(requestID:),
                customizationRequest: importDrainer.lastOutcome == nil ? importDrainer.customizationRequest : nil,
                didPresentCustomization: importDrainer.didPresentCustomization(requestID:),
                readCustomization: { [importDrainer] document in
                    try await importDrainer.trackingCustomizationRead {
                        try await SharedCustomizationImportService.load(document)
                    }
                }
            )
            .frame(width: 0, height: 0)
        }
        .sheet(
            item: Binding(
                get: {
                    // An outcome alert takes precedence, same ordering as the customization
                    // handoff above.
                    importDrainer.lastOutcome == nil ? importDrainer.bookSourceReviewRequest : nil
                },
                set: { request in
                    guard request == nil,
                          let id = importDrainer.bookSourceReviewRequest?.id else { return }
                    importDrainer.didPresentBookSourceReview(requestID: id)
                }
            )
        ) { request in
            BookSourceImportReviewHost(
                sources: request.sources,
                onFinish: { count in
                    importDrainer.didPresentBookSourceReview(requestID: request.id)
                    // Report through the drainer's own alert rather than a second mechanism.
                    importDrainer.lastOutcome = SharedImportQueueDrainer.Outcome(
                        importedCount: count,
                        failureCount: 0,
                        importedBookSourceCount: count
                    )
                },
                onCancel: {
                    importDrainer.didPresentBookSourceReview(requestID: request.id)
                }
            )
        }
        .overlay(alignment: .bottom) {
            if importDrainer.activeImportCount > 0 {
                ProgressView(localized("匯入中，請稍候…"))
                    .padding(DSSpacing.md)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DSRadius.md))
                    .padding(DSSpacing.md)
            }
        }
        .alert(
            localized("匯入"),
            isPresented: Binding(
                get: { importDrainer.lastOutcome != nil },
                set: { isPresented in
                    if !isPresented { importDrainer.lastOutcome = nil }
                }
            ),
            presenting: importDrainer.lastOutcome
        ) { _ in
            Button(localized("確定"), role: .cancel) {
                importDrainer.lastOutcome = nil
            }
        } message: { outcome in
            Text(Self.sharedImportMessage(for: outcome))
        }
        // Screens that set a font of their own redraw with the new weight, as they do
        // when the global font changes; the root `.font` above reaches the rest.
        .onChange(of: isBoldTextOn) { _, _ in
            gs.typographyDidChange()
        }
        .task(id: typographyRefreshID) {
            await MainActor.run {
                GlobalAppTypographyUIKitBridge.apply(
                    postScriptName: drawnGlobalFont
                )
            }
        }
        .onAppear {
            selectedRootTab = gs.fallbackRootTab(for: selectedRootTab)
            #if DEBUG
            // Pairs with `-open-diagnostics` in `SettingsView`: land on 設定 so the
            // pushed diagnostics page can be screenshotted straight from launch.
            if ProcessInfo.processInfo.arguments.contains("-open-diagnostics") {
                selectedRootTab = .settings
            }
            #endif
        }
        .onChange(of: gs.rootTabVisibleIDs) { _, _ in
            selectedRootTab = gs.fallbackRootTab(for: selectedRootTab)
        }
        .fullScreenCover(isPresented: $nowPlaying.isPresentingAudiobook) {
            if let bookId = nowPlaying.audiobookBookId {
                if store.books.contains(where: { $0.id == bookId }) {
                    BookReaderView(bookId: bookId)
                        .environmentObject(store)
                } else {
                    AudiobookReaderView(bookId: bookId)
                        .environmentObject(store)
                }
            }
        }
        // Cold-launch splash: sits above every tab/overlay and fades out.
        .overlay {
            LaunchImageSplashOverlay()
        }
        .onReceive(NotificationCenter.default.publisher(for: .bookSourceRequestedSearch)) { note in
            guard let keyword = note.userInfo?["keyword"] as? String,
                  !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }
            sourceSearchRequest = SourceSearchRequest(keyword: keyword)
        }
        .sheet(item: $sourceSearchRequest) { request in
            NavigationStack {
                SearchView(initialQuery: request.keyword)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button { sourceSearchRequest = nil } label: {
                                Image(systemName: "xmark")
                            }
                        }
                    }
            }
        }
        // Outermost, so the sheets and overlays above resolve their colours from it too:
        // `DSColor`'s themed colours read the themes from here when they draw
        // (`AppThemesTrait`), and follow a switch without their views being rebuilt.
        .environment(\.appThemes, resolvedAppThemes)
        // The same for UIKit views outside this environment.
        .onChange(of: resolvedAppThemes, initial: true) { _, themes in
            AppThemesTrait.apply(themes)
        }
    }

    private static func sharedImportMessage(for outcome: SharedImportQueueDrainer.Outcome) -> String {
        let imported = outcome.importedCount
        let failed = outcome.failureCount
        if imported > 0 && failed == 0 {
            return String(format: localized("成功匯入 %d 個項目"), imported)
        } else if imported > 0 {
            return String(
                format: localized("成功匯入 %1$d 個項目，%2$d 個失敗"), imported, failed)
        } else {
            return String(format: localized("%d 個項目匯入失敗"), failed)
        }
    }

    /// The root tab bar is driven by `GlobalSettings` so users can hide pages
    /// and customize tab icon assets without changing the feature screens.
    @ViewBuilder
    private var tabView: some View {
        if #available(iOS 18.0, *) {
            visibleTabsTabView
        } else {
            // iOS 17 invalidates a NavigationStack inside TabView when a sibling
            // tab is removed while that stack is visible. Keep every tab's slot in
            // the hierarchy and use EmptyView for hidden tabs; without `.tabItem`
            // the placeholder reserves the slot without exposing a tab-bar item.
            // Remove this compatibility path when iOS 17 support is dropped.
            stableSlotsTabView
        }
    }

    private var visibleTabsTabView: some View {
        TabView(selection: $selectedRootTab) {
            ForEach(gs.visibleRootTabs) { tab in
                rootTabContent(for: tab)
                    .modifier(ThemedSurfaceBackground(
                        scope: AppearancePageBackgroundScope(rawValue: tab.rawValue) ?? .global,
                        isProActive: subscriptionStore.hasAccess(.readerThemePacks)
                    ))
                    .background { RootTabBarHider(visibility: rootTabBar) }
                    .environment(\.rootTabBarTab, tab.rawValue)
                    .tag(tab)
                    .tabItem {
                        rootTabItemLabel(for: tab)
                    }
                    .badge(tab == .rss && rssUnreadCount > 0 ? Text("\(rssUnreadCount)") : nil)
            }
        }
    }

    private var stableSlotsTabView: some View {
        TabView(selection: $selectedRootTab) {
            ForEach(RootTabItem.allCases) { tab in
                if gs.isRootTabVisible(tab) {
                    rootTabContent(for: tab)
                        .modifier(ThemedSurfaceBackground(
                            scope: AppearancePageBackgroundScope(rawValue: tab.rawValue) ?? .global,
                            isProActive: subscriptionStore.hasAccess(.readerThemePacks)
                        ))
                        .background { RootTabBarHider(visibility: rootTabBar) }
                        .environment(\.rootTabBarTab, tab.rawValue)
                        .tag(tab)
                        .tabItem {
                            rootTabItemLabel(for: tab)
                        }
                        .badge(tab == .rss && rssUnreadCount > 0 ? Text("\(rssUnreadCount)") : nil)
                } else {
                    EmptyView()
                }
            }
        }
    }

    private var shouldHideRootTabLabels: Bool {
        gs.rootTabHidesLabels && horizontalSizeClass == .compact
    }

    private var usesCustomRootTabIconSize: Bool {
        gs.usesCustomRootTabIconSize
    }

    @ViewBuilder
    private func rootTabContent(for tab: RootTabItem) -> some View {
        switch tab {
        case .bookshelf:
            HomeView()
        case .explore:
            BrowserView()
        case .rss:
            RSSListView()
        case .settings:
            SettingsView()
        case .search:
            NavigationStack {
                SearchView(isTabRoot: true)
            }
        }
    }

    @ViewBuilder
    private func rootTabItemLabel(for tab: RootTabItem) -> some View {
        if let renderedIcon = RootTabIconRenderer.customIcon(
            for: tab,
            colorScheme: effectiveColorScheme,
            pointSize: CGFloat(
                gs.usesCustomRootTabIconSize
                    ? gs.rootTabIconSize
                    : GlobalSettings.initialCustomRootTabIconSize
            ),
            settings: gs
        ) {
            if shouldHideRootTabLabels {
                iconOnlyRootTabLabel(titleKey: tab.titleKey) {
                    Image(uiImage: renderedIcon.image)
                        .renderingMode(renderedIcon.isTemplate ? .template : .original)
                }
            } else {
                Image(uiImage: renderedIcon.image)
                    .renderingMode(renderedIcon.isTemplate ? .template : .original)
                Text(localized(tab.titleKey))
            }
        } else if usesCustomRootTabIconSize {
            let renderedIcon = RootTabIconRenderer.systemIcon(
                for: tab,
                pointSize: CGFloat(gs.rootTabIconSize)
            )
            if shouldHideRootTabLabels {
                iconOnlyRootTabLabel(titleKey: tab.titleKey) {
                    Image(uiImage: renderedIcon.image)
                        .renderingMode(.template)
                }
            } else {
                Image(uiImage: renderedIcon.image)
                    .renderingMode(.template)
                Text(localized(tab.titleKey))
            }
        } else if shouldHideRootTabLabels {
            Label(localized(tab.titleKey), systemImage: tab.defaultSystemImage)
                .labelStyle(.iconOnly)
        } else {
            Label(localized(tab.titleKey), systemImage: tab.defaultSystemImage)
        }
    }

    /// Keep the semantic tab title for VoiceOver while asking SwiftUI for its
    /// supported icon-only layout. A bare Image is treated as the image slot of
    /// the normal image-plus-title tab layout on iOS 17, which leaves it too high.
    @ViewBuilder
    private func iconOnlyRootTabLabel<Icon: View>(
        titleKey: String,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        Label {
            Text(localized(titleKey))
        } icon: {
            icon()
        }
        .labelStyle(.iconOnly)
    }
}

/// Retints scrollable Form/List surfaces to the active app theme by hiding the
/// system background and painting the themed page color behind — plus, when the
/// user configured a page background (Pro), the per-scope gradient/image layer.
/// The default palette resolves to the system grouped background, so default users
/// keep the same appearance while the view structure stays stable across updates.
private struct ThemedSurfaceBackground: ViewModifier {
    let scope: AppearancePageBackgroundScope
    let isProActive: Bool
    @ObservedObject private var gs = GlobalSettings.shared
    @Environment(\.colorScheme) private var colorScheme

    /// Custom page background for this tab, with global fallback. Inactive when
    /// the Pro entitlement lapses so backgrounds degrade like themes do.
    private var pageBackgroundSlice: AppearancePageBackgroundSlice? {
        guard isProActive else { return nil }
        return gs.resolvedPageBackgroundSlice(for: scope, colorScheme: colorScheme)
    }

    /// One structure for every state, on purpose.
    ///
    /// An `if/else` over `content` here returns a different branch of
    /// `_ConditionalContent` per state, which gives the tab's whole subtree a new
    /// identity the moment the state flips — and SwiftUI rebuilds a subtree whose
    /// identity changed. That is what popped every pushed screen back to the tab
    /// root ("閃回設定頁") whenever the theme moved between 默認 (no override) and
    /// any real theme, or a page background appeared. Keep `content` wrapped in
    /// exactly one `.background`; branch *inside* it, where an identity change
    /// only costs a redraw of the backdrop.
    func body(content: Content) -> some View {
        let slice = pageBackgroundSlice
        return content.background {
            ZStack {
                // Keep this node present for every appearance. Changing a
                // conditional child here while a reader is directly pushed onto
                // the shelf navigation stack can make SwiftUI reconcile the
                // tab subtree and detach the reader on foreground resume.
                DSColor.groupedBackground
                AppearancePageBackgroundLayerView(slice: slice)
            }
            .ignoresSafeArea()
        }
    }
}

struct NowPlayingMiniPlayer: View {
    /// Where the mini-player lives. `.reader` is the in-reader TTS bar; `.global` is the
    /// app-root bar that controls audiobook playback from any page.
    enum Placement { case reader, global }
    var placement: Placement = .reader

    /// Whether the host reader's top/bottom bars are showing. Only meaningful for
    /// `.reader`: when the bars appear the player lifts above the bottom toolbar; while
    /// they're hidden it may be dragged lower (no toolbar to clear).
    var barsVisible: Bool = true

    @StateObject private var hub = NowPlayingHub.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var offset = CGSize(width: 0, height: 0)
    @State private var dragStartOffset: CGSize?
    @State private var lastDragEndedAt = Date.distantPast
    /// The screen side the player is tucked into, or nil while it shows in full. ✕ stops
    /// playback, so this is the way to get the player out of the way while it keeps
    /// playing. Reset whenever playback ends, so the next session starts in full.
    @State private var dockedSide: DockSide?
    @AccessibilityFocusState private var focusedControl: FocusedControl?

    enum DockSide { case left, right }
    private enum FocusedControl { case collapse, edgeHandle }
    /// Where the player sat before the bars appeared and lifted it above the toolbar.
    /// Kept so it can drop back to that spot once the bars hide again; cleared the moment
    /// the user drags it somewhere new.
    @State private var liftedFromOffsetHeight: CGFloat?
    /// Resting distance of the bar's bottom edge from the screen bottom.
    var defaultBottomClearance: CGFloat = 136
    /// Lowest the bar can be dragged on tab pages (clears the tab bar). `.global` only.
    var minBottomClearance: CGFloat? = nil
    /// Lowest the bar can be dragged in the reader while the bars are hidden (no toolbar).
    var immersiveBottomClearance: CGFloat = 44

    /// How close to the screen bottom the bar may be dragged, by context.
    private var dragFloorClearance: CGFloat {
        switch placement {
        case .global:
            return minBottomClearance ?? defaultBottomClearance
        case .reader:
            return barsVisible ? defaultBottomClearance : immersiveBottomClearance
        }
    }

    /// Max downward drag from the resting position (size-independent: the resting line is
    /// `defaultBottomClearance` and the floor is `dragFloorClearance`).
    private var bottomOffsetLimit: CGFloat {
        defaultBottomClearance - dragFloorClearance
    }

    private var isVisible: Bool {
        switch placement {
        // In the reader, show for this book's TTS *or* a background audiobook.
        case .reader: return hub.isVisible || hub.showsGlobalBar
        case .global: return hub.showsGlobalBar
        }
    }

    var body: some View {
        GeometryReader { proxy in
            if isVisible {
                if let side = dockedSide {
                    edgeHandle(side)
                        .position(edgeHandlePosition(side, in: proxy.size))
                        .transition(edgeHandleTransition(side))
                } else {
                    miniPlayerView(in: proxy.size)
                        .frame(width: contentWidth)
                        .position(position(in: proxy.size))
                        .simultaneousGesture(dragGesture(in: proxy.size))
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.92).combined(with: .opacity))
                }
            }
        }
        .ignoresSafeArea(.keyboard)
        .animation(DSAnimation.standard, value: isVisible)
        .onChange(of: isVisible) { _, visible in
            if !visible { dockedSide = nil }
        }
        .onChange(of: barsVisible) { _, visible in
            withAnimation(reduceMotion ? nil : DSAnimation.readerChrome) {
                if visible {
                    // Bars appeared: lift the player just above the bottom toolbar (only if
                    // it was dragged into that zone), remembering where it sat so it can
                    // drop back once the bars hide again.
                    if offset.height > bottomOffsetLimit {
                        liftedFromOffsetHeight = offset.height
                        offset.height = bottomOffsetLimit
                    }
                } else if let resting = liftedFromOffsetHeight {
                    // Bars hidden again: if we lifted it earlier and the user hasn't moved
                    // it since, return it to its original spot.
                    offset.height = resting
                    liftedFromOffsetHeight = nil
                }
            }
        }
    }

    private func miniPlayerView(in size: CGSize) -> some View {
        HStack(spacing: controlSpacing) {
            Button {
                performTapAction {
                    hub.openPanel()
                }
            } label: {
                leadingArtwork
            }
            .buttonStyle(.plain)
            .accessibilityLabel(nowPlayingLabel)
            .accessibilityHint(localized("打開播放控制面板"))

            Button {
                performTapAction {
                    hub.togglePlayback()
                }
            } label: {
                Image(systemName: hub.playbackState == .playing ? "pause.fill" : "play.fill")
                    .font(DSFont.fixed(size: 18, weight: .bold))
                    .foregroundStyle(DSColor.textSecondary)
                    .frame(width: 48, height: 48)
                    .background(.thinMaterial, in: Circle())
                    .overlay(Circle().stroke(Color.secondary.opacity(0.35), lineWidth: 2))
            }
            .accessibilityLabel(localized(hub.playbackState == .playing ? "暫停" : "播放"))

            Button {
                performTapAction {
                    hub.stop()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(DSFont.fixed(size: 17, weight: .semibold))
                    .foregroundStyle(DSColor.textSecondary)
                    .frame(width: trailingButtonWidth, height: 48)
            }
            .accessibilityLabel(localized("停止播放"))

            // Tucks the player into the nearer side; playback keeps going. The arrow points
            // the way it will go, so it flips as the player is dragged across.
            Button {
                performTapAction {
                    collapse(to: nearestSide(in: size))
                }
            } label: {
                Image(systemName: nearestSide(in: size) == .left ? "chevron.left" : "chevron.right")
                    .font(DSFont.fixed(size: 17, weight: .semibold))
                    .foregroundStyle(DSColor.textSecondary)
                    .frame(width: trailingButtonWidth, height: 48)
                    .accessibilityHidden(true)
            }
            .accessibilityLabel(localized("收起"))
            .accessibilityFocused($focusedControl, equals: .collapse)
        }
        .buttonStyle(.borderless)
        .padding(.leading, 4)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .floatingSurface(in: Capsule())
        .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
        .contentShape(Capsule())
    }

    /// What VoiceOver announces for the artwork button — the title of whatever is
    /// playing. Labelling each button individually matters: an `.accessibilityLabel`
    /// on the enclosing `HStack` propagates down and gives all three buttons the same
    /// name, so VoiceOver read the book title three times over play/pause and stop.
    private var nowPlayingLabel: String {
        hub.title.isEmpty ? localized("語音朗讀") : hub.title
    }

    /// The leading 56pt tappable artwork: both TTS and audiobook spin the book cover
    /// like a record — the real cover when present, otherwise the same generated
    /// cover the bookshelf gives cover-less books.
    private var leadingArtwork: some View {
        SpinningCoverIcon(isPlaying: hub.playbackState == .playing) {
            if let cover = hub.coverImage {
                Image(uiImage: cover)
                    .resizable()
                    .scaledToFill()
            } else {
                GeneratedBookCover(title: hub.coverTitle)
            }
        }
        .frame(width: 56, height: 56)
    }

    /// Width of the icon buttons at the player's trailing end (✕, and 收起 in the reader).
    private let trailingButtonWidth: CGFloat = 34
    /// Gap between the player's controls.
    private let controlSpacing: CGFloat = 12

    private var contentWidth: CGFloat {
        // Wider by exactly the 收起 button, so the leading edge rests and clamps where it
        // did before the button existed.
        148 + trailingButtonWidth + controlSpacing
    }

    // MARK: - Tucked to the side

    /// The side the player is closer to, measured at its center — where it tucks away.
    private func nearestSide(in size: CGSize) -> DockSide {
        position(in: size).x < size.width / 2 ? .left : .right
    }

    private func collapse(to side: DockSide) {
        withAnimation(reduceMotion ? nil : DSAnimation.standard) {
            dockedSide = side
        }
        // The control VoiceOver was on is gone; land on the one that brings it back.
        focusedControl = .edgeHandle
    }

    private func expand() {
        withAnimation(reduceMotion ? nil : DSAnimation.standard) {
            dockedSide = nil
        }
        focusedControl = .collapse
    }

    /// What is left of the player while it is tucked away: a thin tab on the screen edge
    /// with an arrow pointing back in. Tapping it brings the player back where it was.
    private func edgeHandle(_ side: DockSide) -> some View {
        let inner = DSLayout.miniPlayerEdgeHandleWidth / 2
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: side == .right ? inner : 0,
            bottomLeadingRadius: side == .right ? inner : 0,
            bottomTrailingRadius: side == .left ? inner : 0,
            topTrailingRadius: side == .left ? inner : 0
        )
        return Button {
            expand()
        } label: {
            Image(systemName: side == .left ? "chevron.right" : "chevron.left")
                .font(DSFont.fixed(size: 13, weight: .semibold))
                .foregroundStyle(DSColor.textSecondary)
                .accessibilityHidden(true)
                .frame(
                    width: DSLayout.miniPlayerEdgeHandleWidth,
                    height: DSLayout.miniPlayerEdgeHandleHeight
                )
                .floatingSurface(in: shape)
                .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
                // Thin to look at, full size to hit: the tab hugs the edge and the rest of
                // the 44pt region reaches in over the page.
                .frame(
                    width: DSLayout.minimumTapTarget,
                    height: max(DSLayout.minimumTapTarget, DSLayout.miniPlayerEdgeHandleHeight),
                    alignment: side == .left ? .leading : .trailing
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(localized("展開"))
        .accessibilityValue(nowPlayingLabel)
        .accessibilityFocused($focusedControl, equals: .edgeHandle)
    }

    /// Flush against its side, on the line the player was on, so it tucks away and comes
    /// back along one line — and follows the same lift when the reader bars appear.
    private func edgeHandlePosition(_ side: DockSide, in size: CGSize) -> CGPoint {
        let halfHitWidth = DSLayout.minimumTapTarget / 2
        return CGPoint(
            x: side == .left ? halfHitWidth : size.width - halfHitWidth,
            y: defaultCenterY(in: size) + offset.height
        )
    }

    private func edgeHandleTransition(_ side: DockSide) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .move(edge: side == .left ? .leading : .trailing).combined(with: .opacity)
    }

    private var contentHeight: CGFloat {
        64
    }

    private func position(in size: CGSize) -> CGPoint {
        CGPoint(
            x: contentWidth / 2 + 26 + offset.width,
            y: defaultCenterY(in: size) + offset.height
        )
    }

    private func defaultCenterY(in size: CGSize) -> CGFloat {
        size.height - defaultBottomClearance - contentHeight / 2
    }

    private func clampedOffset(_ proposed: CGSize, in size: CGSize) -> CGSize {
        let width = contentWidth
        let leadingCenter = width / 2 + 26
        let minCenter = width / 2 + 14
        let maxCenter = size.width - width / 2 - 14
        let horizontalLimitLeft = minCenter - leadingCenter
        let horizontalLimitRight = maxCenter - leadingCenter
        let defaultCenterY = defaultCenterY(in: size)
        let topCenter = contentHeight / 2 + 14
        let bottomCenter = size.height - dragFloorClearance - contentHeight / 2
        let topLimit = topCenter - defaultCenterY
        let bottomLimit = bottomCenter - defaultCenterY
        return CGSize(
            width: min(max(proposed.width, horizontalLimitLeft), horizontalLimitRight),
            height: min(max(proposed.height, topLimit), bottomLimit)
        )
    }

    /// Where a drag puts the player: inside its bounds it follows the finger, past
    /// them it follows less and less, so the edge gives instead of stopping dead.
    /// Letting go brings it back inside (`dragGesture`). Under Reduce Motion the
    /// edge is a plain stop, since nothing would animate it back.
    private func resistedOffset(_ proposed: CGSize, in size: CGSize) -> CGSize {
        let clamped = clampedOffset(proposed, in: size)
        guard !reduceMotion else { return clamped }
        return CGSize(
            width: clamped.width + MiniPlayerDragResistance.give(for: proposed.width - clamped.width),
            height: clamped.height + MiniPlayerDragResistance.give(for: proposed.height - clamped.height)
        )
    }

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if dragStartOffset == nil {
                    dragStartOffset = offset
                    // User is repositioning by hand — forget the auto-lift origin so we
                    // don't snap it back when the bars next hide.
                    liftedFromOffsetHeight = nil
                }
                let start = dragStartOffset ?? .zero
                offset = resistedOffset(
                    CGSize(
                        width: start.width + value.translation.width,
                        height: start.height + value.translation.height
                    ),
                    in: size
                )
            }
            .onEnded { _ in
                withAnimation(reduceMotion ? nil : DSAnimation.dragSettle) {
                    offset = clampedOffset(offset, in: size)
                }
                dragStartOffset = nil
                lastDragEndedAt = Date()
            }
    }

    private func performTapAction(_ action: () -> Void) {
        guard Date().timeIntervalSince(lastDragEndedAt) > 0.18 else { return }
        action()
    }
}

/// How far the mini player gives when dragged past the edge of where it may rest.
enum MiniPlayerDragResistance {
    /// The most it can be pulled past the edge, however far the finger goes.
    static let maximumGive: CGFloat = DSLayout.miniPlayerDragMaximumGive

    /// Distance past the edge for a finger `overshoot` points beyond it: starts out
    /// following the finger at about half speed and levels off at `maximumGive`.
    /// The same curve a scroll view uses past its ends.
    static func give(for overshoot: CGFloat) -> CGFloat {
        guard overshoot != 0 else { return 0 }
        let distance = abs(overshoot)
        let given = (1 - 1 / (distance * 0.55 / maximumGive + 1)) * maximumGive
        return overshoot < 0 ? -given : given
    }
}

/// A circular disc that spins like a vinyl record while playing and freezes (keeping its
/// angle) when paused. The disc face is supplied by the caller — a real cover image or the
/// title-card placeholder. Rotation is time-driven via `TimelineView`, so the angle stays
/// continuous across pause/resume and costs nothing while paused.
private struct SpinningCoverIcon<Face: View>: View {
    let isPlaying: Bool
    @ViewBuilder var face: () -> Face

    private let degreesPerSecond = 36.0          // one full turn per 10s
    @State private var baseAngle: Double = 0     // degrees accrued before the current run
    @State private var runStart: Date = .now     // when the current spinning run began

    var body: some View {
        TimelineView(.animation(paused: !isPlaying)) { context in
            let angle = isPlaying
                ? baseAngle + context.date.timeIntervalSince(runStart) * degreesPerSecond
                : baseAngle
            record
                .rotationEffect(.degrees(angle))
        }
        .onAppear { if isPlaying { runStart = Date() } }
        .onChange(of: isPlaying) { _, playing in
            let now = Date()
            if playing {
                runStart = now
            } else {
                // Fold the elapsed run into the accumulated angle so it freezes in place.
                baseAngle += now.timeIntervalSince(runStart) * degreesPerSecond
            }
        }
    }

    private var record: some View {
        face()
            .frame(width: 56, height: 56)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.black.opacity(0.18), lineWidth: 1))
            .overlay(
                // Center spindle hole, to read as a record.
                Circle()
                    .fill(.regularMaterial)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Color.black.opacity(0.15), lineWidth: 0.5))
            )
    }
}

#Preview {
    ContentView()
        .environmentObject(BookStore())
}

#if DEBUG
#Preview("Reader mini-player") {
    NowPlayingHub.shared.configurePreview(
        title: "第十章 玄雅的赔礼",
        playbackState: .playing,
        currentSegmentIndex: 0,
        totalSegments: 94
    )
    return NowPlayingMiniPlayer(placement: .reader, barsVisible: false)
}
#endif
