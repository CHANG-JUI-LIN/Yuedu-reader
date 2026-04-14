import SwiftUI
import UniformTypeIdentifiers

// MARK: - 排序方式
enum BookSortOrder: String, CaseIterable {
    case dateAdded = "加入時間"
    case titleAZ = "書名 A-Z"
    case progress = "閱讀進度"
}

// MARK: - 書架主頁
struct HomeView: View {
    @EnvironmentObject var store: BookStore
    @ObservedObject private var gs = GlobalSettings.shared

    @State private var showAddSheet = false
    @State private var addSheetSessionID = UUID()
    @State private var searchText = ""
    @State private var sortOrder = BookSortOrder.dateAdded
    @State private var editingBook: ReadingBook? = nil
    @State private var bookToDelete: ReadingBook? = nil
    @State private var editMode = EditMode.inactive
    @State private var showSearch = false
    @AppStorage("bookLayoutIsGrid") private var isGridMode = false

    // fullScreenCover 閱讀器（取代 NavigationLink，避免 SwiftUI NavLink 重建 @State bug）
    @State private var readerBookId: UUID? = nil

    // 過濾 + 排序
    var filteredBooks: [ReadingBook] {
        let base =
            searchText.isEmpty
            ? store.books
            : store.books.filter {
                $0.title.localizedCaseInsensitiveContains(searchText)
                    || $0.author.localizedCaseInsensitiveContains(searchText)
            }
        switch sortOrder {
        case .dateAdded: return base  // 原始順序（最新在前）
        case .titleAZ: return base.sorted { $0.title < $1.title }
        case .progress: return base.sorted { $0.currentPosition > $1.currentPosition }
        }
    }

