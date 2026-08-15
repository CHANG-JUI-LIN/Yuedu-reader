import Combine
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Bookshelf Home
enum BookshelfCoverLoader {
    static func load(filename: String) -> UIImage? {
        guard let data = try? Data(contentsOf: StorageLocations.coverFile(filename)) else { return nil }
        return UIImage(data: data)
    }
}

@MainActor
private final class BookshelfReaderGeometryStore: ObservableObject {
    private var frames: [UUID: CGRect] = [:]

    func update(_ frame: CGRect, for bookID: UUID) {
        guard !frame.isEmpty else { return }
        frames[bookID] = frame
    }

    func frame(for bookID: UUID) -> CGRect? {
        frames[bookID]
    }

    func invalidate(bookID: UUID) {
        frames[bookID] = nil
    }
}

private struct BookshelfCoverFramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isEmpty { value = next }
    }
}

private enum BookshelfImportPresentationRoute: Hashable {
    case local
    case webDAV
    case opds
}

private extension View {
    func reportBookshelfCoverFrame(_ frame: Binding<CGRect>) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: BookshelfCoverFramePreferenceKey.self,
                    value: proxy.frame(in: .global)
                )
            }
        }
        .onPreferenceChange(BookshelfCoverFramePreferenceKey.self) { newFrame in
            if !newFrame.isEmpty { frame.wrappedValue = newFrame }
        }
    }
}

struct HomeView: View {
    @EnvironmentObject var store: BookStore
    @Environment(\.appDependencies) private var appDependencies
    @ObservedObject private var gs = GlobalSettings.shared

    @State private var showAddSheet = false
    @State private var showWebDAVImport = false
    @State private var showOPDSImport = false
    @State private var addSheetSessionID = UUID()
    @State private var showLegacyImportChooser = false
    @State private var legacyImportSequence =
        DismissalSequencedPresentation<BookshelfImportPresentationRoute>()
    @State private var editingBook: ReadingBook? = nil
    @State private var bookToDelete: ReadingBook? = nil
    @State private var selectedOnlineBookDetail: OnlineBook? = nil
    @State private var editMode = EditMode.inactive
    @State private var selectedGroup: String = ""
    @State private var selectedBookIds: Set<UUID> = []
    @State private var showBulkDeleteAlert = false
    @State private var showAddToGroupSheet = false
    @AppStorage("bookLayoutIsGrid") private var isGridMode = false
    @AppStorage("bookSortOrder") private var sortOrder = BookSortOrder.manual.rawValue
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Namespace private var bookTransition

