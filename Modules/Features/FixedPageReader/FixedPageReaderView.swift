import YueduCoreText
import Combine
import SwiftUI

// MARK: - Fixed page reader (SwiftUI entry)
//
// Hosts the UIKit `FixedPageReaderViewController` full-screen and overlays SwiftUI
// controls. Shared state flows through `FixedPageReaderState`.

@MainActor
final class FixedPageReaderState: ObservableObject {
    @Published var chapterTitle: String = ""
    @Published var chapterListItems: [FixedPageChapterListItem] = []
    @Published var currentChapterIndex: Int = 0
    @Published var currentPage: Int = 0
    @Published var totalPages: Int = 0
    @Published var fixedPageReaderConfiguration: FixedPageReaderConfiguration = .recommendedDefault(for: .rtl)
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var showControls: Bool = true
    @Published var showChapterList: Bool = false
    @Published var isAutoScrolling: Bool = false

    // Actions wired by the controller.
    var onJumpToPage: ((Int) -> Void)?
    var onSelectChapter: ((Int) -> Void)?
    var onSetConfiguration: ((FixedPageReaderConfiguration) -> Void)?
    var onNextChapter: (() -> Void)?
    var onPrevChapter: (() -> Void)?
    var onReload: (() -> Void)?
    var onToggleAutoScroll: (() -> Void)?
    var onStopAutoScroll: (() -> Void)?
}

struct FixedPageChapterListItem: Identifiable, Equatable {
    let id: UUID
    let index: Int
    let title: String

    static func items(from refs: [OnlineChapterRef]) -> [FixedPageChapterListItem] {
        refs.enumerated().map { offset, ref in
            let trimmedTitle = ref.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return FixedPageChapterListItem(
                id: ref.id,
                index: offset,
                title: trimmedTitle.isEmpty
                    ? String(format: localized("第 %d 章"), offset + 1)
                    : trimmedTitle
            )
        }
    }
}