    var body: some View {
        NavigationView {
            AdaptiveContentContainer(maxWidth: 920) {
                Group {
                    if store.books.isEmpty {
                        EmptyLibraryView(
                            showAdd: $showAddSheet,
                            showSearch: $showSearch
                        )
                            .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    } else {
                        VStack(spacing: 0) {
                            // 搜尋欄
                            searchBar
                            // 排序選擇（僅在編輯模式顯示）
                            if editMode == .active {
                                sortBar
                            }
                            Divider()
                            // 書籍列表 / 網格
                            if isGridMode { bookGrid } else { bookList }
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    }
                }
            }
            .animation(DSAnimation.standard, value: store.books.isEmpty)
            .navigationTitle(gs.t("書架"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        withAnimation {
                            editMode = editMode == .active ? .inactive : .active
                        }
                    } label: {
                        Text(editMode == .active ? gs.t("完成") : gs.t("編輯"))
                    }
                    .id(gs.appLanguage.rawValue + (editMode == .active ? "_done" : "_edit"))
                    .environment(\.editMode, $editMode)
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    // 佈局切換
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { isGridMode.toggle() }
                    } label: {
                        Image(systemName: isGridMode ? "list.bullet" : "square.grid.2x2")
                            .font(DSFont.toolbarIcon)
                    }
                    // 書籍搜索
                    Button { showSearch = true } label: {
                        Image(systemName: "magnifyingglass")
                            .font(DSFont.toolbarIcon)
                    }
                    // 新增本地書籍
                    Button {
                        addSheetSessionID = UUID()
                        showAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                            .font(DSFont.toolbarIconLarge)
                    }
                }
            }
            .sheet(isPresented: $showAddSheet) {
                AdaptiveSheetContainer(maxWidth: 760) {
                    AddBookView()
                        .id(addSheetSessionID)
                        .environmentObject(store)
                }
            }
            .onChange(of: showAddSheet) { isPresented in
                if isPresented {
                    addSheetSessionID = UUID()
                }
            }
            .sheet(isPresented: $showSearch) {
                AdaptiveSheetContainer(maxWidth: 900) {
                    BookSearchView().environmentObject(store)
                }
            }
            // 編輯書籍資訊 Sheet
            .sheet(item: $editingBook) { book in
                AdaptiveSheetContainer(maxWidth: 640) {
                    EditBookSheet(book: book) { newTitle, newAuthor in
                        store.updateBook(bookId: book.id, title: newTitle, author: newAuthor)
                    }
                }
            }
            // 刪除確認對話框
            .alert(
                gs.t("確認刪除"),
                isPresented: Binding(
                    get: { bookToDelete != nil },
                    set: { if !$0 { bookToDelete = nil } }
                )
            ) {
                Button(gs.t("刪除"), role: .destructive) {
                    if let b = bookToDelete { store.delete(bookId: b.id) }
                }
                Button(gs.t("取消"), role: .cancel) {}
            } message: {
                if let b = bookToDelete {
                    Text(gs.t("確定要從書架刪除") + "《\(b.title)》" + gs.t("嗎？"))
                }
            }
        }
        .navigationViewStyle(.stack)
        .fullScreenCover(
            isPresented: Binding(
                get: { readerBookId != nil },
                set: { if !$0 { readerBookId = nil } }
            )
        ) {
            if let bookId = readerBookId {
                ReaderView(bookId: bookId).environmentObject(store)
            }
        }
    }

    // MARK: - 搜尋欄
    private var searchBar: some View {
        DSSearchBar(placeholder: gs.t("搜索書名或作者"), text: $searchText)
    }

    // MARK: - 排序欄
    private var sortBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DSSpacing.sm) {
                Text(gs.t("排序：")).font(DSFont.caption).foregroundColor(DSColor.textSecondary)
                ForEach(BookSortOrder.allCases, id: \.self) { order in
                    DSChip(title: gs.t(order.rawValue), isSelected: sortOrder == order) {
                        withAnimation { sortOrder = order }
                    }
                }
                Spacer()
                Text("\(filteredBooks.count) " + gs.t("本")).font(DSFont.caption).foregroundColor(DSColor.textSecondary)
            }
            .padding(.horizontal, DSSpacing.lg).padding(.vertical, 6)
        }
    }

    // MARK: - 書籍列表（條列式）
    private var bookList: some View {
        List {
            ForEach(filteredBooks) { book in
                HStack(spacing: 0) {
                    Button {
                        readerBookId = book.id
                    } label: {
                        BookRow(book: book)
                    }
                    .buttonStyle(.plain)

                    Menu {
                        Button { editingBook = book } label: {
                            Label(gs.t("編輯書籍資訊"), systemImage: "pencil")
                        }
                        Button(role: .destructive) { bookToDelete = book } label: {
                            Label(gs.t("刪除書籍"), systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 20))
                            .foregroundColor(DSColor.textSecondary)
                            .padding(.horizontal, 8)
                    }
                }
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 8))
                .listRowBackground(Color.clear)
                .transition(.opacity.combined(with: .move(edge: .leading)))
            }
            .onDelete { indexSet in
                withAnimation(.easeOut(duration: 0.25)) {
                    indexSet.forEach { store.delete(bookId: filteredBooks[$0].id) }
                }
            }
        }
        .listStyle(.plain)
        .environment(\.editMode, $editMode)
        .animation(.easeOut(duration: 0.25), value: filteredBooks.map(\.id))
        .accessibilityIdentifier("home_book_list")
    }

    // MARK: - 書籍網格（網格式）
    private var bookGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 100, maximum: 160), spacing: 10)],
                spacing: 12
            ) {
                ForEach(filteredBooks) { book in
                    BookGridCell(book: book, onOpen: { readerBookId = book.id }) {
                        editingBook = book
                    } onDelete: {
                        bookToDelete = book
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .animation(.easeOut(duration: 0.25), value: filteredBooks.map(\.id))
    }
}

// MARK: - 編輯書籍資訊 Sheet
struct EditBookSheet: View {
    let book: ReadingBook
    let onSave: (String, String) -> Void

    @State private var titleInput: String
    @State private var authorInput: String
    @Environment(\.presentationMode) var dismiss
    @ObservedObject private var gs = GlobalSettings.shared

    init(book: ReadingBook, onSave: @escaping (String, String) -> Void) {
        self.book = book
        self.onSave = onSave
        _titleInput = State(initialValue: book.title)
        _authorInput = State(initialValue: book.author)
    }

    var body: some View {
        NavigationView {
            AdaptiveSheetContainer(maxWidth: 640) {
                Form {
                    Section(header: Text(gs.t("基本資訊"))) {
                        HStack {
                            Text(gs.t("書名"))
                            Spacer()
                            TextField(gs.t("書名"), text: $titleInput)
                                .multilineTextAlignment(.trailing)
                        }
                        HStack {
                            Text(gs.t("作者"))
                            Spacer()
                            TextField(gs.t("作者"), text: $authorInput)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    Section(header: Text(gs.t("閱讀進度"))) {
                        HStack {
                            Text(gs.t("目前進度"))
                            Spacer()
                            Text("\(Int(book.currentPosition * 100))%")
                                .foregroundColor(.secondary)
                        }
                        HStack {
                            Text(gs.t("加入時間"))
                            Spacer()
                            Text(book.addedDate, style: .date)
                                .foregroundColor(.secondary)
                        }
                        HStack {
                            Text(gs.t("來源"))
                            Spacer()
                            Text(book.source == "local" ? gs.t("本機文件") : gs.t("網頁匯入"))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .navigationTitle(gs.t("書籍資訊"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button(gs.t("取消")) { dismiss.wrappedValue.dismiss() }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            onSave(titleInput, authorInput)
                            dismiss.wrappedValue.dismiss()
                        } label: {
                            Text(gs.t("儲存")).font(.body.weight(.semibold))
                        }
                        .disabled(titleInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
    }
}

// MARK: - 空書架
struct EmptyLibraryView: View {
    @Binding var showAdd: Bool
    @Binding var showSearch: Bool
    @ObservedObject private var gs = GlobalSettings.shared
    @State private var appeared = false
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "books.vertical")
                .font(.system(size: 72))
                .foregroundColor(DSColor.textSecondary.opacity(0.35))
            Text(gs.t("書架還是空的"))
                .font(DSFont.title2.weight(.semibold))
            Text(gs.t("匯入 TXT 文件，或是輸入網址\n抓取網頁小說加入書架"))
                .font(DSFont.subheadline).foregroundColor(DSColor.textSecondary).multilineTextAlignment(.center)
            Button {
                showAdd = true
            } label: {
                Label(gs.t("添加書籍"), systemImage: "plus")
                    .font(DSFont.headline).foregroundColor(.white)
                    .padding(.horizontal, DSSpacing.xxl).padding(.vertical, 14)
                    .background(DSColor.accent).clipShape(Capsule())
            }
            Button {
                showSearch = true
            } label: {
                Label(gs.t("搜索書籍"), systemImage: "magnifyingglass")
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

// MARK: - 書籍列表行
struct BookRow: View {
    let book: ReadingBook
    @ObservedObject private var gs = GlobalSettings.shared
    var body: some View {
        HStack(spacing: 14) {
            // 封面：優先顯示 EPUB 封面圖片，否則用漸層色塊
            bookCover

            VStack(alignment: .leading, spacing: 5) {
                Text(book.title).font(.headline).lineLimit(2)
                Text(book.author).font(DSFont.subheadline).foregroundColor(DSColor.textSecondary)
                Spacer(minLength: DSSpacing.xs)
                ProgressView(value: book.currentPosition).tint(DSColor.accent)
                HStack {
                    Text(
                        book.currentPosition < 0.01
                            ? gs.t("尚未開始")
                            : book.currentPosition >= 0.99
                                ? gs.t("已讀到最新章節")
                                : "\(Int(book.currentPosition * 100))% " + gs.t("已讀")
                    )
                    .font(DSFont.caption2).foregroundColor(DSColor.textSecondary)
                    Spacer()
                    Text(book.addedDate, style: .date)
                        .font(DSFont.caption2).foregroundColor(DSColor.textSecondary.opacity(0.6))
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    var bookCover: some View {
        if let coverPath = book.coverImagePath,
           let uiImage = loadCoverImage(filename: coverPath) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
                .frame(width: 56, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.2), radius: 4, x: 1, y: 2)
        } else {
            Text(book.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DSColor.textSecondary)
                .multilineTextAlignment(.leading)
                .lineLimit(4)
                .frame(width: 56, height: 76, alignment: .topLeading)
        }
    }

    func loadCoverImage(filename: String) -> UIImage? {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

}

// MARK: - 書籍網格格子
struct BookGridCell: View {
    let book: ReadingBook
    let onOpen: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    @ObservedObject private var gs = GlobalSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 封面
            Button(action: onOpen) {
                ZStack(alignment: .topTrailing) {
                    coverView
                    // 閱讀進度角標
                    if book.currentPosition > 0.01 && book.currentPosition < 0.99 {
                        Text("\(Int(book.currentPosition * 100))%")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(DSColor.accent.opacity(0.85))
                            .clipShape(Capsule())
                            .padding(6)
                    }
                }
            }
            .buttonStyle(.plain)

            // 書名 + 選單
            HStack(alignment: .top, spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(book.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(book.author)
                        .font(.system(size: 11))
                        .foregroundColor(DSColor.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 34, alignment: .topLeading)
                Spacer(minLength: 0)
                Menu {
                    Button { onEdit() } label: {
                        Label(gs.t("編輯書籍資訊"), systemImage: "pencil")
                    }
                    Button(role: .destructive) { onDelete() } label: {
                        Label(gs.t("刪除書籍"), systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14))
                        .foregroundColor(DSColor.textSecondary)
                        .padding(4)
                }
            }
            .frame(height: 34)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(color: .black.opacity(0.18), radius: 4, x: 0, y: 2)
        } else {
            base.overlay(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.secondarySystemBackground))
                    .overlay(
                        Text(book.title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DSColor.textSecondary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(6)
                            .padding(8),
                        alignment: .topLeading
                    )
            )
        }
    }

    private func loadCoverImage(filename: String) -> UIImage? {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

}
