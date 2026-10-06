import YueduCoreText
import Combine
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Bookshelf Home
/// A place on the shelf that lists books: 全部 or a group's page, which the shelf swipes
/// between, or a group opened from its folder on 全部.
private enum ShelfPage: Hashable {
    case all
    case group(String)
    case folder(String)

    /// The page `HomeView.selectedGroup` names — `""` is 全部.
    init(pagerGroup group: String) {
        self = group.isEmpty ? .all : .group(group)
    }

    /// One of the pages the shelf swipes between, not a folder's page pushed over it.
    var isOnPager: Bool {
        if case .folder = self { false } else { true }
    }
}

/// What a page lists. 全部 folds each group into one folder; every other page lists books.
private enum ShelfEntry: Identifiable {
    case book(ReadingBook)
    /// A group, with its books in the shelf's order.
    case folder(name: String, books: [ReadingBook])

    var id: String {
        switch self {
        case .book(let book): "book:" + book.id.uuidString
        case .folder(let name, _): "group:" + name
        }
    }

    var book: ReadingBook? {
        if case .book(let book) = self { book } else { nil }
    }

    /// The book, or a folder's first book: what a book dropped before it in 手動 lands before.
    var firstBookID: UUID? {
        switch self {
        case .book(let book): book.id
        case .folder(_, let books): books.first?.id
        }
    }

    /// What 書名 sorts it by: a folder goes by its group's name.
    var sortTitle: String {
        switch self {
        case .book(let book): book.title
        case .folder(let name, _): name
        }
    }
}

@MainActor
private final class BookshelfReaderGeometryStore: ObservableObject {
    /// By shelf page, then by book. A book is on 全部 and on its group's page, and the
    /// page beside the one in view is laid out too, off screen, so one frame per book
    /// would be whichever page reported last.
    private var frames: [ShelfPage: [UUID: CGRect]] = [:]

    func update(_ frame: CGRect, for bookID: UUID, onPage page: ShelfPage) {
        guard !frame.isEmpty else { return }
        frames[page, default: [:]][bookID] = frame
    }

    func frame(for bookID: UUID, onPage page: ShelfPage) -> CGRect? {
        frames[page]?[bookID]
    }

    func invalidate(bookID: UUID) {
        for page in frames.keys {
            frames[page]?[bookID] = nil
        }
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
    case calibre
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
    @Environment(\.rootTabBarVisibility) private var rootTabBarVisibility
    @ObservedObject private var gs = GlobalSettings.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showAddSheet = false
    @State private var showWebDAVImport = false
    @State private var showOPDSImport = false
    @State private var showCalibreLibrary = false
    @State private var addSheetSessionID = UUID()
    @State private var showLegacyImportChooser = false
    @State private var legacyImportSequence =
        DismissalSequencedPresentation<BookshelfImportPresentationRoute>()
    @State private var editingBook: ReadingBook? = nil
    @State private var bookToDelete: ReadingBook? = nil
    @State private var selectedOnlineBookDetail: OnlineBook? = nil
    @State private var editMode = EditMode.inactive
    /// The group's page in view on the shelf; `""` is 全部.
    @State private var selectedGroup: String = ""
    /// The group whose folder was opened from 全部, its page pushed over the shelf.
    @State private var openedFolder: String?
    @State private var selectedBookIds: Set<UUID> = []
    @State private var showBulkDeleteAlert = false
    @State private var showAddToGroupSheet = false
    /// Pushed rather than presented: a sheet asked for from a menu action can be dropped on iOS 17.
    @State private var showBookshelfOrganizer = false
    @State private var showAIPaywall = false
    @ObservedObject private var subscription = SubscriptionStore.shared
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
    /// A grid cell's cover frame: the flexible columns' share of the width left after
    /// the insets and the gaps between columns, at the cell's 2:3. `.zero` before the
    /// first layout, which leaves covers on their placeholder until it is known.
    private var gridCoverDisplaySize: CGSize {
        let columns = CGFloat(max(gs.bookshelfGridColumnCount, 1))
        let available = gridContainerWidth - gridHorizontalInset * 2 - gridColumnSpacing * (columns - 1)
        guard available > 0 else { return .zero }
        let width = available / columns
        return CGSize(width: width, height: width * 3 / 2)
    }

    @StateObject private var readerCoordinator = ReaderNavigationCoordinator()
    @StateObject private var readerGeometryStore = BookshelfReaderGeometryStore()
    /// Bumped when the book just opened has moved to the front of 最近閱讀. The shelf then
    /// goes back to its top behind the reader: left scrolled down to where the book was,
    /// its new place is off screen, and the closing card had nowhere to land but a
    /// stand-in in the middle of the shelf.
    @State private var shelfScrollToTopRequest = 0
    /// The page the book was opened from, which the request takes back to its top.
    @State private var shelfScrollToTopPage = ShelfPage.all
    /// The grid scroll view's width, measured once per size change (not per cell, not
    /// per scroll), so every cell knows how large to decode its cover.
    @State private var gridContainerWidth: CGFloat = 0
    @State private var pendingReaderOpenToken: UUID?

    /// Audiobooks and the iPad shell retain their modal reader presentation.
    /// Other iPhone shelf readers share the coordinator and card transition.
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
        openBook(book, from: ShelfPage(pagerGroup: selectedGroup), sourceGeometry: nil)
    }
    #endif

