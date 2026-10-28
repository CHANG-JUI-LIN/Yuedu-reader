import SwiftUI

// The single reader entry point. It reads one copy at a time: 換源 to another version of the
// work (`ShelfVersionSwitch`) hands its place to that version's reader, in the same place in
// the navigation.
struct BookReaderView: View {
    let bookId: UUID
    /// 作品詳情's 目錄 entry the reader opens at (`ReaderView`'s opening restore goes on to it).
    var openingTOCTarget: ReaderTOCTarget?
    @Environment(\.readerNavigator) private var readerNavigator
    /// The version 換源 switched to, and where its reader opens.
    @State private var switched: SwitchedVersion?

    private struct SwitchedVersion {
        let id: UUID
        let opening: ReaderTOCTarget?
    }

    var body: some View {
        let id = switched?.id ?? bookId
        BookReaderContent(bookId: id, openingTOCTarget: switched.map { $0.opening } ?? openingTOCTarget)
            // Another copy is another reader: its own resources, layout and restore.
            .id(id)
            .environment(\.readerVersionSwitch, ReaderVersionSwitchAction { target, opening in
                switched = SwitchedVersion(id: target, opening: opening)
                readerNavigator?.readerDidSwitchVersion(to: target)
            })
    }
}

/// 換源 to another version of the work: the reader on screen gives way to the version's own.
struct ReaderVersionSwitchAction {
    let perform: @MainActor (UUID, ReaderTOCTarget?) -> Void

    @MainActor
    func callAsFunction(_ bookID: UUID, opening: ReaderTOCTarget?) {
        perform(bookID, opening)
    }
}

extension EnvironmentValues {
    /// Set by `BookReaderView`; nil for a reader shown outside it.
    @Entry var readerVersionSwitch: ReaderVersionSwitchAction? = nil
}

// Prepares remote resources before choosing the existing format-specific reader. Shelf
// membership never determines readability.
private struct BookReaderContent: View {
    let bookId: UUID
    var openingTOCTarget: ReaderTOCTarget?
    @EnvironmentObject var store: BookStore
    @Environment(\.appDependencies) private var dependencies
    @Environment(\.readerNavigator) private var readerNavigator
    @Environment(\.readerUsesParentNavigationStack) private var usesParentNavigationStack
    @Environment(\.rootTabBarVisibility) private var rootTabBarVisibility
    // iOS 17 repeatedly invalidates DismissAction during a detail-to-reader
    // push, feeding navigation layout back into this entire reader hierarchy.
    // Use the same stable presentation binding as ReaderView itself.
    @Environment(\.presentationMode) private var presentationMode
    @State private var resourceOwnerID = UUID()
    @State private var remoteReady = false
    /// A converted Aozora book is brought up to this build's converter before it opens.
    @State private var aozoraReady = false
    @State private var remoteError: String?
    @State private var retryGeneration = 0
    @State private var holdsCache = false
    @State private var resourceFailureAlert = RemoteReaderFailureAlertState()
    /// This open has moved the book to the front of 繼續閱讀 and 最近閱讀 (`onAppear`).
    @State private var stampedOpen = false

    private var book: ReadingBook? { store.readingBook(id: bookId) }