    private var hInset: CGFloat { sizeClass == .regular ? 32 : 20 }
    private var isCompactFiveColumnGrid: Bool { gs.bookshelfGridColumnCount >= 5 }
    private var gridHorizontalInset: CGFloat {
        sizeClass == .regular ? 32 : (isCompactFiveColumnGrid ? DSSpacing.lg : hInset)
    }
    private var gridColumnSpacing: CGFloat {
        isCompactFiveColumnGrid ? DSSpacing.sm : DSSpacing.md
    }
    private var gridColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: gridColumnSpacing, alignment: .top),
            count: gs.bookshelfGridColumnCount
        )
    }

    @StateObject private var readerCoordinator = ReaderNavigationCoordinator()
    @StateObject private var readerGeometryStore = BookshelfReaderGeometryStore()
    @State private var pendingReaderOpenToken: UUID?

    /// Reader id presented modally (kept fullScreenCover) for kinds that are
    /// explicitly out of scope for the card-navigation migration: audiobook,
    /// manga, fixed-page. Text / reflowable EPUB / online HTML go through the
    /// `readerCoordinator` push path instead.
    @State private var modalReaderBookId: UUID? = nil

    #if DEBUG
    /// DEBUG: `-open-book <titleSubstring>` opens the first shelf book whose
    /// title contains the substring. Runs once from onAppear (after the shelf
    /// is mounted) — a launch-arg hook for diagnostics, never in Release.
    @State private var didHandleDebugOpenBook = false

    private func handleDebugOpenBookIfNeeded() {
        guard !didHandleDebugOpenBook else { return }
        didHandleDebugOpenBook = true
        let args = ProcessInfo.processInfo.arguments
        guard let idx = args.firstIndex(of: "-open-book"),
              args.indices.contains(idx + 1) else { return }
        let needle = args[idx + 1]
        guard let book = store.books.first(where: { $0.title.contains(needle) }) else { return }
        openBook(book, sourceGeometry: nil)
    }
    #endif

    private func openBook(_ book: ReadingBook, sourceGeometry: ReaderCardGeometry?) {
        AppLogger.info("⟐ openBook tap bookID=\(book.id) title=\(book.title) pipelineKind=\(book.resolvedPipelineKind) useCard=\(BookCardNavigationGate.shouldUseCardTransition(for: book)) hasGeometry=\(sourceGeometry != nil)")
        if BookCardNavigationGate.shouldUseCardTransition(for: book) {
            // Re-entrancy guard: once a card open is staged (readerBookID set)
            // or the reader is already on screen, ignore further shelf taps.
            // An impatient double-tap otherwise fired a second open *after*
            // the reader controller had been pushed onto the shelf's SwiftUI
            // NavigationStack. That second pass reconciled the directly-pushed
            // controller back off the stack ("flash back to shelf"), and
            // because the removal never went through the coordinator it stayed
            // convinced a reader was still presented — refusing every later
            // open (the "can't get back into the reader" lock). Blocking here
            // makes a double-tap behave exactly like a single tap.
            if readerCoordinator.shouldIgnoreOpenRequest() {
                AppLogger.info("⟐ openBook ignored re-entrant tap bookID=\(book.id) presented=\(readerCoordinator.isReaderPresented) activeBook=\(String(describing: readerCoordinator.activeBookID))")
                return
            }
            let requestToken = UUID()
            pendingReaderOpenToken = requestToken
            AppLogger.info("⟐ openBook staged token=\(requestToken) hasPendingToken=\(pendingReaderOpenToken != nil)")
            let snapshot: UIImage? = book.coverImagePath.flatMap {
                BookshelfCoverLoader.load(filename: $0)
            }
            AppLogger.info("⟐ openBook snapshot resolved hasSnapshot=\(snapshot != nil)")
            Task { @MainActor in
                AppLogger.info("⟐ openBook begin resolveOpeningDirection bookID=\(book.id)")
                let direction = await resolveOpeningDirection(for: book)
                guard pendingReaderOpenToken == requestToken else {
                    AppLogger.info("⟐ openBook DROPPED: token mismatch (newTap=\(String(describing: pendingReaderOpenToken))) stale=\(requestToken)")
                    return
                }
                pendingReaderOpenToken = nil
                AppLogger.info("⟐ openBook direction resolved=\(direction) calling coordinator.open")
                #if compiler(>=6.2)
                weak let geometryStore = readerGeometryStore
                weak let transitionBookStore = store
                weak let navigator = readerCoordinator
                #else
                weak var geometryStore = readerGeometryStore
                weak var transitionBookStore = store
                weak var navigator = readerCoordinator
                #endif
                let source = ReaderTransitionSource(
                    bookID: book.id,
                    cornerRadius: sourceGeometry?.cornerRadius ?? DSRadius.md,
                    frame: sourceGeometry?.frame,
                    frameProvider: {
                        guard transitionBookStore?.books.contains(where: { $0.id == book.id }) == true else {
                            return nil
                        }
                        return geometryStore?.frame(for: book.id)
                    },
                    snapshot: snapshot,
                    direction: direction
                )
                let shouldInvalidateForRecentSort =
                    sortOrder == BookSortOrder.recentlyRead.rawValue
                    && sortedFilteredBooks.first?.id != book.id
                let readerBookID = book.id
                let readerStore = store
                let readerDependencies = appDependencies
                readerCoordinator.open(
                    bookID: readerBookID,
                    source: source,
                    destination: {
                        ReaderHostingController(content: AnyView(
                            BookReaderView(bookId: readerBookID)
                                .environmentObject(readerStore)
                                .environment(\.appDependencies, readerDependencies)
                                .environment(\.readerNavigator, navigator)
                        ))
                    },
                    onTransitionCompleted: {
                        if shouldInvalidateForRecentSort {
                            // Do not let a closing transition use the old row
                            // position while the recently-read sort moves it.
                            geometryStore?.invalidate(bookID: readerBookID)
                        }
                        transitionBookStore?.updateLastOpened(bookId: readerBookID)
                    }
                )
            }
        } else {
            AppLogger.info("⟐ openBook MODAL path bookID=\(book.id) (audiobook/manga/fixed-page)")
            pendingReaderOpenToken = nil
            store.updateLastOpened(bookId: book.id)
            modalReaderBookId = book.id
        }
    }

    private func resolveOpeningDirection(
        for book: ReadingBook
    ) async -> ReaderBookOpeningDirection {
        if book.resolvedPipelineKind == .epub {
            let url = store.localEPUBURL(for: book)
            AppLogger.info("⟐ resolveOpeningDirection EPUB url=\(url.lastPathComponent) starting inspect")
            let t0 = CACurrentMediaTime()
            let flow = await PublicationSession.inspectOpeningFlow(sourceURL: url)
            let direction = ReaderBookOpeningDirection.resolve(
                writingMode: flow.isVertical ? .verticalRTL : .horizontal,
                pageProgressionIsRTL: flow.pageProgressionIsRTL
            )
            let elapsed = (CACurrentMediaTime() - t0) * 1000
            AppLogger.info("⟐ resolveOpeningDirection EPUB done elapsedMs=\(Int(elapsed)) isVertical=\(flow.isVertical) pageProgressionRTL=\(flow.pageProgressionIsRTL) direction=\(direction)")
            return direction
        }

        let writingMode: ReaderWritingMode = book.allowsVerticalWritingMode
            ? gs.readerWritingMode
            : .horizontal
        if !book.allowsVerticalWritingMode {
            AppLogger.info("⟐ resolveOpeningDirection book denies vertical writing mode; using horizontal")
        }
        let direction = ReaderBookOpeningDirection.resolve(
            writingMode: writingMode,
            pageProgressionIsRTL: false
        )
        AppLogger.info("⟐ resolveOpeningDirection non-EPUB done direction=\(direction)")
        return direction
    }

    var sortedFilteredBooks: [ReadingBook] {
        let base = selectedGroup.isEmpty ? store.books : store.books.filter { $0.group == selectedGroup }
        switch BookSortOrder(rawValue: sortOrder) ?? .manual {
        case .manual:       return base
        case .recentlyRead: return base.sorted {
            ($0.lastOpenedDate ?? $0.addedDate) > ($1.lastOpenedDate ?? $1.addedDate)
        }
        case .title:        return base.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
        case .author:       return base.sorted { $0.author.localizedCompare($1.author) == .orderedAscending }
        }
    }

    private var isAllSelected: Bool {
        !sortedFilteredBooks.isEmpty && selectedBookIds.count == sortedFilteredBooks.count
    }

    /// Local file URLs of the currently selected books, for the share sheet. Online books (no local file)
    /// are skipped.
    private var selectedShareableURLs: [URL] {
        selectedBookIds
            .compactMap { id in store.books.first(where: { $0.id == id }) }
            .compactMap { store.shareableFileURL(for: $0) }
    }

    var body: some View {
        NavigationStack {
            AdaptiveContentContainer(maxWidth: DSLayout.readableShelfWidth) {
                Group {
                    if store.books.isEmpty {
                        EmptyLibraryView(showAdd: $showAddSheet)
                            .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    } else {
                        VStack(spacing: 0) {
                            if !store.allGroups.isEmpty {
                                groupFilterBar
                            }
                            if isGridMode {
                                bookGrid
                            } else {
                                bookList
                            }
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    }
                }
            }
            .themedAppSurface(for: .bookshelf)
            .animation(DSAnimation.standard, value: store.books.isEmpty)
            .navigationTitle(localized("書架"))
            .toolbarTitleDisplayModeInlineLargeOrInline()
            .toolbar {
                if editMode == .active {
                    // Select-all kept as its own pill via the prominent + clear-tint
                    // trick so it doesn't merge with the done button.
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            if isAllSelected {
                                selectedBookIds = []
                            } else {
                                selectedBookIds = Set(sortedFilteredBooks.map(\.id))
                            }
                        } label: {
                            Text(localized(isAllSelected ? "全不選" : "全選"))
                                .font(DSFont.subheadline.weight(.medium))
                                .foregroundColor(.primary)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.clear)
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            withAnimation {
                                editMode = .inactive
                                selectedBookIds = []
                            }
                        } label: {
                            Image(systemName: "checkmark")
                                .font(DSFont.toolbarIcon)
                        }
                    }
                    // Native bottom toolbar: delete · add-to-group · share.
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button(role: .destructive) {
                            if !selectedBookIds.isEmpty { showBulkDeleteAlert = true }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .tint(.red)
                        .disabled(selectedBookIds.isEmpty)
                        .accessibilityLabel(localized("刪除"))

                        Spacer()

                        Button {
                            if !selectedBookIds.isEmpty { showAddToGroupSheet = true }
                        } label: {
                            Label(" "+localized("加入分組"), systemImage: "text.badge.plus")
                                .labelStyle(.titleAndIcon)
                        }
                        .disabled(selectedBookIds.isEmpty)
                        .buttonStyle(.borderless)

                        Spacer()

                        ShareLink(items: selectedShareableURLs) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .disabled(selectedShareableURLs.isEmpty)
                        .accessibilityLabel(localized("分享"))
                    }
                } else {
                    // Two separate glass pills. A ToolbarSpacer (iOS 26+) breaks the
                    // auto-merge so the two menus sit in their own glass instead of
                    // fusing into one. Order swapped: options (…) leads, add (+) trails.
                    ToolbarItem(placement: .navigationBarTrailing) {
                        bookshelfOptionsMenu
                    }
                    #if compiler(>=6.2)
                    if #available(iOS 26.0, *) {
                        ToolbarSpacer(.fixed, placement: .navigationBarTrailing)
                    }
                    #endif
                    ToolbarItem(placement: .navigationBarTrailing) {
                        addBookMenu
                    }
                }
            }
            // In edit mode, hide the app tab bar so the contextual .bottomBar (delete / group / share)
            // takes its place — the system selection pattern used by Photos / Files.
            .toolbar(editMode == .active ? .hidden : .automatic, for: .tabBar)
            .sheet(
                isPresented: $showLegacyImportChooser,
                onDismiss: presentLegacyImportAfterChooserDismissal
            ) {
                AdaptiveSheetContainer(maxWidth: DSLayout.readableCompactWidth) {
                    DismissalSequencedActionChooser(
                        title: localized("添加書籍"),
                        actions: [
                            DismissalSequencedAction(
                                route: .local,
                                title: localized("從本地匯入"),
                                systemImage: "folder"
                            ),
                            DismissalSequencedAction(
                                route: .webDAV,
                                title: localized("從 WebDAV 匯入"),
                                systemImage: "externaldrive.connected.to.line.below"
                            ),
                            DismissalSequencedAction(
                                route: .opds,
                                title: localized("從 OPDS 匯入"),
                                systemImage: "books.vertical"
                            ),
                        ],
                        onSelect: { legacyImportSequence.select($0) }
                    )
                }
            }
            .sheet(isPresented: $showAddSheet) {
                AdaptiveSheetContainer(maxWidth: DSLayout.readableListWidth) {
                    AddBookView()
                        .id(addSheetSessionID)
                        .environmentObject(store)
                }
            }
            .onChange(of: showAddSheet) { _, isPresented in
                if isPresented {
                    addSheetSessionID = UUID()
                }
            }
            .sheet(isPresented: $showWebDAVImport) {
                AdaptiveSheetContainer(maxWidth: DSLayout.readableListWidth) {
                    WebDAVImportView().environmentObject(store)
                }
            }
            .sheet(isPresented: $showOPDSImport) {
                AdaptiveSheetContainer(maxWidth: DSLayout.readableListWidth) {
                    OPDSImportView().environmentObject(store)
                }
            }
            .navigationDestination(item: $selectedOnlineBookDetail) { book in
                if BookSourceStore.shared.isAudiobook(book) {
                    AudiobookDetailView(book: book, onRemoveFromShelf: {
                        selectedOnlineBookDetail = nil
                    })
                        .environmentObject(store)
                } else {
                    OnlineBookView(book: book, onRemoveFromShelf: {
                        selectedOnlineBookDetail = nil
                    })
                        .environmentObject(store)
                }
            }
            // 書籍資訊 owns the cover pickers, so on iOS 17 it is pushed rather
            // than presented (`BookInfoEditPresentationPolicy`); iOS 18 keeps the
            // sheet. Two bindings, one screen — the same shape ProfileView uses
            // for book-source management.
            .navigationDestination(item: pushedEditingBookId) { bookId in
                if let book = store.books.first(where: { $0.id == bookId }) {
                    EditBookSheet(book: book, presentation: .push) { newTitle, newAuthor, newGroup in
                        store.updateBook(bookId: book.id, title: newTitle, author: newAuthor)
                        store.setGroup(newGroup, for: book.id)
                    }
                    .environmentObject(store)
                }
            }
            .sheet(item: sheetEditingBook) { book in
                AdaptiveSheetContainer(maxWidth: DSLayout.readableCompactWidth) {
                    EditBookSheet(book: book) { newTitle, newAuthor, newGroup in
                        store.updateBook(bookId: book.id, title: newTitle, author: newAuthor)
                        store.setGroup(newGroup, for: book.id)
                    }
                    .environmentObject(store)
                }
            }
            .alert(
                localized("確認刪除"),
                isPresented: Binding(
                    get: { bookToDelete != nil },
                    set: { if !$0 { bookToDelete = nil } }
                )
            ) {
                Button(localized("刪除"), role: .destructive) {
                    if let b = bookToDelete { store.delete(bookId: b.id) }
                }
                Button(localized("取消"), role: .cancel) {}
            } message: {
                if let b = bookToDelete {
                    Text(localized("確定要從書架刪除") + "《\(b.title)》" + localized("嗎？"))
                }
            }
            .alert(localized("確認刪除"), isPresented: $showBulkDeleteAlert) {
                Button(localized("刪除"), role: .destructive) {
                    let ids = selectedBookIds
                    withAnimation(.easeOut(duration: 0.25)) {
                        ids.forEach { store.delete(bookId: $0) }
                        selectedBookIds = []
                    }
                }
                Button(localized("取消"), role: .cancel) {}
            } message: {
                Text(localized("確定要刪除") + " \(selectedBookIds.count) " + localized("本書嗎？"))
            }
            .sheet(isPresented: $showAddToGroupSheet) {
                AdaptiveSheetContainer(maxWidth: DSLayout.readableNarrowWidth) {
                    BulkAddToGroupSheet(bookCount: selectedBookIds.count) { group in
                        for id in selectedBookIds {
                            store.setGroup(group, for: id)
                        }
                        selectedBookIds = []
                        withAnimation { editMode = .inactive }
                    }
                    .environmentObject(store)
                }
            }
            // Keep the probe inside this NavigationStack's root destination.
            // Its responder chain resolves this shelf's UIKit navigation
            // controller before the coordinator directly pushes the reader,
            // rather than guessing among sibling stacks owned by TabView.
            .background {
                ReaderEdgeSwipeEnabler(navigator: readerCoordinator)
                    .frame(width: 0, height: 0)
                    #if DEBUG
                    .onAppear {
                        handleDebugOpenBookIfNeeded()
                    }
                    #endif
            }
        }
        // Non-migrated reader kinds (audiobook / manga / fixed-page) keep the
        // original modal presentation. They are explicitly out of scope for the
        // first delivery of the card-navigation migration.
        .fullScreenCover(
            isPresented: Binding(
                get: { modalReaderBookId != nil },
                set: { if !$0 { modalReaderBookId = nil } }
            )
        ) {
            if let bookId = modalReaderBookId {
                BookReaderView(bookId: bookId)
                    .environmentObject(store)
            }
        }
    }

    private func presentLegacyImportAfterChooserDismissal() {
        guard let route = legacyImportSequence.consumeAfterDismissal() else {
            return
        }
        switch route {
        case .local:
            addSheetSessionID = UUID()
            showAddSheet = true
        case .webDAV:
            showWebDAVImport = true
        case .opds:
            showOPDSImport = true
        }
    }

    @ViewBuilder
    private var addBookMenu: some View {
        if MenuModalPresentationPolicy.requiresDismissalSequencedChooser {
            Button {
                legacyImportSequence.cancel()
                showLegacyImportChooser = true
            } label: {
                Image(systemName: "plus")
                    .font(DSFont.toolbarIcon)
            }
        } else {
            Menu {
                Button {
                    addSheetSessionID = UUID()
                    showAddSheet = true
                } label: {
                    Label(localized("從本地匯入"), systemImage: "folder")
                }
                Button {
                    showWebDAVImport = true
                } label: {
                    Label(localized("從 WebDAV 匯入"),
                          systemImage: "externaldrive.connected.to.line.below")
                }
                Button {
                    showOPDSImport = true
                } label: {
                    Label(localized("從 OPDS 匯入"), systemImage: "books.vertical")
                }
            } label: {
                Image(systemName: "plus")
                    .font(DSFont.toolbarIcon)
            }
            .id("\(Locale.autoupdatingCurrent.identifier)_add_menu")
        }
    }

    private var bookshelfOptionsMenu: some View {
        Menu {
            Button {
                withAnimation { editMode = .active }
            } label: {
                Label(localized("選取"), systemImage: "checkmark.circle")
            }

            Divider()

            Picker("", selection: $isGridMode) {
                Label(localized("列表"), systemImage: "list.bullet").tag(false)
                Label(localized("格狀"), systemImage: "square.grid.2x2").tag(true)
            }
            .pickerStyle(.inline)
            .labelsHidden()

            Divider()

            Picker("", selection: $sortOrder) {
                Text(localized("最近閱讀")).tag(BookSortOrder.recentlyRead.rawValue)
                Text(localized("書名")).tag(BookSortOrder.title.rawValue)
                Text(localized("作者")).tag(BookSortOrder.author.rawValue)
                Text(localized("手動")).tag(BookSortOrder.manual.rawValue)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Image(systemName: "ellipsis")
                .font(DSFont.toolbarIcon)
        }
        .id("\(Locale.autoupdatingCurrent.identifier)_menu")
    }

    // MARK: - Group Filter Bar
    private var groupFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DSSpacing.sm) {
                DSChip(title: localized("全部"), isSelected: selectedGroup.isEmpty) {
                    withAnimation { selectedGroup = "" }
                }
                ForEach(store.allGroups, id: \.self) { group in
                    DSChip(title: group, isSelected: selectedGroup == group) {
                        withAnimation { selectedGroup = group }
                    }
                }
            }
            .padding(.horizontal, DSSpacing.lg).padding(.vertical, 6)
        }
    }


    // MARK: - Book List
    private var bookList: some View {
        // Native multi-select: binding the selection Set drives the system selection circles in edit mode.
        List(selection: $selectedBookIds) {
            ForEach(sortedFilteredBooks) { book in
                BookRow(
                    book: book,
                    isEditing: editMode == .active,
                    transitionNamespace: bookTransition,
                    onTap: { sourceGeometry in
                        openBook(book, sourceGeometry: sourceGeometry)
                    },
                    onCoverFrameChange: { frame in
                        readerGeometryStore.update(frame, for: book.id)
                    },
                    onEdit: { editingBook = book },
                    onDelete: { bookToDelete = book },
                    onShowDetail: canShowOnlineBookDetail(for: book)
                        ? { showOnlineBookDetail(for: book) }
                        : nil
                )
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: hInset, bottom: 0, trailing: hInset))
                .listRowBackground(Color.clear)
                .transition(.opacity.combined(with: .move(edge: .leading)))
            }
            .onMove { src, dst in
                guard sortOrder == BookSortOrder.manual.rawValue else { return }
                let filtered = sortedFilteredBooks
                let movingIds = src.map { filtered[$0].id }
                let targetId: UUID? = dst < filtered.count ? filtered[dst].id : nil
                store.moveBooks(ids: movingIds, before: targetId)
            }
        }
        .listStyle(.plain)
        .environment(\.editMode, $editMode)
        .animation(.easeOut(duration: 0.25), value: sortedFilteredBooks.map(\.id))
        .accessibilityIdentifier("home_book_list")
        .refreshable {
            await ChapterUpdater.refreshAll(bookStore: store)
        }
    }

    // MARK: - Book Grid
    private var bookGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: gridColumns,
                spacing: DSSpacing.lg
            ) {
                ForEach(sortedFilteredBooks) { book in
                    BookGridCell(
                        book: book,
                        isCompactLayout: isCompactFiveColumnGrid,
                        transitionNamespace: bookTransition,
                        onOpen: { sourceGeometry in
                            openBook(book, sourceGeometry: sourceGeometry)
                        },
                        onCoverFrameChange: { frame in
                            readerGeometryStore.update(frame, for: book.id)
                        },
                        onEdit: { editingBook = book },
                        onDelete: { bookToDelete = book },
                        onShowDetail: canShowOnlineBookDetail(for: book)
                            ? { showOnlineBookDetail(for: book) }
                            : nil
                    )
                }
            }
            .padding(.horizontal, gridHorizontalInset)
            .padding(.vertical, DSSpacing.md)
        }
        .animation(.easeOut(duration: 0.25), value: sortedFilteredBooks.map(\.id))
        .animation(DSAnimation.standard, value: gs.bookshelfGridColumnCount)
        .refreshable {
            await ChapterUpdater.refreshAll(bookStore: store)
        }
    }

    /// 書籍資訊 as a pushed destination (iOS 17) — nil on iOS 18+. Carries the id
    /// rather than the book because `navigationDestination(item:)` needs a
    /// Hashable value, and the editor reads the live record from the store anyway.
    private var pushedEditingBookId: Binding<UUID?> {
        Binding(
            get: {
                BookInfoEditPresentationPolicy.prefersNavigationDestination
                    ? editingBook?.id
                    : nil
            },
            set: { if $0 == nil { editingBook = nil } }
        )
    }

    /// 書籍資訊 as a sheet (iOS 18+) — nil on iOS 17.
    private var sheetEditingBook: Binding<ReadingBook?> {
        Binding(
            get: {
                BookInfoEditPresentationPolicy.prefersNavigationDestination
                    ? nil
                    : editingBook
            },
            set: { if $0 == nil { editingBook = nil } }
        )
    }

    private func canShowOnlineBookDetail(for book: ReadingBook) -> Bool {
        book.isOnline && book.bookSourceId != nil
    }

    private func showOnlineBookDetail(for book: ReadingBook) {
        selectedOnlineBookDetail = onlineBookDetail(for: book)
    }

    private func onlineBookDetail(for book: ReadingBook) -> OnlineBook? {
        guard book.isOnline, let sourceId = book.bookSourceId else { return nil }
        let source = BookSourceStore.shared.sources.first(where: { $0.id == sourceId })
        return OnlineBook(
            name: book.title,
            author: book.author,
            intro: "",
            coverUrl: book.coverUrl ?? "",
            bookUrl: book.bookInfoURL ?? book.source,
            tocUrl: book.tocURL ?? "",
            wordCount: "",
            lastChapter: book.latestChapterDisplayTitle ?? "",
            kind: "",
            sourceId: sourceId,
            sourceName: source?.bookSourceName ?? "",
            runtimeVariables: book.runtimeVariables
        )
    }
}