    /// `page` is where the book was tapped, and where its card goes back to when it closes:
    /// the reader covers the shelf, so nothing pages it or pops it in between.
    private func openBook(_ book: ReadingBook, from page: ShelfPage, sourceGeometry: ReaderCardGeometry?) {
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
            // Same resolver the cards use, so the lifted card carries the very
            // image the shelf was showing (including a 預設封面).
            let snapshot = BookshelfCoverStyle.snapshot(
                for: book,
                colorScheme: colorScheme,
                sourceSize: sourceGeometry?.frame.size
                    ?? readerGeometryStore.frame(for: book.id, onPage: page)?.size
            )
            let snapshotUpgrade = snapshot == nil
                ? nil
                : BookshelfCoverStyle.snapshotUpgrade(for: book, colorScheme: colorScheme)
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
                        return geometryStore?.frame(for: book.id, onPage: page)
                    },
                    snapshot: snapshot,
                    snapshotUpgrade: snapshotUpgrade,
                    direction: direction
                )
                let shouldInvalidateForRecentSort =
                    sortOrder == BookSortOrder.recentlyRead.rawValue
                    && entries(onPage: page).first?.book?.id != book.id
                let readerBookID = book.id
                let readerStore = store
                let readerDependencies = appDependencies
                let readerTabBarVisibility = rootTabBarVisibility
                readerCoordinator.open(
                    bookID: readerBookID,
                    source: source,
                    destination: {
                        ReaderHostingController(content: AnyView(
                            BookReaderView(bookId: readerBookID)
                                .environmentObject(readerStore)
                                .environment(\.appDependencies, readerDependencies)
                                .environment(\.readerNavigator, navigator)
                                // Its own hosting controller starts a new environment;
                                // without this the reader could hide only 書架's tab bar.
                                .environment(\.rootTabBarVisibility, readerTabBarVisibility)
                        ))
                    },
                    onTransitionCompleted: {
                        if shouldInvalidateForRecentSort {
                            // Do not let a closing transition use the old row
                            // position while the recently-read sort moves it.
                            geometryStore?.invalidate(bookID: readerBookID)
                        }
                        transitionBookStore?.updateLastOpened(bookId: readerBookID)
                        if shouldInvalidateForRecentSort {
                            shelfScrollToTopPage = page
                            shelfScrollToTopRequest += 1
                        }
                    }
                )
            }
        } else {
            AppLogger.info("⟐ openBook MODAL path bookID=\(book.id) (audiobook or non-phone shell)")
            pendingReaderOpenToken = nil
            store.updateLastOpened(bookId: book.id)
            modalReaderBookId = book.id
        }
    }

    private func resolveOpeningDirection(
        for book: ReadingBook
    ) async -> ReaderBookOpeningDirection {
        if book.resolvedPipelineKind == .manga || book.resolvedPipelineKind == .fixedPage {
            let configuration = store.readerSettings.fixedPageConfiguration(for: book.id)
            return ReaderBookOpeningDirection.resolve(
                writingMode: .horizontal,
                pageProgressionIsRTL: configuration.progression == .rightToLeft
            )
        }
        if book.opensWithDeclaredEPUBFlow {
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
        AppLogger.info("⟐ resolveOpeningDirection follows 排版方向 done direction=\(direction)")
        return direction
    }

    /// The page the shelf's buttons act on: a group opened from its folder, otherwise the
    /// page in view on the shelf.
    private var activePage: ShelfPage {
        openedFolder.map(ShelfPage.folder) ?? ShelfPage(pagerGroup: selectedGroup)
    }

    /// The books 選取 can take on that page: on 全部, the ones outside a folder.
    var sortedFilteredBooks: [ReadingBook] {
        entries(onPage: activePage).compactMap(\.book)
    }

    /// The shelf's pages: 全部 (`""`), then each group, in the order of the group bar.
    private var shelfPages: [String] {
        [""] + store.allGroups
    }

    /// What a page lists, in the shelf's order. On 全部 each group is one folder, where
    /// its first book would be — the one read last, under 最近閱讀 — except under 書名,
    /// which sorts a folder by its group's name among the titles.
    private func entries(onPage page: ShelfPage) -> [ShelfEntry] {
        switch page {
        case .group(let group), .folder(let group):
            return sortedBooks(inGroup: group).map(ShelfEntry.book)
        case .all:
            let books = sortedBooks(inGroup: nil)
            let groups = Dictionary(grouping: books.filter { !$0.group.isEmpty }, by: \.group)
            var placed = Set<String>()
            var entries: [ShelfEntry] = []
            for book in books {
                if book.group.isEmpty {
                    entries.append(.book(book))
                } else if placed.insert(book.group).inserted, let members = groups[book.group] {
                    entries.append(.folder(name: book.group, books: members))
                }
            }
            if BookSortOrder(rawValue: sortOrder) == .title {
                entries.sort { $0.sortTitle.localizedCompare($1.sortTitle) == .orderedAscending }
            }
            return entries
        }
    }

    /// A group's books, or with `nil` every book, in the shelf's order.
    private func sortedBooks(inGroup group: String?) -> [ReadingBook] {
        let base = group.map { group in store.books.filter { $0.group == group } } ?? store.books
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
                            .rootTabTitleScrollAnchor()
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
                    } else {
                        groupedShelf(pages: shelfPages)
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
                    }
                }
            }
            .themedAppSurface(for: .bookshelf)
            .animation(DSAnimation.standard, value: store.books.isEmpty)
            .rootTabTitle(localized("書架"), onScroll: .fadesTitle)
            .toolbar { shelfToolbar(addsBooks: true) }
            // In edit mode, hide the app tab bar so the contextual .bottomBar (delete / group / share)
            // takes its place — the system selection pattern used by Photos / Files.
            .hidesRootTabBar(editMode == .active)
            .onChange(of: store.allGroups) { _, groups in
                // A group whose last book moved out or was deleted has no page left to
                // show: 全部 takes over, and its folder's page goes back to the shelf.
                if !selectedGroup.isEmpty, !groups.contains(selectedGroup) {
                    selectedGroup = ""
                }
                if let openedFolder, !groups.contains(openedFolder) {
                    self.openedFolder = nil
                }
            }
            .navigationDestination(item: $openedFolder) { group in
                folderPage(group)
            }
            .onChange(of: openedFolder) { _, folder in
                // 選取 on a group's page ends with the page.
                if folder == nil, editMode == .active {
                    editMode = .inactive
                    selectedBookIds = []
                }
            }
            .sheet(isPresented: $showAddToGroupSheet) {
                AdaptiveSheetContainer(maxWidth: DSLayout.readableNarrowWidth) {
                    BookshelfAddToGroupSheet(groups: groupBookCounts) { group in
                        addSelection(toGroup: group)
                    }
                }
            }
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
                                title: localized("WebDAV 書庫"),
                                systemImage: "externaldrive.connected.to.line.below"
                            ),
                            DismissalSequencedAction(
                                route: .opds,
                                title: localized("OPDS 書庫"),
                                systemImage: "books.vertical"
                            ),
                            DismissalSequencedAction(
                                route: .calibre,
                                title: localized("Calibre 書庫"),
                                systemImage: "server.rack"
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
            .sheet(isPresented: $showCalibreLibrary) {
                AdaptiveSheetContainer(maxWidth: DSLayout.readableListWidth) {
                    OPDSImportView(kind: .calibre).environmentObject(store)
                }
            }
            .navigationDestination(isPresented: $showBookshelfOrganizer) {
                AIBookshelfOrganizerView().environmentObject(store)
            }
            .sheet(isPresented: $showAIPaywall) {
                PaywallView(highlightedFeature: .aiReading)
                    .environmentObject(subscription)
            }
            .navigationDestination(item: $selectedOnlineBookDetail) { book in
                OnlineBookDetailDestination(
                    .book(book),
                    onRemoveFromShelf: { selectedOnlineBookDetail = nil },
                    textPageReaderNavigator: readerCoordinator
                )
                    .environmentObject(store)
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
                    Text(String(format: localized("確定要從書架刪除《%@》嗎？"), b.title))
                }
            }
            .alert(localized("確認刪除"), isPresented: $showBulkDeleteAlert) {
                Button(localized("刪除"), role: .destructive) {
                    let ids = selectedBookIds
                    withAnimation(reduceMotion ? nil : DSAnimation.standard) {
                        ids.forEach { store.delete(bookId: $0) }
                        selectedBookIds = []
                    }
                }
                Button(localized("取消"), role: .cancel) {}
            } message: {
                Text(String(format: localized("確定要刪除 %d 本書嗎？"), selectedBookIds.count))
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
        // Audiobooks and the iPad shell retain their original modal presentation.
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
        case .calibre:
            showCalibreLibrary = true
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
            .accessibilityLabel(localized("添加書籍"))
            .accessibilityIdentifier("home_add_book")
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
                    Label(localized("WebDAV 書庫"),
                          systemImage: "externaldrive.connected.to.line.below")
                }
                Button {
                    showOPDSImport = true
                } label: {
                    Label(localized("OPDS 書庫"), systemImage: "books.vertical")
                }
                Button {
                    showCalibreLibrary = true
                } label: {
                    Label(localized("Calibre 書庫"), systemImage: "server.rack")
                }
            } label: {
                Image(systemName: "plus")
                    .font(DSFont.toolbarIcon)
            }
            .accessibilityLabel(localized("添加書籍"))
            .accessibilityIdentifier("home_add_book")
            .id("\(Locale.autoupdatingCurrent.identifier)_add_menu")
        }
    }

    /// Without Pro: marked, and opens the paywall. On iOS 17 a menu cannot open a sheet
    /// (Technotes/iOS17MenuModalPresentation.md), so there it pushes the organizer, whose
    /// 開始整理 opens the paywall instead.
    private var organizerMenuItem: some View {
        let locked = !ReaderPremiumVisibilityPolicy(isProActive: subscription.isProActive).allowsAI
        return Button {
            if locked, !MenuModalPresentationPolicy.requiresDismissalSequencedChooser {
                showAIPaywall = true
            } else {
                showBookshelfOrganizer = true
            }
        } label: {
            // Two `Text`s: the second is the menu row's subtitle.
            Text(localized("AI 整理書架"))
            if locked {
                Text(localized("需要 Pro"))
            }
            Image(systemName: locked ? "lock.fill" : "sparkles")
        }
    }

    private var bookshelfOptionsMenu: some View {
        Menu {
            Button {
                withAnimation(reduceMotion ? nil : DSAnimation.standard) { editMode = .active }
            } label: {
                Label(localized("選取"), systemImage: "checkmark.circle")
            }
            organizerMenuItem

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
        .accessibilityIdentifier("home_options_menu")
        .id("\(Locale.autoupdatingCurrent.identifier)_menu")
    }

    // MARK: - Toolbar

    /// The shelf's buttons, on 書架 and on a group's page: the options menu and, on 書架,
    /// the add button; while selecting, 全選 and done, with delete, 加入分組 and share in a
    /// bottom bar.
    @ToolbarContentBuilder
    private func shelfToolbar(addsBooks: Bool) -> some ToolbarContent {
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
                        .foregroundStyle(DSColor.textPrimary)
                }
                .buttonStyle(.borderedProminent)
                .tint(.clear)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    withAnimation(reduceMotion ? nil : DSAnimation.standard) {
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
                    ToolbarTitleAndIconLabel(
                        title: localized("加入分組"),
                        systemImage: "text.badge.plus",
                        width: DSLayout.bookshelfAddToGroupLabelWidth
                    )
                }
                .disabled(selectedBookIds.isEmpty)
                .accessibilityLabel(localized("加入分組"))
                .accessibilityIdentifier("home_add_to_group")

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
            if addsBooks {
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
    }

    /// The shelf's groups in the group bar's order, each with how many books it holds.
    private var groupBookCounts: [(name: String, count: Int)] {
        let counts = Dictionary(grouping: store.books.filter { !$0.group.isEmpty }, by: \.group)
            .mapValues(\.count)
        return store.allGroups.map { (name: $0, count: counts[$0] ?? 0) }
    }

    /// Moves the selection into `group` and ends 選取. A name left empty moves nothing.
    private func addSelection(toGroup group: String) {
        guard !group.isEmpty, !selectedBookIds.isEmpty else { return }
        store.setGroups(Dictionary(uniqueKeysWithValues: selectedBookIds.map { ($0, group) }))
        selectedBookIds = []
        withAnimation(reduceMotion ? nil : DSAnimation.standard) { editMode = .inactive }
    }

    // MARK: - Group Pages

    /// The shelf as pages — 全部, then each group — that the reader swipes between, as
    /// legado's bookshelf pages through its groups; the group bar names the page in view.
    ///
    /// From iOS 26 the group bar is a safe-area bar: it and the navigation bar are one
    /// surface that the pages scroll on under, with one soft edge behind both. The system
    /// draws that edge for the pager, the outermost scroll view, so the pager carries
    /// `softScrollEdges()`; left to the system the edge is hard — a lighter band ending in
    /// a hairline under the group bar (iOS 27 simulator), the line the bar used to show
    /// under the navigation bar when it was a scroll view of its own above the shelf.
    /// Earlier systems draw no edge and no line, so there the bar stays above the pages,
    /// which stop under it.
    @ViewBuilder
    private func groupedShelf(pages: [String]) -> some View {
        let showsGroupBar = pages.count > 1
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            shelfPager(pages: pages)
                .safeAreaBar(edge: .top, spacing: 0) {
                    if showsGroupBar {
                        groupFilterBar(pages: pages)
                    }
                }
        } else {
            VStack(spacing: 0) {
                if showsGroupBar {
                    groupFilterBar(pages: pages)
                }
                shelfPager(pages: pages)
            }
        }
        #else
        VStack(spacing: 0) {
            if showsGroupBar {
                groupFilterBar(pages: pages)
            }
            shelfPager(pages: pages)
        }
        #endif
    }

    /// `selectedGroup` is the page in view: a chip tapped pages to its group, and a page
    /// swiped past halfway selects its chip.
    private func shelfPager(pages: [String]) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(pages, id: \.self) { group in
                    let isInView = group == selectedGroup
                    shelfContent(ShelfPage(pagerGroup: group), isInView: isInView)
                        // VoiceOver reads the page in view and moves between pages with the
                        // group bar, instead of walking out of one group's books into the next.
                        .accessibilityHidden(!isInView)
                        .containerRelativeFrame(.horizontal)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: pageInView, anchor: .center)
        .scrollIndicators(.hidden)
        // 全部 alone, with no group yet, does not page at all.
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        // The edge under the bars is drawn for this scroll view, not the pages' own (see
        // `groupedShelf`). Hiding it here hides theirs too — the setting reaches every
        // scroll view inside — and the books then show through the bars unblurred.
        .softScrollEdges()
    }

    private var pageInView: Binding<String?> {
        Binding(
            get: { selectedGroup },
            set: { page in
                if let page { selectedGroup = page }
            }
        )
    }

    /// One page as the shelf shows it, in a list or a grid. `isInView`: the page on screen,
    /// not one the pager has laid out beside it.
    @ViewBuilder
    private func shelfContent(_ page: ShelfPage, isInView: Bool) -> some View {
        let listed = entries(onPage: page)
        if isGridMode {
            bookGrid(entries: listed, page: page, isInView: isInView)
        } else {
            bookList(entries: listed, page: page, isInView: isInView)
        }
    }

    // MARK: - Folder Page

    /// A group opened from its folder on 全部: its books as the shelf shows them, under the
    /// group's name, with the shelf's options and 選取.
    private func folderPage(_ group: String) -> some View {
        AdaptiveContentContainer(maxWidth: DSLayout.readableShelfWidth) {
            shelfContent(.folder(group), isInView: true)
        }
        .themedAppSurface(for: .bookshelf)
        .navigationTitle(group)
        .toolbarTitleDisplayMode(.inline)
        .toolbar { shelfToolbar(addsBooks: false) }
        .hidesRootTabBar(editMode == .active)
    }

    // MARK: - Group Filter Bar
    private func groupFilterBar(pages: [String]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DSSpacing.sm) {
                    ForEach(pages, id: \.self) { page in
                        DSChip(
                            title: page.isEmpty ? localized("全部") : page,
                            isSelected: selectedGroup == page,
                            minWidth: DSLayout.capsuleControlMinWidth
                        ) {
                            withAnimation(reduceMotion ? nil : DSAnimation.standard) { selectedGroup = page }
                        }
                        .accessibilityIdentifier("home_group_chip")
                        .id(page)
                    }
                }
                .padding(.horizontal, DSSpacing.lg).padding(.vertical, 6)
            }
            // A group swiped to brings its chip into view when the groups overflow the bar.
            .onChange(of: selectedGroup) { _, page in
                withAnimation(reduceMotion ? nil : DSAnimation.standard) {
                    proxy.scrollTo(page, anchor: .center)
                }
            }
        }
    }


    // MARK: - Book List
    private func bookList(entries: [ShelfEntry], page: ShelfPage, isInView: Bool) -> some View {
        ScrollViewReader { proxy in
            bookListContent(entries: entries, page: page, isInView: isInView)
                .onChange(of: shelfScrollToTopRequest) {
                    if shelfScrollToTopPage == page, let first = entries.first {
                        proxy.scrollTo(first.id, anchor: .top)
                    }
                }
        }
    }

    private func bookListContent(entries: [ShelfEntry], page: ShelfPage, isInView: Bool) -> some View {
        let isSelecting = editMode == .active
        // A group's page pushed over the shelf leaves 書架's title alone.
        let measuresTitleFade = isInView && page.isOnPager
        // Native multi-select: binding the selection Set drives the system selection circles in
        // edit mode. A book row is tagged with its id; a folder has no id to select.
        return List(selection: $selectedBookIds) {
            ForEach(entries) { entry in
                Group {
                    switch entry {
                    case .book(let book):
                        BookRow(
                            book: book,
                            isEditing: isSelecting,
                            transitionNamespace: bookTransition,
                            onTap: { sourceGeometry in
                                openBook(book, from: page, sourceGeometry: sourceGeometry)
                            },
                            onCoverFrameChange: { frame in
                                readerGeometryStore.update(frame, for: book.id, onPage: page)
                            },
                            onEdit: { editingBook = book },
                            onDelete: { bookToDelete = book },
                            onShowDetail: canShowOnlineBookDetail(for: book)
                                ? { showOnlineBookDetail(for: book) }
                                : nil
                        )
                        .tag(book.id)
                    case .folder(let name, let books):
                        BookshelfFolderRow(name: name, books: books, isSelecting: isSelecting) {
                            openedFolder = name
                        }
                        .moveDisabled(true)
                    }
                }
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: hInset, bottom: 0, trailing: hInset))
                .listRowBackground(Color.clear)
                .background {
                    // The first row of the page in view measures its scroll for the title's fade.
                    if measuresTitleFade, entry.id == entries.first?.id {
                        Color.clear.rootTabTitleScrollAnchor()
                    }
                }
                .transition(
                    reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .move(edge: .leading))
                )
            }
            .onMove { src, dst in
                guard sortOrder == BookSortOrder.manual.rawValue else { return }
                // Folders stay put; a book dropped before one lands before its first book.
                let movingIds = src.compactMap { entries[$0].book?.id }
                let targetId: UUID? = dst < entries.count ? entries[dst].firstBookID : nil
                store.moveBooks(ids: movingIds, before: targetId)
            }
        }
        .softScrollEdges()
        .listStyle(.plain)
        .environment(\.editMode, $editMode)
        .animation(reduceMotion ? nil : DSAnimation.standard, value: entries.map(\.id))
        .accessibilityIdentifier(shelfAccessibilityIdentifier(for: page, isInView: isInView, grid: false))
        .refreshable {
            await ChapterUpdater.refreshAll(bookStore: store)
        }
    }

    /// The page in view answers to `home_book_list` / `home_book_grid`, a group's page pushed
    /// from its folder to `home_folder_list` / `home_folder_grid`.
    private func shelfAccessibilityIdentifier(for page: ShelfPage, isInView: Bool, grid: Bool) -> String {
        let kind = grid ? "grid" : "list"
        if !page.isOnPager { return "home_folder_\(kind)" }
        return isInView ? "home_book_\(kind)" : "home_book_\(kind)_offscreen"
    }

    // MARK: - Book Grid
    private func bookGrid(entries: [ShelfEntry], page: ShelfPage, isInView: Bool) -> some View {
        let coverDisplaySize = gridCoverDisplaySize
        let selectedCoverScale = BookshelfGridSelectionStyle.liftScale(
            coverSize: coverDisplaySize,
            columnSpacing: gridColumnSpacing
        )
        // The grid has no List to draw selection for it: each cell shows its own place
        // in `selectedBookIds`, and a tap in 選取 toggles it instead of opening the book.
        let isSelecting = editMode == .active
        return ScrollViewReader { proxy in
            bookGridScrollView(
                entries: entries,
                page: page,
                isInView: isInView,
                coverDisplaySize: coverDisplaySize,
                selectedCoverScale: selectedCoverScale,
                isSelecting: isSelecting
            )
            .onChange(of: shelfScrollToTopRequest) {
                if shelfScrollToTopPage == page {
                    proxy.scrollTo(Self.gridTopAnchorID, anchor: .top)
                }
            }
        }
    }

    /// The grid's content, for `ScrollViewReader.scrollTo` to bring back to the top.
    private static let gridTopAnchorID = "bookshelf-grid-top"

    private func bookGridScrollView(
        entries: [ShelfEntry],
        page: ShelfPage,
        isInView: Bool,
        coverDisplaySize: CGSize,
        selectedCoverScale: CGFloat,
        isSelecting: Bool
    ) -> some View {
        ScrollView {
            LazyVGrid(
                columns: gridColumns,
                spacing: DSSpacing.lg
            ) {
                ForEach(entries) { entry in
                    switch entry {
                    case .book(let book):
                        BookGridCell(
                            book: book,
                            isCompactLayout: isCompactFiveColumnGrid,
                            coverDisplaySize: coverDisplaySize,
                            isEditing: isSelecting,
                            isSelected: selectedBookIds.contains(book.id),
                            selectedCoverScale: selectedCoverScale,
                            transitionNamespace: bookTransition,
                            onOpen: { sourceGeometry in
                                openBook(book, from: page, sourceGeometry: sourceGeometry)
                            },
                            onToggleSelection: { toggleSelection(of: book.id) },
                            onCoverFrameChange: { frame in
                                readerGeometryStore.update(frame, for: book.id, onPage: page)
                            },
                            onEdit: { editingBook = book },
                            onDelete: { bookToDelete = book },
                            onShowDetail: canShowOnlineBookDetail(for: book)
                                ? { showOnlineBookDetail(for: book) }
                                : nil
                        )
                    case .folder(let name, let books):
                        BookshelfFolderGridCell(
                            name: name,
                            books: books,
                            isCompactLayout: isCompactFiveColumnGrid,
                            coverDisplaySize: coverDisplaySize,
                            isSelecting: isSelecting
                        ) {
                            openedFolder = name
                        }
                    }
                }
            }
            .padding(.horizontal, gridHorizontalInset)
            .padding(.vertical, DSSpacing.md)
            .background {
                // The page in view measures its scroll for the title's fade; a group's page
                // pushed over the shelf leaves 書架's title alone.
                if isInView, page.isOnPager {
                    Color.clear.rootTabTitleScrollAnchor()
                }
            }
            .id(Self.gridTopAnchorID)
        }
        .accessibilityIdentifier(shelfAccessibilityIdentifier(for: page, isInView: isInView, grid: true))
        .softScrollEdges()
        .animation(reduceMotion ? nil : DSAnimation.standard, value: entries.map(\.id))
        .animation(reduceMotion ? nil : DSAnimation.standard, value: gs.bookshelfGridColumnCount)
        .refreshable {
            await ChapterUpdater.refreshAll(bookStore: store)
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            gridContainerWidth = width
        }
    }

    /// Puts the book into the 選取 selection, or takes it out.
    private func toggleSelection(of bookID: UUID) {
        if selectedBookIds.remove(bookID) == nil {
            selectedBookIds.insert(bookID)
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
                .toolbarTitleDisplayMode(.inline)
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

                    Section(header: Text(localized("基本資訊")).foregroundStyle(DSColor.textSecondary)) {
                        HStack {
                            Text(localized("書名"))
                                .foregroundStyle(DSColor.textPrimary)
                            Spacer()
                            TextField(localized("書名"), text: $titleInput)
                                .multilineTextAlignment(.trailing)
                        }
                        HStack {
                            Text(localized("作者"))
                                .foregroundStyle(DSColor.textPrimary)
                            Spacer()
                            TextField(localized("作者"), text: $authorInput)
                                .multilineTextAlignment(.trailing)
                        }
                        HStack {
                            Text(localized("分組"))
                                .foregroundStyle(DSColor.textPrimary)
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
                    Section(header: Text(localized("閱讀進度")).foregroundStyle(DSColor.textSecondary)) {
                        HStack {
                            Text(localized("目前進度"))
                                .foregroundStyle(DSColor.textPrimary)
                            Spacer()
                            Text("\(Int(book.currentPosition * 100))%")
                                .foregroundStyle(DSColor.textSecondary)
                        }
                        HStack {
                            Text(localized("加入時間"))
                                .foregroundStyle(DSColor.textPrimary)
                            Spacer()
                            Text(book.addedDate, style: .date)
                                .foregroundStyle(DSColor.textSecondary)
                        }
                        HStack {
                            Text(localized("來源"))
                                .foregroundStyle(DSColor.textPrimary)
                            Spacer()
                            Text(book.source == "local" ? localized("本機文件") : localized("網頁匯入"))
                                .foregroundStyle(DSColor.textSecondary)
                        }
                    }
                    .interfaceSectionSurface()
                }
                .softScrollEdges()
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
                OnlineCoverSearchView(
                    title: liveBook.title,
                    author: liveBook.author
                ) { candidate in
                    applyCover(url: candidate.coverUrl, sourceId: candidate.sourceId)
                }
            } label: {
                SettingsRowLabel(localized("封面搜索"), systemImage: "globe")
            }
            .disabled(isApplyingCover)

            NavigationLink {
                ChangeCoverView(
                    bookId: book.id,
                    title: liveBook.title,
                    author: liveBook.author
                ) { candidate in
                    applyCover(url: candidate.coverUrl, sourceId: candidate.sourceId)
                }
            } label: {
                SettingsRowLabel(localized("換封面"), systemImage: "books.vertical")
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
                .foregroundStyle(DSColor.textSecondary)
        } footer: {
            Text(localized("封面搜索會上網找封面；換封面則在你已加入的書源裡，尋找同書名同作者的封面。"))
                .dsSectionFooter()
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
                .dsSectionFooter()
        }
        .interfaceSectionSurface()
    }

    private var canApplyCoverUrl: Bool {
        let trimmed = coverUrlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return false }
        return url.scheme?.hasPrefix("http") == true
    }

    /// The artwork itself, filling whatever frame the caller gives it: the user's
    /// own image when they set one, otherwise the source's cover. Loaded like a
    /// shelf card, off the main thread, at the hero's size.
    private var coverArtwork: some View {
        BookshelfCoverArtwork(
            book: liveBook,
            plan: .bookInfo(for: liveBook),
            displaySize: CGSize(width: DSLayout.bookCoverHeroWidth, height: DSLayout.bookCoverHeroHeight)
        )
    }

    /// 書籍資訊 opens on the cover: the artwork at a size worth looking at, lifted
    /// off a blurred wash of itself that melts into the page background.
    ///
    /// Both layers render one `coverArtwork` value. They request the same size, so
    /// the pipeline decodes the file once for both.
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
                .foregroundStyle(DSColor.textPrimary)
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
                    .foregroundStyle(DSColor.textPrimary)
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding()
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(DSAnimation.standard) { appeared = true }
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

    /// A row's cover. A group's folder in the list takes the same frame.
    static let coverSize = CGSize(width: 45, height: 65)
    private let coverW: CGFloat = BookRow.coverSize.width
    private let coverH: CGFloat = BookRow.coverSize.height
    @State private var liveCoverFrame: CGRect = .zero
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if isEditing {
            // Let List retain its native multi-selection accessibility actions.
            content
        } else {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(BookshelfAccessibility.description(for: book))
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { openBook() }
                .accessibilityActions {
                    if let onShowDetail {
                        Button(localized("書籍詳情")) { onShowDetail() }
                    }
                    Button(localized("編輯書籍資訊")) { onEdit() }
                    Button(localized("刪除書籍"), role: .destructive) { onDelete() }
                }
        }
    }

    private func openBook() {
        onTap(liveCoverFrame.isEmpty ? nil : ReaderCardGeometry(
            frame: liveCoverFrame, cornerRadius: BookshelfCoverStyle.cornerRadius
        ))
    }

    private var content: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                // In edit mode the row is plain content so the List's native selection circle handles
                // taps; otherwise it's a button that opens the book.
                if isEditing {
                    rowContent
                } else {
                    Button(action: openBook) { rowContent }
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
                    .foregroundStyle(DSColor.textPrimary)

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
        let total = book.offlineDownloadTask?.clamped(to: book.totalChapterNum ?? 0)?.totalChapterCount
            ?? book.totalChapterNum
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

    private var bookCover: some View {
        BookshelfCoverStyle.artwork(
            for: book,
            colorScheme: colorScheme,
            displaySize: CGSize(width: coverW, height: coverH)
        )
            .frame(width: coverW, height: coverH)
            .clipShape(RoundedRectangle(cornerRadius: BookshelfCoverStyle.cornerRadius))
            .shadow(color: .black.opacity(0.08), radius: 15, x: 0, y: 10)
            .overlay(alignment: .bottomTrailing) {
                if book.resolvedPipelineKind == .audio { AudiobookCoverBadge(glyphSize: 7) }
            }
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
    /// The cover's frame as the grid lays it out; picks the decode size.
    var coverDisplaySize: CGSize = .zero
    /// 選取 is on: a tap selects the book instead of opening it, and the cover shows
    /// whether it is in the selection. The shelf owns the selection; the cell reports taps.
    var isEditing: Bool = false
    var isSelected: Bool = false
    /// How much a selected cover lifts, from `BookshelfGridSelectionStyle.liftScale`.
    var selectedCoverScale: CGFloat = 1
    var transitionNamespace: Namespace.ID? = nil
    let onOpen: (ReaderCardGeometry?) -> Void
    var onToggleSelection: () -> Void = {}
    var onCoverFrameChange: ((CGRect) -> Void)? = nil
    let onEdit: () -> Void
    let onDelete: () -> Void
    var onShowDetail: (() -> Void)? = nil
    @State private var liveCoverFrame: CGRect = .zero
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Cover geometry for the open-book card transition, or nil before the cover
    /// has reported a frame. The radius has to match what the cell actually
    /// clipped with, or the card visibly re-rounds as it lifts off the shelf.
    private var readerCardGeometry: ReaderCardGeometry? {
        liveCoverFrame.isEmpty
            ? nil
            : ReaderCardGeometry(frame: liveCoverFrame, cornerRadius: BookshelfCoverStyle.cornerRadius)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DSLayout.bookshelfGridCoverTitleSpacing) {
            Button(action: activate) {
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
                // While 選取 is on, a cover out of the selection dims and one in it
                // lifts. The mark sits outside the dimming, so it stays white.
                .opacity(isEditing && !isSelected ? DSLayout.bookshelfUnselectedCoverOpacity : 1)
                .overlay(alignment: .bottomTrailing) {
                    if isEditing {
                        BookshelfSelectionMark(isSelected: isSelected)
                            .padding(isCompactLayout ? DSSpacing.xs : DSSpacing.sm)
                            .transition(.opacity)
                    }
                }
                .scaleEffect(coverLiftScale, anchor: BookshelfGridSelectionStyle.liftAnchor)
                // However the selection changed: a tap, 全選, or clearing it.
                .animation(DSAnimation.standard, value: isSelected)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                    .font(DSFont.fixed(size: isCompactLayout ? 12 : 13, weight: .semibold))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(DSColor.textPrimary)

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
                    // 選取 takes the per-book menu away, as it does in the list. It keeps
                    // its room, so the shelf does not reflow on the way in and out.
                    .opacity(isEditing ? 0 : 1)
                    .allowsHitTesting(!isEditing)
                }
            }
            // While selecting, the title and author select the book too.
            .contentShape(Rectangle())
            .gesture(TapGesture().onEnded(onToggleSelection), including: isEditing ? .all : .subviews)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: liveCoverFrame) { _, frame in
            if !frame.isEmpty { onCoverFrameChange?(frame) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(BookshelfAccessibility.description(for: book))
        .accessibilityAddTraits(isEditing && isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { activate() }
        // The overflow menu is no longer its own element, so its items become the
        // cell's rotor actions instead — gone with the menu while selecting.
        .accessibilityActions {
            if !isEditing {
                if let onShowDetail {
                    Button(localized("書籍詳情")) { onShowDetail() }
                }
                Button(localized("編輯書籍資訊")) { onEdit() }
                Button(localized("刪除書籍"), role: .destructive) { onDelete() }
            }
        }
    }

    /// Opens the book, or while selecting, puts it in or out of the selection.
    private func activate() {
        if isEditing {
            onToggleSelection()
        } else {
            onOpen(readerCardGeometry)
        }
    }

    /// A selected cover lifts; with Reduce Motion it stays put and the dimming and the
    /// mark alone tell it apart.
    private var coverLiftScale: CGFloat {
        isEditing && isSelected && !reduceMotion ? selectedCoverScale : 1
    }

    private var coverView: some View {
        Color.clear
            .aspectRatio(2/3, contentMode: .fit)
            .overlay(
                BookshelfCoverStyle.artwork(
                    for: book,
                    colorScheme: colorScheme,
                    displaySize: coverDisplaySize
                )
            )
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: BookshelfCoverStyle.cornerRadius))
            .shadow(color: .black.opacity(0.18), radius: 4, x: 0, y: 2)
            .overlay(alignment: .bottomTrailing) {
                // The selection mark takes this corner while selecting.
                if book.resolvedPipelineKind == .audio && !isEditing {
                    AudiobookCoverBadge(glyphSize: 11)
                }
            }
    }

}