    var body: some View {
        Group {
            if book?.remoteSource != nil && !remoteReady {
                ReaderPreparingView(
                    error: remoteError,
                    onRetry: { retryGeneration += 1 },
                    onClose: closeReader
                )
            } else if book?.aozora != nil && !aozoraReady {
                ReaderPreparingView(error: nil, onRetry: {}, onClose: closeReader)
            } else if isAudiobook {
                AudiobookReaderView(bookId: bookId)
            } else if shouldUseFixedPageReader {
                FixedPageReaderView(bookId: bookId)
            } else {
                ReaderView(bookId: bookId, openingTOCTarget: openingTOCTarget)
            }
        }
        .environment(\.rootTabBarVisibility, isInTabNavigation ? rootTabBarVisibility : nil)
        .onReceive(dependencies.remoteLibrary.failurePublisher) { failure in
            resourceFailureAlert.receive(failure, bookID: bookId, isReady: remoteReady)
        }
        .alert(
            localized("遠端內容載入失敗"),
            isPresented: Binding(
                get: { resourceFailureAlert.failure != nil },
                set: { if !$0 { resourceFailureAlert.dismiss() } }
            ),
            presenting: resourceFailureAlert.failure
        ) { _ in
            Button(localized("關閉")) { closeReader() }
            Button(localized("取消"), role: .cancel) { resourceFailureAlert.dismiss() }
        } message: { failure in
            Text(failure.message)
        }
        .task(id: retryGeneration) {
            guard book?.remoteSource != nil else { return }
            if !holdsCache {
                RemoteLibraryCache.shared.retain(bookId)
                holdsCache = true
            }
            remoteError = nil
            do {
                _ = try await dependencies.remoteLibrary.prepare(bookID: bookId, store: store)
                try Task.checkCancellation()
                remoteReady = true
            } catch is CancellationError {
                // Navigation cancellation leaves the persisted reading position intact.
            } catch {
                remoteError = error.localizedDescription
            }
        }
        .task(id: bookId) {
            guard let book, book.aozora != nil, !aozoraReady else { return }
            do {
                _ = try await AozoraBookRegenerator.prepare(book: book, store: store, readerID: resourceOwnerID)
            } catch is CancellationError {
                return
            } catch {
                // Opening never waits on a failure: the existing EPUB still reads.
                AppLogger.error("Aozora regeneration failed; opening the existing EPUB", error: error,
                                context: ["book": bookId.uuidString])
            }
            aozoraReady = true
        }
        .onAppear {
            ReadingResourceUsage.shared.retain(bookID: bookId, ownerID: resourceOwnerID)
            if let book {
                CrashContext.setKey("current_book", "\(book.title) [\(book.id.uuidString.prefix(8))]")
                CrashContext.setKey("current_book_kind", "\(book.resolvedPipelineKind)")
                CrashContext.setKey("current_book_online", book.isOnline)
                CrashContext.breadcrumb("open reader: \(book.title) (\(book.resolvedPipelineKind))")
                // Every open is the book's newest, from 作品詳情, 探索, 搜索 or a modal alike, and
                // once: coming back from a page pushed above the reader is not another open.
                // The shelf's card transition stamps its open itself once the card has landed
                // (`HomeView.openBook`), so a 最近閱讀 shelf does not move the source cover mid-open.
                if !stampedOpen, readerNavigator == nil {
                    stampedOpen = true
                    store.updateLastOpened(bookId: bookId)
                }
            }
        }
        .onDisappear {
            let releasedLastReader = ReadingResourceUsage.shared.release(bookID: bookId, ownerID: resourceOwnerID)
            if holdsCache {
                RemoteLibraryCache.shared.release(bookId)
                if releasedLastReader { dependencies.remoteLibrary.release(bookID: bookId) }
                holdsCache = false
                remoteReady = false
            }
            CrashContext.breadcrumb("close reader")
        }
    }

    private func closeReader() {
        if let readerNavigator {
            readerNavigator.close()
        } else {
            // Pushed library readers and modal readers use their owning SwiftUI
            // presentation. Closing also cancels the view's preparation task.
            presentationMode.wrappedValue.dismiss()
        }
    }

    /// Pushed onto a tab's navigation — by 書架's card transition or onto a detail page's
    /// stack — the reader hides the root tab bar from every tab (`RootTabBarVisibility`).
    /// A modal reader covers the tab bar instead, and so does everything pushed inside it:
    /// asking from there would only hide the bar behind the cover, for it to jump back in
    /// once the cover has slid away.
    private var isInTabNavigation: Bool {
        readerNavigator != nil || usesParentNavigationStack
    }

    private var shouldUseFixedPageReader: Bool {
        guard let kind = book?.resolvedPipelineKind else { return false }
        return kind == .manga || kind == .fixedPage
    }

    private var isAudiobook: Bool { book?.resolvedPipelineKind == .audio }
}

/// A book being readied before its reader can open — a library's copy downloading, a 青空文庫
/// work imported (`AozoraReaderEntry`) or brought up to this build's converter: the reader's
/// own 載入中…, full screen on the surface the reader opens on. Until 2026-10-27 this was a
/// page of its own, 正在開啟書籍 and 取消 on the app's background, and a reader pushed in a tab
/// showed it under the tab bar and the status bar (maintainer: 「統一都是加載中」).
struct ReaderPreparingView: View {
    let error: String?
    var onRetry: () -> Void
    var onClose: () -> Void
    @Bindable private var settings = GlobalSettings.shared
    @ObservedObject private var readerConfig = ReaderConfig.shared