// MARK: - Edit Book Info Sheet

/// How 書籍資訊 is being shown. On iOS 17 the bookshelf pushes it so its image
/// pickers are first-level presentations — see `BookInfoEditPresentationPolicy`.
enum BookInfoEditPresentation {
    case sheet
    case push
}

struct EditBookSheet: View {
    let book: ReadingBook
    var presentation: BookInfoEditPresentation = .sheet
    let onSave: (String, String, String) -> Void

    @State private var titleInput: String
    @State private var authorInput: String
    @State private var groupInput: String
    @State private var coverUrlInput: String
    @State private var isApplyingCover = false
    @State private var coverErrorMessage: String?
    @Environment(\.presentationMode) var dismiss
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @EnvironmentObject private var store: BookStore

    init(
        book: ReadingBook,
        presentation: BookInfoEditPresentation = .sheet,
        onSave: @escaping (String, String, String) -> Void
    ) {
        self.book = book
        self.presentation = presentation
        self.onSave = onSave
        _titleInput = State(initialValue: book.title)
        _authorInput = State(initialValue: book.author)
        _groupInput = State(initialValue: book.group)
        // The remote address currently in effect: the user's own if they set one,
        // otherwise whatever the source gave us, so the field starts truthful.
        let customUrl = book.customCoverUrl == ReadingBook.localCustomCoverMarker
            ? nil
            : book.customCoverUrl
        _coverUrlInput = State(initialValue: customUrl ?? book.coverUrl ?? "")
    }