// MARK: - Group Folder

/// A group on 全部: the covers of its first four books, two by two, in the frame a book's
/// cover takes — a folder, as iOS gathers apps. A group of fewer books leaves the rest of
/// the folder empty. It fills the frame it is given; `displaySize` is that frame, and sets
/// the margins and the covers' decode size.
private struct BookshelfFolderCover: View {
    let books: [ReadingBook]
    let displaySize: CGSize
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let inset = displaySize.width * DSLayout.bookshelfFolderInsetRatio
        let spacing = displaySize.width * DSLayout.bookshelfFolderSpacingRatio
        let coverSize = CGSize(
            width: max(0, (displaySize.width - inset * 2 - spacing) / 2),
            height: max(0, (displaySize.height - inset * 2 - spacing) / 2)
        )
        Grid(horizontalSpacing: spacing, verticalSpacing: spacing) {
            GridRow {
                cover(0, displaySize: coverSize)
                cover(1, displaySize: coverSize)
            }
            GridRow {
                cover(2, displaySize: coverSize)
                cover(3, displaySize: coverSize)
            }
        }
        .padding(inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DSColor.surface)
    }

    private func cover(_ index: Int, displaySize: CGSize) -> some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if books.indices.contains(index) {
                    BookshelfCoverStyle.artwork(for: books[index], colorScheme: colorScheme, displaySize: displaySize)
                }
            }
            .clipShape(RoundedRectangle(
                cornerRadius: BookshelfCoverStyle.cornerRadius * DSLayout.bookshelfFolderCoverRadiusRatio
            ))
    }
}