    var body: some View {
        // What the reader puts on as it opens (`ReaderView.syncActiveThemePreset`).
        let resolution = settings.readerBackgroundResolution(mode: settings.readerMode, wornTheme: readerConfig.theme)
        ReaderPreparingSurface(
            theme: resolution.theme,
            imageURL: settings.readerBackgroundImageURL(wearing: resolution),
            backIcon: ReaderChromePalette(theme: resolution.theme, settings: settings).topIcon,
            error: error,
            onRetry: onRetry,
            onClose: onClose
        )
    }
}

/// `ReaderPreparingView` on a given surface. As on the reader's loading page, a tap raises the
/// reading menu with the status bar; before there is a book to show, its menu is 退出閱讀.
private struct ReaderPreparingSurface: View {
    let theme: ReaderTheme
    let imageURL: URL?
    let backIcon: Color
    let error: String?
    var onRetry: () -> Void
    var onClose: () -> Void
    @State private var showsChrome = false

    /// A failure page has its own way out, so a tap raises nothing over it, as in the reader.
    private var chromeIsShown: Bool { showsChrome && error == nil }

    var body: some View {
        // The reader's own stack, where it has one: shown full screen or by the shelf's card,
        // with no stack above it to put 退出閱讀 in.
        ReaderNavigationContainer {
            ZStack {
                ReaderSurfaceBackground(theme: theme, imageURL: imageURL)
                if let error {
                    BookOpenFailureView(
                        message: error,
                        titleColor: theme.textColor,
                        detailColor: theme.textColor.opacity(0.62),
                        onRetry: onRetry,
                        onClose: onClose
                    )
                } else {
                    ProgressView(localized("載入中…"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .readerLoadingChromeTap {
                            withAnimation(DSAnimation.readerChrome) { showsChrome.toggle() }
                        }
                }
            }
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onClose) {
                        Label(localized("退出閱讀"), systemImage: "chevron.left")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(backIcon)
                    }
                    .accessibilityIdentifier("reader_back_button")
                    .accessibilityLabel(localized("退出閱讀"))
                }
            }
            .toolbar(chromeIsShown ? .visible : .hidden, for: .navigationBar)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(theme == .night ? .dark : .light, for: .navigationBar)
            // Inside the stack, where the reader applies them too: that layer reaches the
            // hosting controller through the stack.
            .statusBarHidden(
                ReaderOverlayPresentationPolicy.hidesStatusBar(showsReaderChrome: chromeIsShown, isEditing: false)
            )
            .persistentSystemOverlays(
                ReaderOverlayPresentationPolicy.hidesHomeIndicator(showsReaderChrome: chromeIsShown, isEditing: false)
                    ? .hidden : .automatic
            )
            .hidesRootTabBar()
        }
        .tint(theme.textColor)
    }
}

/// 「無法開啟書籍」, the one page for a book that cannot be opened: before the format
/// reader mounts (`ReaderPreparingView`), and inside `ReaderView` when a local EPUB
/// fails to open. The reader draws it on the reading background, so it passes the
/// reader's text colours; elsewhere the app's apply.
struct BookOpenFailureView: View {
    let message: String
    var titleColor: Color?
    var detailColor: Color?
    var onRetry: () -> Void
    var onClose: () -> Void

    var body: some View {
        ContentUnavailableView {
            UnavailableLabel(
                localized("無法開啟書籍"),
                systemImage: "exclamationmark.triangle",
                titleColor: titleColor,
                symbolColor: detailColor
            )
        } description: {
            Text(message).foregroundStyle(detailColor ?? DSColor.textSecondary)
        } actions: {
            Button(localized("重試"), action: onRetry)
            Button(localized("關閉"), action: onClose)
        }
    }
}

#Preview("Preparing · reader's surface") {
    ReaderPreparingView(error: nil, onRetry: {}, onClose: {})
}

#Preview("Preparing · 黑色") {
    ReaderPreparingSurface(
        theme: .night, imageURL: nil, backIcon: ReaderTheme.night.previewTextColor,
        error: nil, onRetry: {}, onClose: {}
    )
}

#Preview("Preparing · error") {
    ReaderPreparingView(error: localized("認證失敗，請確認帳號和密碼"), onRetry: {}, onClose: {})
}

#Preview("Local EPUB failure in the reader") {
    // 黑色 in light mode: the case the reader's own colours are for.
    let text = ReaderTheme.night.previewTextColor
    BookOpenFailureView(
        message: localized("檔案可能已損毀，或不是支援的 EPUB 格式。"),
        titleColor: text,
        detailColor: text.opacity(0.62),
        onRetry: {},
        onClose: {}
    )
    .tint(text)
    .background(ReaderTheme.night.previewBackgroundColor)
    .preferredColorScheme(.light)
}
