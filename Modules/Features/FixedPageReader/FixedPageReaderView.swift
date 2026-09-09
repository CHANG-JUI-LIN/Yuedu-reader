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
    @Environment(\.dismiss) private var dismiss
    @Environment(\.readerNavigator) private var readerNavigator
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appDependencies) private var dependencies
    @StateObject private var state = FixedPageReaderState()
    @State private var readingStatsTracker: ReadingStatsSessionTracker?
    @State private var showTouchZoneEditor = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let book = store.books.first(where: { $0.id == bookId }) {
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
                        onClose: {
                            if let readerNavigator {
                                readerNavigator.close()
                            } else {
                                dismiss()
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
                                state.isAutoScrolling.toggle()
                            } label: {
                                Image(systemName: state.isAutoScrolling ? "pause.circle.fill" : "play.circle.fill")
                                    .font(.system(size: 40))
                                    .foregroundColor(.white)
                                    .background(Circle().fill(Color.black.opacity(0.6)))
                            }
                            .padding(.trailing, DSSpacing.lg)
                            .padding(.bottom, state.showControls ? 85 : 36)
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
        .sheet(isPresented: $state.showChapterList) {
            FixedPageChapterListView(state: state)
        }
    }

    private var currentBook: ReadingBook? {
        store.books.first(where: { $0.id == bookId })
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
    var onClose: () -> Void
    var onOpenTouchZoneEditor: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            bottomBar
        }
        .ignoresSafeArea(edges: .top)
    }

    private var topBar: some View {
        HStack(spacing: DSSpacing.sm) {
            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(DSFont.fixed(size: 17, weight: .medium))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)
            }
            .accessibilityLabel(localized("返回"))
            if !state.chapterListItems.isEmpty {
                Button {
                    state.showChapterList = true
                } label: {
                    Image(systemName: "list.bullet")
                        .font(DSFont.fixed(size: 17, weight: .medium))
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel(localized("目錄"))
            }
            Text(state.chapterTitle)
                .font(DSFont.fixed(size: 14, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            FixedPageReaderSettingsView(
                fixedPageReaderConfiguration: state.fixedPageReaderConfiguration,
                onSelectConfiguration: { state.onSetConfiguration?($0) },
                onOpenTouchZoneEditor: onOpenTouchZoneEditor
            )
        }
        .padding(.horizontal, DSSpacing.md)
        .padding(.vertical, DSSpacing.sm)
        .padding(.top, 44)
        .background(.ultraThinMaterial)
    }

    private var isRTL: Bool {
        state.fixedPageReaderConfiguration.progression == .rightToLeft
    }

    private var bottomBar: some View {
        VStack(spacing: DSSpacing.xs) {
            if state.totalPages > 1 {
                HStack(spacing: DSSpacing.md) {
                    Button {
                        if isRTL { state.onNextChapter?() } else { state.onPrevChapter?() }
                    } label: {
                        Image(systemName: isRTL ? "forward.end" : "backward.end").foregroundColor(.white)
                    }
                    Slider(
                        value: Binding(
                            get: {
                                isRTL
                                    ? Double(max(0, state.totalPages - 1 - state.currentPage))
                                    : Double(state.currentPage)
                            },
                            set: { newValue in
                                let target = isRTL
                                    ? state.totalPages - 1 - Int(newValue.rounded())
                                    : Int(newValue.rounded())
                                state.onJumpToPage?(target)
                            }
                        ),
                        in: 0...Double(max(1, state.totalPages - 1)),
                        step: 1
                    )
                    .tint(.white)
                    Button {
                        if isRTL { state.onPrevChapter?() } else { state.onNextChapter?() }
                    } label: {
                        Image(systemName: isRTL ? "backward.end" : "forward.end").foregroundColor(.white)
                    }
                }
                .padding(.horizontal, DSSpacing.md)
            }
            Text(String(format: localized("第 %d / %d 頁"), state.currentPage + 1, max(state.totalPages, state.currentPage + 1)))
                .font(DSFont.caption)
                .foregroundColor(.white)
        }
        .padding(.top, DSSpacing.sm)
        .padding(.bottom, 30)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
    }
}

struct FixedPageReaderSettingsView: View {
    let fixedPageReaderConfiguration: FixedPageReaderConfiguration
    var onSelectConfiguration: (FixedPageReaderConfiguration) -> Void
    var onOpenTouchZoneEditor: () -> Void

    @ObservedObject private var subscriptionStore = SubscriptionStore.shared