/// How a group names itself: its name, and how many books are in it.
private enum BookshelfFolderLabel {
    static func count(_ bookCount: Int) -> String {
        String(format: localized("%d 本"), bookCount)
    }

    static func accessibilityLabel(name: String, books: [ReadingBook]) -> String {
        name + "，" + count(books.count)
    }
}

/// A group on 全部 in the list: its folder where a book's cover would be, its name, and how
/// many books it holds. A tap opens the group's page. 選取 takes books only, so the folder
/// dims and takes no taps while it is on.
private struct BookshelfFolderRow: View {
    let name: String
    let books: [ReadingBook]
    var isSelecting = false
    let onOpen: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onOpen) {
                HStack(alignment: .top, spacing: 12) {
                    BookshelfFolderCover(books: books, displaySize: BookRow.coverSize)
                        .frame(width: BookRow.coverSize.width, height: BookRow.coverSize.height)
                        .clipShape(RoundedRectangle(cornerRadius: BookshelfCoverStyle.cornerRadius))
                        .shadow(color: .black.opacity(0.08), radius: 15, x: 0, y: 10)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(name)
                            .font(DSFont.fixed(size: 15, weight: .medium))
                            .lineLimit(2)
                            .foregroundStyle(DSColor.textPrimary)
                        Text(BookshelfFolderLabel.count(books.count))
                            .font(DSFont.fixed(size: 13))
                            .foregroundColor(DSColor.textSecondary)
                            .lineLimit(1)
                    }
                    .padding(.top, 2)

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(DSFont.fixed(size: 14, weight: .semibold))
                        .foregroundStyle(DSColor.textTertiary)
                        .frame(maxHeight: .infinity)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isSelecting ? DSLayout.bookshelfUnselectedCoverOpacity : 1)
            .padding(.vertical, 10)

            Rectangle()
                .fill(Color(uiColor: .separator))
                .frame(height: 0.5)
        }
        .disabled(isSelecting)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(BookshelfFolderLabel.accessibilityLabel(name: name, books: books))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onOpen() }
        .accessibilityIdentifier("home_group_folder")
    }
}

