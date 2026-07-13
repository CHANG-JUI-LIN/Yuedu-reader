import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: BookStore
    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject private var gs = GlobalSettings.shared
    @StateObject private var rssStore = RSSStore.shared
    @ObservedObject private var importDrainer = SharedImportQueueDrainer.shared
    @StateObject private var nowPlaying = NowPlayingHub.shared
    @State private var selectedRootTab: RootTabItem = .bookshelf

    private var rssUnreadCount: Int {
        rssStore.totalUnreadCount()
    }

    private var appearanceTheme: AppearanceThemePreset {
        gs.appearanceTheme(
            for: colorScheme,
            isProActive: subscriptionStore.hasAccess(.readerThemePacks)
        )
    }

    /// The theme whose surface colors should retint the whole app, or nil for
    /// system colors. Presets are light palettes, so surfaces only retint in
    /// light appearance; dark mode keeps clean system colors (accent still
    /// applies). Classic = no override.
    private var resolvedAppTheme: AppearanceThemePreset? {
        (colorScheme == .light && !appearanceTheme.isClassic) ? appearanceTheme : nil
    }

    private var typographyRefreshID: String {
        "\(gs.resolvedGlobalFontPostScript ?? "system")|\(dynamicTypeSize)"
    }

    var body: some View {
        // Sync the app-wide themed surfaces (read by DSColor) with the current
        // appearance before descendants read them this render pass. This is a
        // plain global, not SwiftUI state, so assigning it here is side-effect
        // free as far as invalidation goes.
        AppearanceThemePreset.activeAppTheme = resolvedAppTheme
        GlobalAppTypography.activate(postScriptName: gs.resolvedGlobalFontPostScript)
        return tabView
        // Classic (默認) = the app's original look: no tint override at all.
        .tint(appearanceTheme.isClassic ? nil : appearanceTheme.accentColor)
        .accentColor(appearanceTheme.isClassic ? nil : appearanceTheme.accentColor)
        .font(DSFont.body)
        .overlay(alignment: .top) {
            if let outcome = importDrainer.lastOutcome {
                SharedImportToast(outcome: outcome)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: outcome) {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        withAnimation { importDrainer.lastOutcome = nil }
                    }
            }
        }
        .overlay {
            // App-wide audiobook mini-player: controls the long-lived audiobook session
            // from any tab. Naturally hidden while a full-screen reader/player is presented.
            // No reader toolbar here, so allow dragging down to just above the tab bar.
            NowPlayingMiniPlayer(placement: .global, minBottomClearance: 90)
        }
        .iPadAdaptiveRootTabStyle()
        .rootTabBarMinimizeStyle()
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: importDrainer.lastOutcome)
        .task(id: typographyRefreshID) {
            await MainActor.run {
                GlobalAppTypographyUIKitBridge.apply(
                    postScriptName: gs.resolvedGlobalFontPostScript
                )
            }
        }
        .onAppear {
            selectedRootTab = gs.fallbackRootTab(for: selectedRootTab)
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
    }

    /// The root tab bar is driven by `GlobalSettings` so users can hide pages
    /// and customize tab icon assets without changing the feature screens.
    private var tabView: some View {
        TabView(selection: $selectedRootTab) {
            ForEach(gs.visibleRootTabs) { tab in
                rootTabContent(for: tab)
                    .modifier(ThemedSurfaceBackground(
                        themeActive: resolvedAppTheme != nil,
                        scope: AppearancePageBackgroundScope(rawValue: tab.rawValue) ?? .global,
                        isProActive: subscriptionStore.hasAccess(.readerThemePacks)
                    ))
                    .tag(tab)
                    .tabItem {
                        rootTabItemLabel(for: tab)
                    }
                    .badge(tab == .rss && rssUnreadCount > 0 ? Text("\(rssUnreadCount)") : nil)
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
                SearchView()
            }
        }
    }

    @ViewBuilder
    private func rootTabItemLabel(for tab: RootTabItem) -> some View {
        if let renderedIcon = RootTabIconRenderer.customIcon(
            for: tab,
            colorScheme: colorScheme,
            pointSize: CGFloat(
                gs.usesCustomRootTabIconSize
                    ? gs.rootTabIconSize
                    : GlobalSettings.initialCustomRootTabIconSize
            ),
            settings: gs
        ) {
            Image(uiImage: renderedIcon.image)
                .renderingMode(renderedIcon.isTemplate ? .template : .original)
            if !shouldHideRootTabLabels {
                Text(localized(tab.titleKey))
            }
        } else if usesCustomRootTabIconSize {
            let renderedIcon = RootTabIconRenderer.systemIcon(
                for: tab,
                pointSize: CGFloat(gs.rootTabIconSize)
            )
            Image(uiImage: renderedIcon.image)
                .renderingMode(.template)
            if !shouldHideRootTabLabels {
                Text(localized(tab.titleKey))
            }
        } else if shouldHideRootTabLabels {
            Image(systemName: tab.defaultSystemImage)
        } else {
            Label(localized(tab.titleKey), systemImage: tab.defaultSystemImage)
        }
    }
}