    /// The book as the store currently has it — `book` is the snapshot the sheet
    /// was opened with, and every cover action writes through the store.
    private var liveBook: ReadingBook {
        store.books.first { $0.id == book.id } ?? book
    }

    var body: some View {
        switch presentation {
        case .sheet:
            NavigationStack {
                editorContent
                    .toolbarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                dismiss.wrappedValue.dismiss()
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .accessibilityLabel(localized("關閉"))
                        }
                        saveToolbarItem
                    }
            }
        case .push:
            // Pushed from the shelf: the back button is the way out, so no 關閉.
            editorContent
                .toolbarTitleDisplayMode(.inlineLarge)
                .toolbar { saveToolbarItem }
        }
    }

    private var saveToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                onSave(titleInput, authorInput, groupInput)
                dismiss.wrappedValue.dismiss()
            } label: {
                Image(systemName: "checkmark")
            }
            .accessibilityLabel(localized("完成"))
            .disabled(titleInput.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var editorContent: some View {
            AdaptiveSheetContainer(maxWidth: DSLayout.readableCompactWidth) {
                Form {
                    coverSection

                    Section(header: Text(localized("基本資訊"))) {
                        HStack {
                            Text(localized("書名"))
                            Spacer()
                            TextField(localized("書名"), text: $titleInput)
                                .multilineTextAlignment(.trailing)
                        }
                        HStack {
                            Text(localized("作者"))
                            Spacer()
                            TextField(localized("作者"), text: $authorInput)
                                .multilineTextAlignment(.trailing)
                        }
                        HStack {
                            Text(localized("分組"))
                            Spacer()
                            TextField(localized("未分組"), text: $groupInput)
                                .multilineTextAlignment(.trailing)
                        }
                        if !store.allGroups.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(store.allGroups, id: \.self) { g in
                                        Button(g) { groupInput = g }
                                            .font(DSFont.caption)
                                            .padding(.horizontal, 10).padding(.vertical, 4)
                                            .background(groupInput == g ? DSColor.accent.opacity(0.2) : Color.secondary.opacity(0.1))
                                            .foregroundColor(groupInput == g ? DSColor.accent : DSColor.textSecondary)
                                            .clipShape(Capsule())
                                    }
                                }
                            }
                        }
                    }
                    .interfaceSectionSurface()
                    Section(header: Text(localized("閱讀進度"))) {
                        HStack {
                            Text(localized("目前進度"))
                            Spacer()
                            Text("\(Int(book.currentPosition * 100))%")
                                .foregroundColor(.secondary)
                        }
                        HStack {
                            Text(localized("加入時間"))
                            Spacer()
                            Text(book.addedDate, style: .date)
                                .foregroundColor(.secondary)
                        }
                        HStack {
                            Text(localized("來源"))
                            Spacer()
                            Text(book.source == "local" ? localized("本機文件") : localized("網頁匯入"))
                                .foregroundColor(.secondary)
                        }
                    }
                    .interfaceSectionSurface()
                }
                .navigationTitle(localized("書籍資訊"))
                .themedAppSurface(for: .bookshelf)
                .alert(
                    localized("封面設定失敗"),
                    isPresented: Binding(
                        get: { coverErrorMessage != nil },
                        set: { if !$0 { coverErrorMessage = nil } }
                    )
                ) {
                    Button(localized("確定"), role: .cancel) {}
                } message: {
                    Text(coverErrorMessage ?? "")
                }
        }
    }

    // MARK: - Cover

    /// Legado's 换封面 block: the cover as the page's hero, a cross-source cover
    /// search, a local pick, a reset, and the raw address.
    @ViewBuilder
    private var coverSection: some View {
        // Full-bleed and card-less: the hero paints its own backdrop, so it takes
        // the row edge to edge and hands back a clear row instead of a surface.
        Section {
            coverHero
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }

        Section {
            // Pushed, not presented: a nested sheet is the shape iOS 17 drops
            // (Technotes/iOS17MenuModalPresentation.md), and internal navigation
            // inside a sheet is the sanctioned pattern anyway.
            NavigationLink {
                CoverSearchView(
                    bookId: book.id,
                    title: liveBook.title,
                    author: liveBook.author
                ) { candidate in
                    applyCover(url: candidate.coverUrl, sourceId: candidate.sourceId)
                }
            } label: {
                Label(localized("封面搜索"), systemImage: "magnifyingglass")
            }
            .disabled(isApplyingCover)

            ImageSourcePickerButton(
                accessibilityTitle: localized("選擇封面圖片"),
                onPick: handleCoverPick
            ) {
                Label(localized("選擇圖片"), systemImage: "photo")
            }
            .disabled(isApplyingCover)

            if liveBook.hasCustomCover {
                Button(role: .destructive) {
                    store.resetCover(bookId: book.id)
                    coverUrlInput = liveBook.coverUrl ?? ""
                } label: {
                    Label(localized("重設封面"), systemImage: "arrow.uturn.backward")
                }
                .disabled(isApplyingCover)
            }
        } header: {
            Text(localized("封面"))
        } footer: {
            Text(localized("封面搜索會在所有啟用的書源中，尋找同書名同作者的封面。"))
        }
        .interfaceSectionSurface()

        Section {
            TextField(localized("封面網址"), text: $coverUrlInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .accessibilityLabel(localized("封面網址"))

            Button {
                applyCover(url: coverUrlInput, sourceId: liveBook.bookSourceId)
            } label: {
                Label(localized("套用網址"), systemImage: "arrow.down.circle")
            }
            .disabled(isApplyingCover || !canApplyCoverUrl)
        } footer: {
            Text(localized("貼上圖片網址後，點「套用網址」下載為封面。"))
        }
        .interfaceSectionSurface()
    }

    private var canApplyCoverUrl: Bool {
        let trimmed = coverUrlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return false }
        return url.scheme?.hasPrefix("http") == true
    }

    /// The artwork itself, filling whatever frame the caller gives it: the user's
    /// own image when they set one, otherwise the source's cover.
    @ViewBuilder
    private var coverArtwork: some View {
        if let path = liveBook.coverImagePath,
           let image = BookshelfCoverLoader.load(filename: path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            let source = liveBook.bookSourceId.flatMap { id in
                BookSourceStore.shared.sources.first { $0.id == id }
            }
            BookCoverImage(
                coverURL: liveBook.coverUrl ?? "",
                title: liveBook.title,
                sourceBaseURL: source?.bookSourceUrl,
                sourceHeaders: source?.parsedHeaders ?? [:]
            )
        }
    }

    /// 書籍資訊 opens on the cover: the artwork at a size worth looking at, lifted
    /// off a blurred wash of itself that melts into the page background.
    ///
    /// Both layers render one `coverArtwork` value, so the artwork is resolved
    /// once per pass — `BookshelfCoverLoader.load` reads and decodes from disk on
    /// every call, and `BookCoverImage` would start a second load.
    private var coverHero: some View {
        let artwork = coverArtwork
        let shape = RoundedRectangle(cornerRadius: DSRadius.xl, style: .continuous)

        return ZStack {
            artwork

            if isApplyingCover {
                Color.black.opacity(0.35)
                ProgressView()
                    .tint(.white)
            }
        }
        .frame(width: DSLayout.bookCoverHeroWidth, height: DSLayout.bookCoverHeroHeight)
        .clipShape(shape)
        .overlay(shape.stroke(DSColor.textSecondary.opacity(0.2), lineWidth: 0.5))
        .shadow(
            color: DSColor.coverHeroShadow,
            radius: DSLayout.bookCoverHeroShadowRadius,
            y: DSLayout.bookCoverHeroShadowOffsetY
        )
        .padding(.vertical, DSSpacing.xl)
        .frame(maxWidth: .infinity)
        .background { coverHeroBackdrop(artwork) }
        // One image, not an interactive element; the buttons below act on it.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            isApplyingCover ? localized("正在套用封面") : localized("目前封面")
        )
    }

    /// The same artwork blurred out into a colour wash behind the hero. Purely
    /// decorative and carrying no state, so Reduce Transparency drops it entirely
    /// and the cover sits on the plain page background instead.
    @ViewBuilder
    private func coverHeroBackdrop<Artwork: View>(_ artwork: Artwork) -> some View {
        if !reduceTransparency {
            GeometryReader { proxy in
                artwork
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    // `opaque: true` samples the edge pixels instead of the
                    // transparency outside the frame, so the wash keeps its
                    // strength at the edges rather than fading into a halo.
                    .blur(radius: DSLayout.bookCoverHeroBackdropBlur, opaque: true)
                    .clipped()
            }
            .saturation(DSLayout.bookCoverHeroBackdropSaturation)
            .opacity(DSLayout.bookCoverHeroBackdropOpacity)
            .mask { coverHeroBackdropFade }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// Soft top and bottom edges so the wash reads as light coming off the cover,
    /// not a band pasted across the top of the form. The form's own inset above
    /// the first section means a hard top edge would show as a seam.
    private var coverHeroBackdropFade: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.16),
                .init(color: .black, location: 0.58),
                .init(color: .clear, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func applyCover(url: String, sourceId: UUID?) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isApplyingCover = true
        Task {
            let applied = await store.applyCustomCover(
                bookId: book.id, coverUrl: trimmed, sourceId: sourceId
            )
            isApplyingCover = false
            if applied {
                coverUrlInput = trimmed
            } else {
                coverErrorMessage = localized("無法下載這張封面，請換一張或檢查網路。")
            }
        }
    }

    private func handleCoverPick(_ result: Result<PickedImageSource, PickedImageError>) {
        switch result {
        case .success(.data(let data)):
            storePickedCover(data)
        case .success(.file(let url)):
            guard let data = try? Data(contentsOf: url) else {
                coverErrorMessage = localized("無法讀取圖片。")
                return
            }
            storePickedCover(data)
        case .failure(let error):
            coverErrorMessage = localized(error.messageKey)
        }
    }

    private func storePickedCover(_ data: Data) {
        guard store.applyCustomCover(bookId: book.id, imageData: data) else {
            coverErrorMessage = localized("無法讀取圖片。")
            return
        }
        coverUrlInput = ""
    }
}