struct FixedPageReaderView: View {
    let bookId: UUID
    @EnvironmentObject var store: BookStore
    // iOS 17 invalidates DismissAction over and over while a reader is pushed above
    // a book detail, and this reader's toolbar feeds every rebuild back into
    // navigation layout. Same stable binding as BookReaderView and ReaderView
    // (Technotes/iOS17ReaderNavigationWatchdog.md).
    @Environment(\.presentationMode) private var presentationMode
    @Environment(\.readerNavigator) private var readerNavigator
    @Environment(\.readerUsesParentNavigationStack) private var usesParentNavigationStack
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appDependencies) private var dependencies
    @StateObject private var state = FixedPageReaderState()
    @State private var readingStatsTracker: ReadingStatsSessionTracker?
    @State private var showTouchZoneEditor = false

    var body: some View {
        // The shelf's card push hosts this reader in a UIKit controller whose bar
        // carries the toolbar. Every other entry lets ReaderNavigationContainer
        // decide, as the flowing reader does: a modal reader brings its own stack,
        // a reader pushed from a book detail joins the detail's. No card navigator
        // does not mean modal; the detail's destination must never hold a second
        // NavigationStack (DetailReaderStackTests).
        if readerNavigator == nil {
            ReaderNavigationContainer { readerContent }
        } else {
            readerContent
        }
    }

    private var readerContent: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let book = store.readingBook(id: bookId) {
                FixedPageReaderRepresentable(
                    book: book,
                    store: store,
                    state: state,
                    chapterFetcher: dependencies.chapterFetcher
                )
                    .ignoresSafeArea()

                if state.isLoading {
                    ProgressView().tint(.white).controlSize(.large)
                }

                if let message = state.errorMessage {
                    errorView(message)
                }

                if state.showControls {
                    FixedPageReaderControlsOverlay(
                        state: state,
                        isModal: readerNavigator == nil && !usesParentNavigationStack,
                        onClose: {
                            if let readerNavigator {
                                readerNavigator.close()
                            } else {
                                // Pops a detail-origin push, dismisses a modal reader.
                                presentationMode.wrappedValue.dismiss()
                            }
                        },
                        onOpenTouchZoneEditor: {
                            state.showControls = false
                            showTouchZoneEditor = true
                        }
                    )
                        .transition(.opacity)
                }

                if state.fixedPageReaderConfiguration.layout == .continuousVerticalScroll {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Button {
                                state.onToggleAutoScroll?()
                            } label: {
                                Image(systemName: state.isAutoScrolling ? "pause.fill" : "play.fill")
                                    .font(DSFont.bodyBold)
                                    .foregroundStyle(DSColor.textPrimary)
                                    .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
                                    .contentShape(Rectangle())
                                    .accessibilityHidden(true)
                            }
                            .background(.regularMaterial, in: Circle())
                            .accessibilityLabel(
                                state.isAutoScrolling ? localized("暫停自動捲動") : localized("開始自動捲動")
                            )
                            .padding(.trailing, DSSpacing.lg)
                            .padding(.bottom, DSSpacing.lg)
                        }
                    }
                    .transition(.opacity)
                }

                if showTouchZoneEditor {
                    ReaderTouchZoneEditorView(
                        isRTL: state.fixedPageReaderConfiguration.progression == .rightToLeft,
                        onCancel: { showTouchZoneEditor = false },
                        onSave: { showTouchZoneEditor = false }
                    )
                    .zIndex(100)
                }
            }
        }
        .animation(DSAnimation.fast, value: state.showControls)
        .toolbar(.hidden, for: .tabBar)
        .navigationBarBackButtonHidden(true)
        .toolbarTitleDisplayMode(.inline)
        .toolbar(state.showControls ? .visible : .hidden, for: .navigationBar, .bottomBar)
        .statusBarHidden(!state.showControls)
        // Same immersive rule as the flowing reader: the home indicator fades with
        // the controls and comes back with them.
        .persistentSystemOverlays(
            ReaderOverlayPresentationPolicy.hidesHomeIndicator(
                showsReaderChrome: state.showControls,
                isEditing: false
            ) ? .hidden : .automatic
        )
        .onChange(of: state.isLoading) { _, isLoading in
            if !isLoading {
                // The page container or its error state has been installed.
                readerNavigator?.signalReaderContentReady()
            }
        }
        .onChange(of: state.fixedPageReaderConfiguration) { _, configuration in
            readerNavigator?.updateOpeningDirection(
                ReaderBookOpeningDirection.resolve(
                    writingMode: .horizontal,
                    pageProgressionIsRTL: configuration.progression == .rightToLeft
                )
            )
        }
        .onAppear {
            // A pushed reader updates recency after its card transition finishes,
            // so a recently-read shelf does not move the source cover mid-open.
            if readerNavigator == nil {
                store.updateLastOpened(bookId: bookId)
            }
            beginReadingStatsSession()
        }
        .onDisappear {
            finishReadingStatsSession()
        }
        .onChanged(of: scenePhase) { phase in
            if phase == .background || phase == .inactive {
                finishReadingStatsSession()
            } else if phase == .active {
                beginReadingStatsSession()
            }
        }
        .onChange(of: state.showChapterList) { _, isPresented in
            if isPresented { state.onStopAutoScroll?() }
        }
        .sheet(isPresented: $state.showChapterList) {
            FixedPageChapterListView(state: state)
        }
    }

    private var currentBook: ReadingBook? {
        store.readingBook(id: bookId)
    }

    private func beginReadingStatsSession() {
        guard readingStatsTracker == nil, let currentBook else { return }
        readingStatsTracker = ReadingStatsSessionTracker(
            bookId: currentBook.id.uuidString,
            bookTitle: currentBook.title
        )
    }

    private func finishReadingStatsSession() {
        guard let tracker = readingStatsTracker else { return }
        if let session = tracker.finish() {
            ReadingStatsStore.shared.recordSession(session)
        }
        readingStatsTracker = nil
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: DSSpacing.md) {
            Text(message)
                .foregroundColor(.white)
                .font(DSFont.body)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button(localized("重試")) { state.onReload?() }
                .foregroundColor(DSColor.accent)
                .font(DSFont.bodyBold)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - UIKit bridge

private struct FixedPageReaderRepresentable: UIViewControllerRepresentable {
    let book: ReadingBook
    let store: BookStore
    let state: FixedPageReaderState
    let chapterFetcher: any ChapterFetching

    func makeUIViewController(context: Context) -> FixedPageReaderViewController {
        FixedPageReaderViewController(
            book: book,
            store: store,
            state: state,
            chapterFetcher: chapterFetcher
        )
    }

    func updateUIViewController(_ uiViewController: FixedPageReaderViewController, context: Context) {}
}

// MARK: - Controls overlay

struct FixedPageReaderControlsOverlay: View {
    @ObservedObject var state: FixedPageReaderState
    var isModal = true
    var onClose: () -> Void
    var onOpenTouchZoneEditor: () -> Void
    @State private var showSettings = false
    @State private var pendingTouchZoneEditor = false
    /// iOS 17: the paywall a locked setting asked for, presented once settings is gone.
    @State private var pendingPaywall: PremiumFeature?
    @State private var paywallFeature: PremiumFeature?

    var body: some View {
        GeometryReader { geometry in
            Color.clear
                .allowsHitTesting(false)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: onClose) {
                            Label(localized(isModal ? "關閉" : "返回"), systemImage: isModal ? "xmark" : "chevron.left")
                                .labelStyle(.iconOnly)
                        }
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        if !state.chapterListItems.isEmpty {
                            Button {
                                state.onStopAutoScroll?()
                                state.showChapterList = true
                            } label: {
                                Label(localized("目錄"), systemImage: "list.bullet")
                                    .labelStyle(.iconOnly)
                            }
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            state.onStopAutoScroll?()
                            showSettings = true
                        } label: {
                            Label(localized("閱讀設定"), systemImage: "slider.horizontal.3")
                                .labelStyle(.iconOnly)
                        }
                    }
                    ToolbarItem(placement: .bottomBar) {
                        // Like Aidoku, the progress control lives in the native toolbar.
                        // Measure this window, including Split View, rather than the screen.
                        bottomBar
                            .frame(width: max(0, geometry.size.width - DSSpacing.xl * 2))
                    }
                }
        }
        .navigationTitle(state.chapterTitle)
        .sheet(isPresented: $showSettings, onDismiss: {
            if pendingTouchZoneEditor {
                pendingTouchZoneEditor = false
                onOpenTouchZoneEditor()
            }
            if let feature = pendingPaywall {
                pendingPaywall = nil
                paywallFeature = feature
            }
        }) {
            FixedPageReaderSettingsView(
                state: state,
                onOpenTouchZoneEditor: {
                    pendingTouchZoneEditor = true
                    showSettings = false
                },
                onOpenPaywall: ReaderSettingsPresentationPolicy.requiresFirstLevelImporter
                    ? { feature in
                        pendingPaywall = feature
                        showSettings = false
                    }
                    : nil
            )
        }
        .sheet(item: $paywallFeature) { feature in
            PaywallView(highlightedFeature: feature)
                .environmentObject(SubscriptionStore.shared)
        }
    }

    private var isRTL: Bool {
        state.fixedPageReaderConfiguration.progression == .rightToLeft
    }

    private var pageIndicatorText: String {
        String(format: localized("第 %d / %d 頁"), state.currentPage + 1,
               max(state.totalPages, state.currentPage + 1))
    }

    private var bottomBar: some View {
        HStack(spacing: DSSpacing.sm) {
            chapterButton(forward: false)
            // Aidoku's ReaderToolbarView anchors the slider to the top of the
            // bar and pins the page labels to its bottom edge, so the label
            // never takes part in the slider's own layout. Stacking the two in
            // a VStack instead centres them as a pair and leaves the slider
            // about 6pt above the bar's centre line.
            ZStack {
                Slider(
                    value: Binding(
                        get: { Double(state.currentPage) },
                        set: { state.onJumpToPage?(Int($0.rounded())) }
                    ),
                    in: 0...Double(max(1, state.totalPages - 1)),
                    step: 1
                )
                .disabled(state.totalPages <= 1)
                // The value is always plain forward progress; a right-to-left
                // book mirrors the *track* instead, which is what Aidoku's
                // ReaderSliderView does for `direction == .backward` by
                // re-anchoring its thumb and filled track to the trailing edge.
                // Inverting the value here instead filled the whole bar on page
                // one of a manga, so a freshly opened book read as finished.
                .environment(\.layoutDirection, isRTL ? .rightToLeft : .leftToRight)
                .tint(DSColor.textPrimary)
                .accessibilityLabel(localized("閱讀進度"))
                .accessibilityValue(pageIndicatorText)
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Text(pageIndicatorText)
                        .font(DSFont.caption2)
                        .foregroundStyle(DSColor.textSecondary)
                        .accessibilityHidden(true)
                }
            }
            chapterButton(forward: true)
        }
        // The bar itself never mirrors with the app's UI language; only the
        // slider above follows the book. This is what Aidoku gets from
        // `semanticContentAttribute = .playback` on its slider view.
        .environment(\.layoutDirection, .leftToRight)
        // The toolbar's capsule keeps its own height whatever this frame asks for,
        // so anything laid out past minimumTapTarget spills outside it — that is
        // what pushed the page number half out of the bar.
        .frame(height: DSLayout.minimumTapTarget)
    }

    private func chapterButton(forward: Bool) -> some View {
        let nextChapter = forward != isRTL
        return Button {
            if nextChapter { state.onNextChapter?() } else { state.onPrevChapter?() }
        } label: {
            Image(systemName: forward ? "forward.end" : "backward.end")
                .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(DSColor.textPrimary)
        .accessibilityLabel(nextChapter ? localized("下一章") : localized("上一章"))
    }
}