/// A group on 全部 in the grid: its folder in a book's cover's place, its name in the
/// title's, and how many books it holds in the author's.
private struct BookshelfFolderGridCell: View {
    let name: String
    let books: [ReadingBook]
    var isCompactLayout = false
    /// The cover's frame as the grid lays it out, which the folder takes.
    var coverDisplaySize: CGSize = .zero
    var isSelecting = false
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: DSLayout.bookshelfGridCoverTitleSpacing) {
                Color.clear
                    .aspectRatio(2/3, contentMode: .fit)
                    .overlay(BookshelfFolderCover(books: books, displaySize: coverDisplaySize))
                    .clipShape(RoundedRectangle(cornerRadius: BookshelfCoverStyle.cornerRadius))
                    .shadow(color: .black.opacity(0.18), radius: 4, x: 0, y: 2)

                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(DSFont.fixed(size: isCompactLayout ? 12 : 13, weight: .semibold))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(DSColor.textPrimary)
                    Text(BookshelfFolderLabel.count(books.count))
                        .font(DSFont.fixed(size: isCompactLayout ? 10 : 11))
                        .foregroundColor(DSColor.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isSelecting ? DSLayout.bookshelfUnselectedCoverOpacity : 1)
        .disabled(isSelecting)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(BookshelfFolderLabel.accessibilityLabel(name: name, books: books))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onOpen() }
        .accessibilityIdentifier("home_group_folder")
    }
}