// MARK: - Empty Bookshelf
struct EmptyLibraryView: View {
    @Binding var showAdd: Bool
    @State private var appeared = false
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "books.vertical")
                .font(DSFont.fixed(size: 72))
                .foregroundColor(DSColor.textSecondary.opacity(0.35))
            Text(localized("書架還是空的"))
                .font(DSFont.title2.weight(.semibold))
            Text(localized("匯入 TXT 文件，或是輸入網址\n抓取網頁小說加入書架"))
                .font(DSFont.subheadline).foregroundColor(DSColor.textSecondary).multilineTextAlignment(.center)
            Button {
                showAdd = true
            } label: {
                Label(localized("添加書籍"), systemImage: "plus")
                    .font(DSFont.headline).foregroundColor(.white)
                    .padding(.horizontal, DSSpacing.xxl).padding(.vertical, 14)
                    .background(DSColor.accent).clipShape(Capsule())
            }
            NavigationLink {
                SearchView()
            } label: {
                Label(localized("搜索書籍"), systemImage: "magnifyingglass")
                    .font(DSFont.subheadline.weight(.medium))
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding()
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.easeOut(duration: 0.3)) { appeared = true }
        }
    }
}

// MARK: - Book Row (Apple Books Style)
struct BookRow: View {
    let book: ReadingBook
    var isEditing: Bool = false
    var transitionNamespace: Namespace.ID? = nil
    let onTap: (ReaderCardGeometry?) -> Void
    var onCoverFrameChange: ((CGRect) -> Void)? = nil
    let onEdit: () -> Void
    let onDelete: () -> Void
    var onShowDetail: (() -> Void)? = nil