struct FixedPageReaderSettingsView: View {
    @ObservedObject var state: FixedPageReaderState
    var onOpenTouchZoneEditor: () -> Void
    /// iOS 17: hands the paywall to the controls overlay, which presents it once this
    /// sheet is gone — a sheet asked for from inside this one can be dropped there
    /// (`ReaderSettingsPresentationPolicy`). Nil where this view presents it itself.
    var onOpenPaywall: ((PremiumFeature) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var subscriptionStore = SubscriptionStore.shared
    @State private var paywallFeature: PremiumFeature?

    private var configuration: FixedPageReaderConfiguration { state.fixedPageReaderConfiguration }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(localized("閱讀模式"), selection: Binding(
                        get: { configuration.mode },
                        set: { mode in
                            var updated = FixedPageReaderConfiguration.recommendedDefault(for: mode)
                            updated.cropBorders = configuration.cropBorders
                            updated.isLiveTextEnabled = configuration.isLiveTextEnabled
                            updated.pageSpreadLayout = configuration.pageSpreadLayout
                            updated.pageOffset = configuration.pageOffset
                            updated.splitWideImages = configuration.splitWideImages
                            updated.pillarbox = configuration.pillarbox
                            state.onSetConfiguration?(updated)
                        }
                    )) {
                        ForEach(FixedPageReadingMode.allCases, id: \.rawValue) { mode in
                            Text(mode.localizedName).tag(mode)
                        }
                    }
                }
                Section {
                    if configuration.layout == .paged {
                        Picker(localized("頁面顯示"), selection: binding(\.pageSpreadLayout)) {
                            ForEach(FixedPageReaderConfiguration.PageSpreadLayout.allCases, id: \.rawValue) { layout in
                                Text(spreadTitle(layout)).tag(layout)
                            }
                        }
                        Toggle(localized("封面單頁偏移"), isOn: binding(\.pageOffset))
                        Toggle(localized("自動切分雙頁大圖"), isOn: binding(\.splitWideImages))
                    } else {
                        Toggle(localized("寬屏黑邊限制"), isOn: binding(\.pillarbox))
                    }
                    Toggle(localized("自動裁切留白邊框"), isOn: binding(\.cropBorders))
                    Toggle(localized("原文字選取與識別"), isOn: binding(\.isLiveTextEnabled))
                }
                if configuration.layout == .paged {
                    Section {
                        if ReaderPremiumVisibilityPolicy(isProActive: subscriptionStore.isProActive).showsTouchZoneEditor {
                            Button(action: onOpenTouchZoneEditor) {
                                Label(localized("翻頁區塊編輯"), systemImage: "hand.tap")
                            }
                        } else {
                            // Seen without Pro too, locked (2026-09-27): the paywall, not the editor.
                            Button {
                                requestPaywall(.touchZoneEditor)
                            } label: {
                                HStack {
                                    Label(localized("翻頁區塊編輯"), systemImage: "hand.tap")
                                        .foregroundStyle(DSColor.textPrimary)
                                    Spacer(minLength: DSSpacing.md)
                                    Text(localized("需要 Pro"))
                                        .foregroundStyle(DSColor.textSecondary)
                                    Image(systemName: "lock.fill")
                                        .font(DSFont.caption)
                                        .foregroundStyle(DSColor.textSecondary)
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(localized("閱讀設定"))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Label(localized("關閉"), systemImage: "xmark").labelStyle(.iconOnly)
                    }
                }
            }
            .sheet(item: $paywallFeature) { feature in
                PaywallView(highlightedFeature: feature)
                    .environmentObject(subscriptionStore)
            }
        }
    }

