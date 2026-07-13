import Combine
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Bookshelf Home
enum BookshelfCoverLoader {
    static func load(filename: String) -> UIImage? {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
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

    private func openBook(_ book: ReadingBook, sourceGeometry: ReaderCardGeometry?) {
        if BookCardNavigationGate.shouldUseCardTransition(for: book) {
            let requestToken = UUID()
            pendingReaderOpenToken = requestToken
            let snapshot: UIImage? = book.coverImagePath.flatMap {
                BookshelfCoverLoader.load(filename: $0)
            }
            Task { @MainActor in
                let direction = await resolveOpeningDirection(for: book)
                guard pendingReaderOpenToken == requestToken else { return }
                pendingReaderOpenToken = nil
                let source = ReaderTransitionSource(
                    bookID: book.id,
                    cornerRadius: sourceGeometry?.cornerRadius ?? DSRadius.md,
                    frame: sourceGeometry?.frame,
                    frameProvider: { [weak readerGeometryStore, weak store] in
                        guard store?.books.contains(where: { $0.id == book.id }) == true else {
                            return nil
                        }
                        return readerGeometryStore?.frame(for: book.id)
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
                    destination: { [weak readerCoordinator] in
                        ReaderHostingController(content: AnyView(
                            BookReaderView(bookId: readerBookID)
                                .environmentObject(readerStore)
                                .environment(\.appDependencies, readerDependencies)
                                .environment(\.readerNavigator, readerCoordinator)
                        ))
                    },
                    onTransitionCompleted: { [weak readerGeometryStore, weak store] in
                        if shouldInvalidateForRecentSort {
                            // Do not let a closing transition use the old row
                            // position while the recently-read sort moves it.
                            readerGeometryStore?.invalidate(bookID: readerBookID)
                        }
                        store?.updateLastOpened(bookId: readerBookID)
                    }
                )
            }
        } else {
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
            let flow = await PublicationSession.inspectOpeningFlow(sourceURL: url)
            return ReaderBookOpeningDirection.resolve(
                writingMode: flow.isVertical ? .verticalRTL : .horizontal,
                pageProgressionIsRTL: flow.pageProgressionIsRTL
            )
        }

        let writingMode: ReaderWritingMode = book.allowsVerticalWritingMode
            ? gs.readerWritingMode
            : .horizontal
        return ReaderBookOpeningDirection.resolve(
            writingMode: writingMode,
            pageProgressionIsRTL: false
        )
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
                    if #available(iOS 26.0, *) {
                        ToolbarSpacer(.fixed, placement: .navigationBarTrailing)
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        addBookMenu
                    }
                }
            }
            // In edit mode, hide the app tab bar so the contextual .bottomBar (delete / group / share)
            // takes its place — the system selection pattern used by Photos / Files.
            .toolbar(editMode == .active ? .hidden : .automatic, for: .tabBar)
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
                    AudiobookDetailView(book: book)
                        .environmentObject(store)
                } else {
                    OnlineBookView(book: book)
                        .environmentObject(store)
                }
            }
            .sheet(item: $editingBook) { book in
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

    private var addBookMenu: some View {
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
                .foregroundColor(.black)
        }
        .id("\(Locale.autoupdatingCurrent.identifier)_add_menu")
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
                .foregroundColor(.black)
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
struct EditBookSheet: View {
    let book: ReadingBook
    let onSave: (String, String, String) -> Void

    @State private var titleInput: String
    @State private var authorInput: String
    @State private var groupInput: String
    @Environment(\.presentationMode) var dismiss
    @EnvironmentObject private var store: BookStore

    init(book: ReadingBook, onSave: @escaping (String, String, String) -> Void) {
        self.book = book
        self.onSave = onSave
        _titleInput = State(initialValue: book.title)
        _authorInput = State(initialValue: book.author)
        _groupInput = State(initialValue: book.group)
    }

    var body: some View {
        NavigationStack {
            AdaptiveSheetContainer(maxWidth: DSLayout.readableCompactWidth) {
                Form {
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
                }
                .navigationTitle(localized("書籍資訊"))
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
                            onSave(titleInput, authorInput, groupInput)
                            dismiss.wrappedValue.dismiss()
                        } label: {
                            Image(systemName: "checkmark")
                        }
                        .disabled(titleInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
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
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: {
                onOpen(
                    liveCoverFrame.isEmpty
                        ? nil
                        : ReaderCardGeometry(
                            frame: liveCoverFrame,
                            cornerRadius: DSRadius.md
                        )
                )
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
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
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
                Section {
                    Text(localized("將套用到") + " \(bookCount) " + localized("本書"))
                        .font(DSFont.footnote)
                        .foregroundColor(DSColor.textSecondary)
                }
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
#endif
