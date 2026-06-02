import Combine
import SwiftUI

// MARK: - Manga reader (SwiftUI entry)
//
// Hosts the UIKit `MangaReaderViewController` full-screen and overlays SwiftUI
// controls. Shared state flows through `MangaReaderState`.

@MainActor
final class MangaReaderState: ObservableObject {
    @Published var chapterTitle: String = ""
    @Published var chapterListItems: [MangaChapterListItem] = []
    @Published var currentChapterIndex: Int = 0
    @Published var currentPage: Int = 0
    @Published var totalPages: Int = 0
    @Published var mode: MangaReadingMode = .rtl
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var showControls: Bool = true
    @Published var showChapterList: Bool = false

    // Actions wired by the controller.
    var onJumpToPage: ((Int) -> Void)?
    var onSelectChapter: ((Int) -> Void)?
    var onSetMode: ((MangaReadingMode) -> Void)?
    var onNextChapter: (() -> Void)?
    var onPrevChapter: (() -> Void)?
    var onReload: (() -> Void)?
}

struct MangaChapterListItem: Identifiable, Equatable {
    let id: UUID
    let index: Int
    let title: String

    static func items(from refs: [OnlineChapterRef]) -> [MangaChapterListItem] {
        refs.enumerated().map { offset, ref in
            let trimmedTitle = ref.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return MangaChapterListItem(
                id: ref.id,
                index: offset,
                title: trimmedTitle.isEmpty
                    ? String(format: localized("第 %d 章"), offset + 1)
                    : trimmedTitle
            )
        }
    }
}

struct MangaReaderView: View {
    let bookId: UUID
    @EnvironmentObject var store: BookStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var state = MangaReaderState()
    @State private var readingStatsTracker: ReadingStatsSessionTracker?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let book = store.books.first(where: { $0.id == bookId }) {
                MangaReaderRepresentable(book: book, store: store, state: state)
                    .ignoresSafeArea()

                if state.isLoading {
                    ProgressView().tint(.white).controlSize(.large)
                }

                if let message = state.errorMessage {
                    errorView(message)
                }

                if state.showControls {
                    MangaControlsOverlay(state: state, onClose: { dismiss() })
                        .transition(.opacity)
                }
            }
        }
        .animation(DSAnimation.fast, value: state.showControls)
        .statusBarHidden(!state.showControls)
        .onAppear {
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
            MangaChapterListView(state: state)
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

private struct MangaReaderRepresentable: UIViewControllerRepresentable {
    let book: ReadingBook
    let store: BookStore
    let state: MangaReaderState

    func makeUIViewController(context: Context) -> MangaReaderViewController {
        MangaReaderViewController(book: book, store: store, state: state)
    }

    func updateUIViewController(_ uiViewController: MangaReaderViewController, context: Context) {}
}

// MARK: - Controls overlay

struct MangaControlsOverlay: View {
    @ObservedObject var state: MangaReaderState
    var onClose: () -> Void

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
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
            }
            if !state.chapterListItems.isEmpty {
                Button {
                    state.showChapterList = true
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel(localized("目錄"))
            }
            Text(state.chapterTitle)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            modeMenu
        }
        .padding(.horizontal, DSSpacing.md)
        .padding(.vertical, DSSpacing.sm)
        .padding(.top, 44)
        .background(.ultraThinMaterial)
    }

    private var modeMenu: some View {
        Menu {
            ForEach(MangaReadingMode.allCases, id: \.rawValue) { mode in
                Button {
                    state.onSetMode?(mode)
                } label: {
                    Label(mode.localizedName, systemImage: state.mode == mode ? "checkmark" : mode.iconName)
                }
            }
        } label: {
            Image(systemName: "rectangle.portrait.on.rectangle.portrait")
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(.white)
                .frame(width: 36, height: 36)
        }
    }

    private var bottomBar: some View {
        VStack(spacing: DSSpacing.xs) {
            if state.totalPages > 1 {
                HStack(spacing: DSSpacing.md) {
                    Button { state.onPrevChapter?() } label: {
                        Image(systemName: "backward.end").foregroundColor(.white)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(state.currentPage) },
                            set: { state.onJumpToPage?(Int($0.rounded())) }
                        ),
                        in: 0...Double(max(1, state.totalPages - 1)),
                        step: 1
                    )
                    .tint(.white)
                    Button { state.onNextChapter?() } label: {
                        Image(systemName: "forward.end").foregroundColor(.white)
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

struct MangaChapterListView: View {
    @ObservedObject var state: MangaReaderState
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
                                .font(.subheadline)
                            Spacer()
                            if item.index == state.currentChapterIndex {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .id(item.index)
                }
                .onAppear {
                    proxy.scrollTo(state.currentChapterIndex, anchor: .center)
                }
            }
            .navigationTitle(localized("目錄"))
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(localized("關閉")) { dismiss() }
                }
            }
        }
    }
}