// MARK: - Add to Group Sheet

/// 加入分組: 新建分組 first, which names a group in an alert and puts the books straight in,
/// then each of the shelf's groups with how many books it holds, and 取消 on its own below.
private struct BookshelfAddToGroupSheet: View {
    let groups: [(name: String, count: Int)]
    let onChoose: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showsNewGroupAlert = false
    @State private var newGroupName = ""
    /// The list's full height, which the sheet takes: as tall as its buttons, however many
    /// groups there are and however large the text. Nil until the list is laid out.
    @State private var listHeight: CGFloat?

    var body: some View {
        List {
            Section {
                Button {
                    newGroupName = ""
                    showsNewGroupAlert = true
                } label: {
                    Label {
                        Text(localized("新建分組"))
                            .foregroundStyle(DSColor.textPrimary)
                    } icon: {
                        Image(systemName: "plus")
                            .foregroundStyle(DSColor.textSecondary)
                    }
                }
                .background {
                    Color.clear.reportsScrollContentHeight { listHeight = $0 }
                }
                ForEach(groups, id: \.name) { group in
                    Button {
                        choose(group.name)
                    } label: {
                        LabeledContent {
                            Text(BookshelfFolderLabel.count(group.count))
                        } label: {
                            Label {
                                Text(group.name)
                                    .foregroundStyle(DSColor.textPrimary)
                            } icon: {
                                Image(systemName: "folder")
                                    .foregroundStyle(DSColor.textSecondary)
                            }
                        }
                    }
                }
            } header: {
                Text(localized("加入分組"))
                    .font(DSFont.subheadline)
                    .foregroundStyle(DSColor.textSecondary)
                    .textCase(nil)
                    .frame(maxWidth: .infinity)
                    .accessibilityAddTraits(.isHeader)
            }
            .interfaceSectionSurface()

            Section {
                Button {
                    dismiss()
                } label: {
                    Text(localized("取消"))
                        .font(DSFont.body.weight(.semibold))
                        .foregroundStyle(DSColor.textSecondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .interfaceSectionSurface()
        }
        .listStyle(.insetGrouped)
        .softScrollEdges()
        .themedAppSurface(for: .bookshelf)
        .presentationDetents(detents)
        .alert(localized("新建分組"), isPresented: $showsNewGroupAlert) {
            TextField(localized("分組名稱"), text: $newGroupName)
            Button(localized("新建")) {
                choose(newGroupName.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            Button(localized("取消"), role: .cancel) {}
        }
    }

    /// The list's height once it is known; the medium height for the moment before.
    private var detents: Set<PresentationDetent> {
        if let listHeight { [.height(listHeight)] } else { [.medium] }
    }

    /// Puts the books in `group` and closes the sheet. A new group left unnamed keeps the
    /// sheet open, its books where they were.
    private func choose(_ group: String) {
        guard !group.isEmpty else { return }
        onChoose(group)
        dismiss()
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
    // A shelf record: the summary of its table of contents, not the list.
    book.applyChapterSummary(from: [
        OnlineChapterRef(index: 0, title: "第一章 開始", url: "https://example.com/1"),
        OnlineChapterRef(index: 1, title: "第一百零八章 大結局", url: "https://example.com/108"),
    ])
    book.hasNewChapterUpdate = hasUpdate
    return book
}

#Preview("BookRow – 有更新 / 無更新") {
    List {
        BookRow(book: previewOnlineBook(hasUpdate: true), onTap: { _ in }, onEdit: {}, onDelete: {})
        BookRow(book: previewOnlineBook(hasUpdate: false), onTap: { _ in }, onEdit: {}, onDelete: {})
    }
    .softScrollEdges()
    .listStyle(.plain)
}

#Preview("BookGridCell – 有更新 / 無更新") {
    LazyVGrid(
        columns: Array(repeating: GridItem(.flexible(), spacing: DSSpacing.md), count: 3),
        spacing: DSSpacing.lg
    ) {
        BookGridCell(
            book: previewOnlineBook(hasUpdate: true),
            coverDisplaySize: CGSize(width: 110, height: 165),
            onOpen: { _ in }, onEdit: {}, onDelete: {}
        )
        BookGridCell(
            book: previewOnlineBook(hasUpdate: false),
            coverDisplaySize: CGSize(width: 110, height: 165),
            onOpen: { _ in }, onEdit: {}, onDelete: {}
        )
    }
    .padding()
}

#Preview("BookGridCell – 選取中") {
    @Previewable @State var selected: Set<Int> = [1]
    let coverSize = CGSize(width: 110, height: 165)
    LazyVGrid(
        columns: Array(repeating: GridItem(.flexible(), spacing: DSSpacing.md, alignment: .top), count: 3),
        spacing: DSSpacing.lg
    ) {
        ForEach(0..<6, id: \.self) { index in
            BookGridCell(
                book: previewOnlineBook(hasUpdate: index == 0),
                coverDisplaySize: coverSize,
                isEditing: true,
                isSelected: selected.contains(index),
                selectedCoverScale: BookshelfGridSelectionStyle.liftScale(
                    coverSize: coverSize,
                    columnSpacing: DSSpacing.md
                ),
                onOpen: { _ in },
                onToggleSelection: {
                    if selected.remove(index) == nil { selected.insert(index) }
                },
                onEdit: {}, onDelete: {}
            )
        }
    }
    .padding()
}

#Preview("分組資料夾 – 列表／格狀") {
    let books = (0..<3).map { previewOnlineBook(hasUpdate: $0 == 0) }
    let coverSize = CGSize(width: 110, height: 165)
    VStack(spacing: 0) {
        List {
            BookshelfFolderRow(name: "在追", books: books) {}
            BookshelfFolderRow(name: "同人", books: Array(books.prefix(1))) {}
            BookshelfFolderRow(name: "選取中", books: books, isSelecting: true) {}
        }
        .listStyle(.plain)
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: DSSpacing.md, alignment: .top), count: 3),
            spacing: DSSpacing.lg
        ) {
            BookshelfFolderGridCell(name: "在追", books: books, coverDisplaySize: coverSize) {}
            BookshelfFolderGridCell(name: "同人", books: Array(books.prefix(1)), coverDisplaySize: coverSize) {}
            BookshelfFolderGridCell(name: "選取中", books: books, coverDisplaySize: coverSize, isSelecting: true) {}
        }
        .padding()
    }
    .background(DSColor.groupedBackground)
}

#Preview("加入分組") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            BookshelfAddToGroupSheet(groups: [("未看", 18), ("在追", 18), ("同人", 3)]) { _ in }
        }
}

#Preview("書籍資訊 – 封面區") {
    EditBookSheet(book: previewOnlineBook(hasUpdate: false)) { _, _, _ in }
        .environmentObject(BookStore())
}
#endif