    /// A locked control's paywall: from this sheet on iOS 18, from the controls overlay on
    /// iOS 17 (`onOpenPaywall`) — the same split as the flowing reader's settings.
    private func requestPaywall(_ feature: PremiumFeature) {
        if let onOpenPaywall {
            onOpenPaywall(feature)
        } else {
            paywallFeature = feature
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<FixedPageReaderConfiguration, Value>) -> Binding<Value> {
        Binding(get: { configuration[keyPath: keyPath] }, set: { value in
            var updated = configuration
            updated[keyPath: keyPath] = value
            state.onSetConfiguration?(updated)
        })
    }

    private func spreadTitle(_ layout: FixedPageReaderConfiguration.PageSpreadLayout) -> String {
        switch layout {
        case .single: return localized("單頁")
        case .double: return localized("雙頁")
        case .auto: return localized("自動雙頁")
        }
    }
}

struct FixedPageChapterListView: View {
    @ObservedObject var state: FixedPageReaderState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(state.chapterListItems) { item in
                    Button {
                        state.onSelectChapter?(item.index)
                    } label: {
                        HStack {
                            Text(item.title)
                                .foregroundColor(.primary)
                                .font(DSFont.subheadline)
                            Spacer()
                            if item.index == state.currentChapterIndex {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .interfaceSectionSurface()
                    .id(item.index)
                }
                // Rows need their own transparent surface too — `scrollContentBackground`
                // only clears the list container. docs/design.md §4.1.
                .scrollContentBackground(.hidden)
                .onAppear {
                    proxy.scrollTo(state.currentChapterIndex, anchor: .center)
                }
            }
            .background(PageBackgroundView(scope: .settings).ignoresSafeArea())
            .pageBackgroundToolbar(for: .settings)
            .navigationTitle(localized("目錄"))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
        }
    }
}

#Preview {
    FixedPageReaderView(bookId: UUID())
        .environmentObject(BookStore())
}

#Preview("Controls overlay") {
    let state = FixedPageReaderState()
    state.chapterTitle = "第 1 話"
    state.chapterListItems = FixedPageChapterListItem.items(
        from: [OnlineChapterRef(index: 0, title: "第 1 話", url: "")]
    )
    state.totalPages = 24
    return NavigationStack {
        ZStack {
            Color.black.ignoresSafeArea()
            FixedPageReaderControlsOverlay(state: state, onClose: {}, onOpenTouchZoneEditor: {})
        }
        .toolbarTitleDisplayMode(.inline)
    }
}

#Preview("Settings") {
    // Paged by default, so 翻頁區塊編輯 shows — locked unless Pro is active.
    FixedPageReaderSettingsView(state: FixedPageReaderState(), onOpenTouchZoneEditor: {})
        .environmentObject(SubscriptionStore.shared)
}