/// Retints scrollable Form/List surfaces to the active app theme by hiding the
/// system background and painting the themed page color behind — plus, when the
/// user configured a page background (Pro), the per-scope gradient/image layer.
/// A no-op when neither applies, so default users keep the exact system look.
private struct ThemedSurfaceBackground: ViewModifier {
    let themeActive: Bool
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

    func body(content: Content) -> some View {
        if let slice = pageBackgroundSlice {
            content
                .scrollContentBackground(.hidden)
                .background {
                    ZStack {
                        DSColor.groupedBackground
                        AppearancePageBackgroundLayerView(slice: slice)
                    }
                    .ignoresSafeArea()
                }
        } else if themeActive {
            content
                .scrollContentBackground(.hidden)
                .background(DSColor.groupedBackground.ignoresSafeArea())
        } else {
            content
        }
    }
}

/// Toast surfacing the real result of a Share Extension import,
/// replacing the extension's generic "added to queue" message.
private struct SharedImportToast: View {
    let outcome: SharedImportQueueDrainer.Outcome

    private var message: String {
        let imported = outcome.importedCount
        let failed = outcome.failureCount
        if imported > 0 && failed == 0 {
            return localized("成功匯入") + " \(imported) " + localized("個項目")
        } else if imported > 0 {
            return localized("成功匯入") + " \(imported) " + localized("個項目")
                + "，\(failed) " + localized("個失敗")
        } else {
            return "\(failed) " + localized("個項目匯入失敗")
        }
    }

    private var tint: Color {
        if outcome.importedCount == 0 { return .red }
        return outcome.failureCount == 0 ? .green : .orange
    }

    var body: some View {
        Label(message, systemImage: outcome.importedCount > 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
            .font(DSFont.subheadline.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(tint.opacity(0.95), in: Capsule())
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
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
    @State private var offset = CGSize(width: 0, height: 0)
    @State private var dragStartOffset: CGSize?
    @State private var lastDragEndedAt = Date.distantPast
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
                miniPlayerView
                    .frame(width: contentWidth)
                    .position(position(in: proxy.size))
                    .simultaneousGesture(dragGesture(in: proxy.size))
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
        .ignoresSafeArea(.keyboard)
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: isVisible)
        .onChange(of: barsVisible) { _, visible in
            withAnimation(.easeInOut(duration: 0.25)) {
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

    private var miniPlayerView: some View {
        HStack(spacing: 12) {
            Button {
                performTapAction {
                    hub.openPanel()
                }
            } label: {
                leadingArtwork
            }
            .buttonStyle(.plain)

            Button {
                performTapAction {
                    hub.togglePlayback()
                }
            } label: {
                Image(systemName: hub.playbackState == .playing ? "pause.fill" : "play.fill")
                    .font(DSFont.fixed(size: 18, weight: .bold))
                    .foregroundColor(.secondary)
                    .frame(width: 48, height: 48)
                    .background(.thinMaterial, in: Circle())
                    .overlay(Circle().stroke(Color.secondary.opacity(0.35), lineWidth: 2))
            }

            Button {
                performTapAction {
                    hub.stop()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(DSFont.fixed(size: 17, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 34, height: 48)
            }
        }
        .buttonStyle(.borderless)
        .padding(.leading, 4)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
        .contentShape(Capsule())
        .accessibilityLabel(hub.title.isEmpty ? localized("語音朗讀") : hub.title)
    }

    /// The leading 56pt tappable artwork: both TTS and audiobook spin the book cover
    /// like a record — the real cover when present, otherwise the same title-card
    /// placeholder the bookshelf gives cover-less books.
    private var leadingArtwork: some View {
        SpinningCoverIcon(isPlaying: hub.playbackState == .playing) {
            if let cover = hub.coverImage {
                Image(uiImage: cover)
                    .resizable()
                    .scaledToFill()
            } else {
                TitleCardPlaceholder(title: hub.coverTitle)
            }
        }
        .frame(width: 56, height: 56)
    }

    private var contentWidth: CGFloat {
        148
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
                offset = clampedOffset(
                    CGSize(
                        width: start.width + value.translation.width,
                        height: start.height + value.translation.height
                    ),
                    in: size
                )
            }
            .onEnded { _ in
                offset = clampedOffset(offset, in: size)
                dragStartOffset = nil
                lastDragEndedAt = Date()
            }
    }

    private func performTapAction(_ action: () -> Void) {
        guard Date().timeIntervalSince(lastDragEndedAt) > 0.18 else { return }
        action()
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
