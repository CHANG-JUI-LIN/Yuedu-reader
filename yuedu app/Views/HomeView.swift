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
                BookRow(
                    book: book,
                    onOpen: { readerBookId = book.id },
                    onEdit: { editingBook = book },
                    onDelete: { bookToDelete = book }
                )
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
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

// MARK: - 書籍列表行（Apple Books 風格）
struct BookRow: View {
    let book: ReadingBook
    let onOpen: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    @ObservedObject private var gs = GlobalSettings.shared

    private let coverW: CGFloat = 45
    private let coverH: CGFloat = 65

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onOpen) {
                HStack(alignment: .top, spacing: 12) {
                    bookCover

                    VStack(alignment: .leading, spacing: 5) {
                        Text(book.title)
                            .font(.system(size: 15, weight: .medium))
                            .lineLimit(2)
                            .foregroundColor(.primary)

                        if !book.author.isEmpty {
                            Text(book.author)
                                .font(.system(size: 13))
                                .foregroundColor(DSColor.textSecondary)
                                .lineLimit(1)
                        }

                        progressBadge
                    }
                    .padding(.top, 2)

                    Spacer(minLength: 0)

                    // 右側雙 icon：雲端 + 三點選單，沉底對齊 badge
                    VStack {
                        Spacer(minLength: 0)
                        HStack(spacing: 18) {
                            Image(systemName: "cloud")
                                .font(.system(size: 16))
                                .foregroundColor(DSColor.textSecondary)

                            Menu {
                                Button { onEdit() } label: {
                                    Label(gs.t("編輯書籍資訊"), systemImage: "pencil")
                                }
                                Button(role: .destructive) { onDelete() } label: {
                                    Label(gs.t("刪除書籍"), systemImage: "trash")
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 16))
                                    .foregroundColor(DSColor.textSecondary)
                            }
                        }
                        .padding(.bottom, 2)
                    }
                }
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // 自訂分隔線，從文字左緣開始（cover 45pt + spacing 12pt = 57pt offset）
            HStack(spacing: 0) {
                Color.clear.frame(width: coverW + 12)
                Rectangle()
                    .fill(DSColor.textSecondary.opacity(0.15))
                    .frame(height: 0.5)
            }
        }
    }

    @ViewBuilder
    private var progressBadge: some View {
        if book.currentPosition < 0.01 {
            Text(gs.t("新增"))
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.blue)
                .clipShape(Capsule())
        } else if book.currentPosition >= 0.99 {
            Text(gs.t("已讀完"))
                .font(.system(size: 12))
                .foregroundColor(DSColor.textSecondary)
        } else {
            Text("\(Int(book.currentPosition * 100))%")
                .font(.system(size: 12))
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
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .shadow(color: .black.opacity(0.12), radius: 2, x: 0, y: 1)
        } else {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(
                        LinearGradient(
                            colors: coverGradient(for: book.title),
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: .black.opacity(0.12), radius: 2, x: 0, y: 1)
                Text(book.title)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(3)
                    .padding(5)
            }
            .frame(width: coverW, height: coverH)
        }
    }

    private func loadCoverImage(filename: String) -> UIImage? {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    private func coverGradient(for title: String) -> [Color] {
        let palettes: [[Color]] = [
            [Color(red: 0.30, green: 0.45, blue: 0.80), Color(red: 0.15, green: 0.25, blue: 0.55)],
            [Color(red: 0.70, green: 0.25, blue: 0.30), Color(red: 0.45, green: 0.10, blue: 0.18)],
            [Color(red: 0.20, green: 0.55, blue: 0.45), Color(red: 0.10, green: 0.35, blue: 0.28)],
            [Color(red: 0.65, green: 0.45, blue: 0.15), Color(red: 0.42, green: 0.28, blue: 0.05)],
            [Color(red: 0.45, green: 0.20, blue: 0.65), Color(red: 0.28, green: 0.10, blue: 0.45)],
        ]
        let idx = abs(title.hashValue) % palettes.count
        return palettes[idx]
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