    private let coverW: CGFloat = 45
    private let coverH: CGFloat = 65
    @State private var liveCoverFrame: CGRect = .zero

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                // In edit mode the row is plain content so the List's native selection circle handles
                // taps; otherwise it's a button that opens the book.
                if isEditing {
                    rowContent
                } else {
                    Button(action: {
                        onTap(
                            liveCoverFrame.isEmpty
                                ? nil
                                : ReaderCardGeometry(
                                    frame: liveCoverFrame,
                                    cornerRadius: DSRadius.sm
                                )
                        )
                    }) { rowContent }
                        .buttonStyle(.plain)

                    VStack {
                        Spacer(minLength: 0)
                        HStack(spacing: 12) {
                            if book.offlineDownloadState == .downloading {
                                BookSyncIndicator(progress: offlineDownloadProgress)
                            }
                            BookOverflowMenu(
                                iconSize: 16,
                                onEdit: onEdit,
                                onDelete: onDelete,
                                onShowDetail: onShowDetail
                            )
                        }
                    }
                }
            }
            .padding(.vertical, 10)

            Rectangle()
                .fill(Color(uiColor: .separator))
                .frame(height: 0.5)
        }
        .onChange(of: liveCoverFrame) { _, frame in
            if !frame.isEmpty { onCoverFrameChange?(frame) }
        }
    }

    private var rowContent: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if #available(iOS 18.0, *), let ns = transitionNamespace {
                    bookCover.matchedTransitionSource(id: book.id, in: ns)
                } else {
                    bookCover
                }
            }
            .reportBookshelfCoverFrame($liveCoverFrame)

            VStack(alignment: .leading, spacing: 5) {
                Text(book.title)
                    .font(DSFont.fixed(size: 15, weight: .medium))
                    .lineLimit(2)
                    .foregroundColor(.primary)

                if !book.author.isEmpty {
                    Text(book.author)
                        .font(DSFont.fixed(size: 13))
                        .foregroundColor(DSColor.textSecondary)
                        .lineLimit(1)
                }

                if let latest = book.latestChapterDisplayTitle {
                    Text(localized("最新") + " · " + latest)
                        .font(DSFont.fixed(size: 12))
                        .foregroundColor(DSColor.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                HStack(spacing: 6) {
                    if book.hasNewChapterUpdate {
                        updateBadge
                    }
                    progressBadge
                }
            }
            .padding(.top, 2)

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    /// Offline-download progress (downloaded chapters / total), or nil when the
    /// chapter count isn't known yet (indeterminate).
    private var offlineDownloadProgress: Double? {
        let total = book.offlineDownloadTask?.clamped(to: book.onlineChapters?.count ?? 0)?.totalChapterCount
            ?? book.onlineChapters?.count
        guard let total, total > 0 else { return nil }
        return min(1, Double(book.downloadedChapterCount) / Double(total))
    }

    /// "更新" pill shown when a refresh found new chapters the user hasn't opened yet.
    private var updateBadge: some View {
        Text(localized("更新"))
            .font(DSFont.fixed(size: 11, weight: .bold))
            .foregroundColor(DSColor.textOnAccent)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(DSColor.accent)
            .clipShape(Capsule())
            .accessibilityLabel(localized("有新章節"))
    }

    @ViewBuilder
    private var progressBadge: some View {
        if book.shouldShowNewOnBookshelf {
            Text(localized("新增"))
                .font(DSFont.fixed(size: 11, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color(red: 0.03, green: 0.31, blue: 0.58))
                .clipShape(Capsule())
        } else if book.currentPosition >= 0.99 {
            Text(localized("已讀完"))
                .font(DSFont.fixed(size: 12))
                .foregroundColor(DSColor.textSecondary)
        } else {
            Text("\(Int(book.currentPosition * 100))%")
                .font(DSFont.fixed(size: 12))
                .foregroundColor(DSColor.textSecondary)
        }
    }

    @ViewBuilder
    private var bookCover: some View {
        if let coverPath = book.coverImagePath,
           let uiImage = loadCoverImage(filename: coverPath) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
                .frame(width: coverW, height: coverH)
                .clipShape(RoundedRectangle(cornerRadius: DSRadius.sm))
                .shadow(color: .black.opacity(0.08), radius: 15, x: 0, y: 10)
                .overlay(alignment: .bottomTrailing) {
                    if book.resolvedPipelineKind == .audio { AudiobookCoverBadge(glyphSize: 7) }
                }
        } else {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: DSRadius.sm)
                    .fill(Color(.secondarySystemBackground))
                    .shadow(color: .black.opacity(0.08), radius: 15, x: 0, y: 10)
                Text(book.title)
                    .font(DSFont.fixed(size: 9, weight: .medium))
                    .foregroundColor(DSColor.textSecondary)
                    .lineLimit(4)
                    .padding(5)
            }
            .frame(width: coverW, height: coverH)
            .overlay(alignment: .bottomTrailing) {
                if book.resolvedPipelineKind == .audio { AudiobookCoverBadge(glyphSize: 7) }
            }
        }
    }

    private func loadCoverImage(filename: String) -> UIImage? {
        BookshelfCoverLoader.load(filename: filename)
    }

}