    var body: some View {
        Menu {
            // Section 1: Reading Mode
            Section {
                ForEach(FixedPageReadingMode.allCases, id: \.rawValue) { mode in
                    Button {
                        var updated = FixedPageReaderConfiguration.recommendedDefault(for: mode)
                        // Preserve user toggles
                        updated.cropBorders = fixedPageReaderConfiguration.cropBorders
                        updated.isLiveTextEnabled = fixedPageReaderConfiguration.isLiveTextEnabled
                        updated.pageSpreadLayout = fixedPageReaderConfiguration.pageSpreadLayout
                        updated.pageOffset = fixedPageReaderConfiguration.pageOffset
                        updated.splitWideImages = fixedPageReaderConfiguration.splitWideImages
                        updated.pillarbox = fixedPageReaderConfiguration.pillarbox
                        onSelectConfiguration(updated)
                    } label: {
                        Label(
                            mode.localizedName,
                            systemImage: fixedPageReaderConfiguration.mode == mode ? "checkmark" : mode.iconName
                        )
                    }
                }
            }

            // Section 2: Paged mode specific options
            if fixedPageReaderConfiguration.layout == .paged {
                Section {
                    ForEach(FixedPageReaderConfiguration.PageSpreadLayout.allCases, id: \.rawValue) { layout in
                        Button {
                            var config = fixedPageReaderConfiguration
                            config.pageSpreadLayout = layout
                            onSelectConfiguration(config)
                        } label: {
                            Label(
                                spreadTitle(layout),
                                systemImage: fixedPageReaderConfiguration.pageSpreadLayout == layout ? "checkmark" : spreadIcon(layout)
                            )
                        }
                    }

                    Button {
                        var config = fixedPageReaderConfiguration
                        config.pageOffset.toggle()
                        onSelectConfiguration(config)
                    } label: {
                        Label(
                            localized("封面單頁偏移"),
                            systemImage: fixedPageReaderConfiguration.pageOffset ? "checkmark.square" : "square"
                        )
                    }

                    Button {
                        var config = fixedPageReaderConfiguration
                        config.splitWideImages.toggle()
                        onSelectConfiguration(config)
                    } label: {
                        Label(
                            localized("自動切分雙頁大圖"),
                            systemImage: fixedPageReaderConfiguration.splitWideImages ? "checkmark.square" : "square"
                        )
                    }
                }
            }

            // Section 3: Webtoon mode specific options
            if fixedPageReaderConfiguration.layout == .continuousVerticalScroll {
                Section {
                    Button {
                        var config = fixedPageReaderConfiguration
                        config.pillarbox.toggle()
                        onSelectConfiguration(config)
                    } label: {
                        Label(
                            localized("寬屏黑邊限制"),
                            systemImage: fixedPageReaderConfiguration.pillarbox ? "checkmark.square" : "square"
                        )
                    }
                }
            }

            // Section 4: General enhancements
            Section {
                Button {
                    var config = fixedPageReaderConfiguration
                    config.cropBorders.toggle()
                    onSelectConfiguration(config)
                } label: {
                    Label(
                        localized("自動裁切留白邊框"),
                        systemImage: fixedPageReaderConfiguration.cropBorders ? "checkmark.square" : "square"
                    )
                }

                Button {
                    var config = fixedPageReaderConfiguration
                    config.isLiveTextEnabled.toggle()
                    onSelectConfiguration(config)
                } label: {
                    Label(
                        localized("原文字選取與識別"),
                        systemImage: fixedPageReaderConfiguration.isLiveTextEnabled ? "checkmark.square" : "square"
                    )
                }
            }

            // Section 5: Touch zone editor
            if ReaderPremiumVisibilityPolicy(isProActive: subscriptionStore.isProActive).showsTouchZoneEditor,
               fixedPageReaderConfiguration.layout == .paged {
                Divider()
                Button(action: onOpenTouchZoneEditor) {
                    Label(localized("翻頁區塊編輯"), systemImage: "hand.tap")
                }
            }
        } label: {
            Image(systemName: "rectangle.portrait.on.rectangle.portrait")
                .font(DSFont.fixed(size: 17, weight: .medium))
                .foregroundColor(.white)
                .frame(width: 36, height: 36)
        }
    }

    private func spreadTitle(_ layout: FixedPageReaderConfiguration.PageSpreadLayout) -> String {
        switch layout {
        case .single: return localized("單頁")
        case .double: return localized("雙頁")
        case .auto: return localized("自動雙頁")
        }
    }

    private func spreadIcon(_ layout: FixedPageReaderConfiguration.PageSpreadLayout) -> String {
        switch layout {
        case .single: return "rectangle.portrait"
        case .double: return "rectangle.split.2x1"
        case .auto: return "rectangle.portrait.and.arrow.forward"
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