// MARK: - Book Sync Indicator

/// Cloud-in-a-ring shown on a bookshelf row only while the book is downloading
/// for offline reading. Determinate when the chapter count is known; otherwise a
/// small spinner. Hidden entirely when no sync is in progress.
private struct BookSyncIndicator: View {
    /// Download progress 0...1, or nil for indeterminate.
    let progress: Double?

    var body: some View {
        ZStack {
            if let progress {
                Circle()
                    .stroke(DSColor.accent.opacity(0.18), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: max(0.02, progress))
                    .stroke(DSColor.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(DSAnimation.standard, value: progress)
                Image(systemName: "arrow.down")
                    .font(DSFont.fixed(size: 10, weight: .semibold))
                    .foregroundColor(DSColor.accent)
            } else {
                ProgressView()
                    .scaleEffect(0.7)
            }
        }
        .frame(width: 26, height: 26)
        .accessibilityLabel(localized("下載中"))
    }
}

// MARK: - Book Grid Cell
struct BookGridCell: View {
    let book: ReadingBook
    var isCompactLayout: Bool = false
    var transitionNamespace: Namespace.ID? = nil
    let onOpen: (ReaderCardGeometry?) -> Void
    var onCoverFrameChange: ((CGRect) -> Void)? = nil
    let onEdit: () -> Void
    let onDelete: () -> Void
    var onShowDetail: (() -> Void)? = nil
    @State private var liveCoverFrame: CGRect = .zero

    /// Cover geometry for the open-book card transition, or nil before the cover
    /// has reported a frame.
    private var readerCardGeometry: ReaderCardGeometry? {
        liveCoverFrame.isEmpty
            ? nil
            : ReaderCardGeometry(frame: liveCoverFrame, cornerRadius: DSRadius.md)
    }

    /// Everything the cell shows, spoken as one phrase. The cell is a single
    /// VoiceOver element, so the cover button, title, author and overflow menu
    /// must not be reachable separately — swiping through a grid of books
    /// otherwise costs four stops per book instead of one, unlike the list.
    private var accessibilityDescription: String {
        var parts: [String] = [book.title]
        if !book.author.isEmpty {
            parts.append(book.author)
        }
        if book.resolvedPipelineKind == .audio {
            parts.append(localized("有聲書"))
        }
        if book.hasNewChapterUpdate {
            parts.append(localized("有新章節"))
        }
        if book.currentPosition >= 0.99 {
            parts.append(localized("已讀完"))
        } else if book.currentPosition > 0.01 {
            parts.append(String(format: localized("已讀 %d%%"), Int(book.currentPosition * 100)))
        }
        return parts.joined(separator: "，")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: {
                onOpen(readerCardGeometry)
            }) {
                ZStack(alignment: .topTrailing) {
                    Group {
                        if #available(iOS 18.0, *), let ns = transitionNamespace {
                            coverView.matchedTransitionSource(id: book.id, in: ns)
                        } else {
                            coverView
                        }
                    }
                    .reportBookshelfCoverFrame($liveCoverFrame)
                    if book.currentPosition > 0.01 && book.currentPosition < 0.99 {
                        Text("\(Int(book.currentPosition * 100))%")
                            .font(DSFont.fixed(size: 10, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(DSColor.accent.opacity(0.85))
                            .clipShape(Capsule())
                            .padding(6)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if book.hasNewChapterUpdate {
                        Text(localized("更新"))
                            .font(DSFont.fixed(size: 10, weight: .bold))
                            .foregroundColor(DSColor.textOnAccent)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(DSColor.accent)
                            .clipShape(Capsule())
                            .padding(6)
                            .accessibilityLabel(localized("有新章節"))
                    }
                }
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                    .font(DSFont.fixed(size: isCompactLayout ? 12 : 13, weight: .semibold))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(alignment: .center, spacing: 2) {
                    Text(book.author)
                        .font(DSFont.fixed(size: isCompactLayout ? 10 : 11))
                        .foregroundColor(DSColor.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    BookOverflowMenu(
                        iconSize: isCompactLayout ? 13 : 14,
                        controlSize: isCompactLayout ? 28 : 32,
                        onEdit: onEdit,
                        onDelete: onDelete,
                        onShowDetail: onShowDetail
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: liveCoverFrame) { _, frame in
            if !frame.isEmpty { onCoverFrameChange?(frame) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onOpen(readerCardGeometry) }
        // The overflow menu is no longer its own element, so its items become the
        // cell's rotor actions instead.
        .accessibilityActions {
            if let onShowDetail {
                Button(localized("書籍詳情")) { onShowDetail() }
            }
            Button(localized("編輯書籍資訊")) { onEdit() }
            Button(localized("刪除書籍"), role: .destructive) { onDelete() }
        }
    }

    @ViewBuilder
    private var coverView: some View {
        let base = Color.clear
            .aspectRatio(2/3, contentMode: .fit)

        if let coverPath = book.coverImagePath,
           let uiImage = loadCoverImage(filename: coverPath) {
            base.overlay(
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            )
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: DSRadius.md))
            .shadow(color: .black.opacity(0.18), radius: 4, x: 0, y: 2)
            .overlay(alignment: .bottomTrailing) {
                if book.resolvedPipelineKind == .audio { AudiobookCoverBadge(glyphSize: 11) }
            }
        } else {
            base.overlay(
                RoundedRectangle(cornerRadius: DSRadius.md)
                    .fill(Color(.secondarySystemBackground))
                    .overlay(
                        Text(book.title)
                            .font(DSFont.fixed(size: 11, weight: .medium))
                            .foregroundColor(DSColor.textSecondary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(6)
                            .padding(8),
                        alignment: .topLeading
                    )
            )
            .overlay(alignment: .bottomTrailing) {
                if book.resolvedPipelineKind == .audio { AudiobookCoverBadge(glyphSize: 11) }
            }
        }
    }

    private func loadCoverImage(filename: String) -> UIImage? {
        BookshelfCoverLoader.load(filename: filename)
    }

}

// MARK: - Book Overflow Menu

private struct BookOverflowMenu: View {
    let iconSize: CGFloat
    var controlSize: CGFloat = 44
    let onEdit: () -> Void
    let onDelete: () -> Void
    var onShowDetail: (() -> Void)? = nil

    var body: some View {
        Menu {
            if let onShowDetail {
                Button { onShowDetail() } label: {
                    Label(localized("書籍詳情"), systemImage: "book")
                }
            }
            Button { onEdit() } label: {
                Label(localized("編輯書籍資訊"), systemImage: "pencil")
            }
            Button(role: .destructive) { onDelete() } label: {
                Label(localized("刪除書籍"), systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(DSFont.fixed(size: iconSize, weight: .semibold))
                .foregroundColor(DSColor.textSecondary)
                .frame(width: controlSize, height: controlSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(localized("更多"))
    }
}

// MARK: - Bulk Add to Group Sheet
struct BulkAddToGroupSheet: View {
    let bookCount: Int
    let onConfirm: (String) -> Void

    @EnvironmentObject private var store: BookStore
    @Environment(\.presentationMode) private var dismiss
    @State private var groupInput: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text(localized("分組名稱"))) {
                    TextField(localized("輸入分組名稱（留空＝未分組）"), text: $groupInput)
                    if !store.allGroups.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(store.allGroups, id: \.self) { g in
                                    Button(g) { groupInput = g }
                                        .font(DSFont.caption)
                                        .padding(.horizontal, 10).padding(.vertical, 4)
                                        .background(groupInput == g ? DSColor.accent.opacity(0.2) : Color.secondary.opacity(0.1))
                                        .foregroundColor(groupInput == g ? DSColor.accent : DSColor.textSecondary)
                                        .clipShape(Capsule())
                                }
                            }
                        }
                    }
                }
                .interfaceSectionSurface()
                Section {
                    Text(localized("將套用到") + " \(bookCount) " + localized("本書"))
                        .font(DSFont.footnote)
                        .foregroundColor(DSColor.textSecondary)
                }
                .interfaceSectionSurface()
            }
            .navigationTitle(localized("加入分組"))
            .toolbarTitleDisplayMode(.inline)
            .themedAppSurface(for: .bookshelf)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss.wrappedValue.dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        onConfirm(groupInput)
                        dismiss.wrappedValue.dismiss()
                    } label: {
                        Image(systemName: "checkmark")
                    }
                }
            }
        }
    }
}

// MARK: - Previews

#if DEBUG
private func previewOnlineBook(hasUpdate: Bool) -> ReadingBook {
    var book = ReadingBook(
        title: "示範線上小說",
        author: "示範作者",
        source: "https://example.com",
        contentFilename: ""
    )
    book.isOnline = true
    book.currentPosition = 0.42
    book.onlineChapters = [
        OnlineChapterRef(index: 0, title: "第一章 開始", url: "https://example.com/1"),
        OnlineChapterRef(index: 1, title: "第一百零八章 大結局", url: "https://example.com/108"),
    ]
    book.hasNewChapterUpdate = hasUpdate
    return book
}

#Preview("BookRow – 有更新 / 無更新") {
    List {
        BookRow(book: previewOnlineBook(hasUpdate: true), onTap: { _ in }, onEdit: {}, onDelete: {})
        BookRow(book: previewOnlineBook(hasUpdate: false), onTap: { _ in }, onEdit: {}, onDelete: {})
    }
    .listStyle(.plain)
}

#Preview("BookGridCell – 有更新 / 無更新") {
    LazyVGrid(
        columns: Array(repeating: GridItem(.flexible(), spacing: DSSpacing.md), count: 3),
        spacing: DSSpacing.lg
    ) {
        BookGridCell(book: previewOnlineBook(hasUpdate: true), onOpen: { _ in }, onEdit: {}, onDelete: {})
        BookGridCell(book: previewOnlineBook(hasUpdate: false), onOpen: { _ in }, onEdit: {}, onDelete: {})
    }
    .padding()
}

#Preview("書籍資訊 – 封面區") {
    EditBookSheet(book: previewOnlineBook(hasUpdate: false)) { _, _, _ in }
        .environmentObject(BookStore())
}
#endif
