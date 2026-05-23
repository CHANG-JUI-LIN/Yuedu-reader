import SwiftUI
import UniformTypeIdentifiers

// MARK: - Bookshelf Home
struct HomeView: View {
    @EnvironmentObject var store: BookStore

    @State private var showAddSheet = false
    @State private var addSheetSessionID = UUID()
    @State private var editingBook: ReadingBook? = nil
    @State private var bookToDelete: ReadingBook? = nil
    @State private var editMode = EditMode.inactive
    @State private var showSearch = false
    @State private var selectedGroup: String = ""
    @State private var selectedBookIds: Set<UUID> = []
    @State private var showBulkDeleteAlert = false
    @State private var showAddToGroupSheet = false
    @AppStorage("bookLayoutIsGrid") private var isGridMode = false
    @AppStorage("bookSortOrder") private var sortOrder = BookSortOrder.manual.rawValue
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Namespace private var bookTransition

    private var hInset: CGFloat { sizeClass == .regular ? 32 : 20 }

    @State private var readerBookId: UUID? = nil

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

    var body: some View {
        NavigationStack {
            AdaptiveContentContainer(maxWidth: 920) {
                Group {
                    if store.books.isEmpty {
                        EmptyLibraryView(showAdd: $showAddSheet, showSearch: $showSearch)
                            .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    } else {
                        VStack(spacing: 0) {
                            if !store.allGroups.isEmpty {
                                groupFilterBar
                            }
                            if isGridMode { bookGrid } else { bookList }
                            if editMode == .active {
                                editActionBar
                            }
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    }
                }
            }
            .animation(DSAnimation.standard, value: store.books.isEmpty)
            .navigationTitle(localized("書架"))
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {

                ToolbarItem(placement: .navigationBarTrailing) {
                    Group {
                        if editMode == .active {
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
                        } else {
                            Button { showSearch = true } label: {
                                Image(systemName: "magnifyingglass")
                                    .font(DSFont.toolbarIcon)
                                    .foregroundColor(.black)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.clear)
                        }
                    }
                }

                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    if editMode == .active {
                        Button {
                            withAnimation {
                                editMode = .inactive
                                selectedBookIds = []
                            }
                        } label: {
                            Image(systemName: "checkmark")
                                .font(DSFont.toolbarIcon)
                        }
                    } else {
                        Button {
                            addSheetSessionID = UUID()
                            showAddSheet = true
                        } label: {
                            Image(systemName: "plus")
                                .font(DSFont.toolbarIcon)
                        }
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
                            Image(systemName: "ellipsis.circle")
                                .font(DSFont.toolbarIcon)
                        }
                        .id("\(Locale.autoupdatingCurrent.identifier)_menu")
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
            .onChange(of: showAddSheet) { _, isPresented in
                if isPresented {
                    addSheetSessionID = UUID()
                }
            }
            .sheet(isPresented: $showSearch) {
                AdaptiveSheetContainer(maxWidth: 900) {
                    BookSearchView().environmentObject(store)
                }
            }
            .sheet(item: $editingBook) { book in
                AdaptiveSheetContainer(maxWidth: 640) {
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
                AdaptiveSheetContainer(maxWidth: 480) {
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
        }
        .fullScreenCover(
            isPresented: Binding(
                get: { readerBookId != nil },
                set: { if !$0 { readerBookId = nil } }
            )
        ) {
            if let bookId = readerBookId {
                ReaderView(bookId: bookId)
                    .environmentObject(store)
            }
        }
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

    // MARK: - Edit Mode Action Bar
    private var editActionBar: some View {
        HStack {
            Button {
                if !selectedBookIds.isEmpty { showBulkDeleteAlert = true }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 20))
                    .foregroundColor(selectedBookIds.isEmpty ? DSColor.textSecondary : .red)
                    .frame(width: 44, height: 44)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(Circle())
            }
            .disabled(selectedBookIds.isEmpty)

            Spacer()

            Button {
                if !selectedBookIds.isEmpty { showAddToGroupSheet = true }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle")
                    Text(localized("加入分組"))
                }
                .font(DSFont.subheadline.weight(.medium))
                .foregroundColor(selectedBookIds.isEmpty ? DSColor.textSecondary : .primary)
                .padding(.horizontal, 18).padding(.vertical, 10)
                .background(Color(.secondarySystemBackground))
                .clipShape(Capsule())
            }
            .disabled(selectedBookIds.isEmpty)

            Spacer()

            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, hInset)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    // MARK: - Book List
    private var bookList: some View {
        List {
            ForEach(sortedFilteredBooks) { book in
                BookRow(
                    book: book,
                    isEditing: editMode == .active,
                    isSelected: selectedBookIds.contains(book.id),
                    transitionNamespace: bookTransition,
                    onTap: {
                        if editMode == .active {
                            if selectedBookIds.contains(book.id) {
                                selectedBookIds.remove(book.id)
                            } else {
                                selectedBookIds.insert(book.id)
                            }
                        } else {
                            store.updateLastOpened(bookId: book.id)
                            readerBookId = book.id
                        }
                    },
                    onEdit: { editingBook = book },
                    onDelete: { bookToDelete = book }
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
    }

    // MARK: - Book Grid
    private var bookGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 100, maximum: 160), spacing: 10)],
                spacing: 12
            ) {
                ForEach(sortedFilteredBooks) { book in
                    BookGridCell(
                        book: book,
                        transitionNamespace: bookTransition,
                        onOpen: {
                            store.updateLastOpened(bookId: book.id)
                            readerBookId = book.id
                        },
                        onEdit: { editingBook = book },
                        onDelete: { bookToDelete = book }
                    )
                }
            }
            .padding(.horizontal, hInset)
            .padding(.vertical, 12)
        }
        .animation(.easeOut(duration: 0.25), value: sortedFilteredBooks.map(\.id))
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
        NavigationView {
            AdaptiveSheetContainer(maxWidth: 640) {
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
                                            .font(.caption)
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
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button(localized("取消")) { dismiss.wrappedValue.dismiss() }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            onSave(titleInput, authorInput, groupInput)
                            dismiss.wrappedValue.dismiss()
                        } label: {
                            Text(localized("儲存")).font(.body.weight(.semibold))
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
    @Binding var showSearch: Bool
    @State private var appeared = false
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "books.vertical")
                .font(.system(size: 72))
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
            Button {
                showSearch = true
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
    var isSelected: Bool = false
    var transitionNamespace: Namespace.ID? = nil
    let onTap: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    private let coverW: CGFloat = 45
    private let coverH: CGFloat = 65

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onTap) {
                HStack(alignment: .top, spacing: 12) {
                    if isEditing {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 22))
                            .foregroundColor(isSelected ? DSColor.accent : DSColor.textSecondary.opacity(0.5))
                            .padding(.top, (coverH - 22) / 2)
                    }

                    Group {
                        if let ns = transitionNamespace {
                            bookCover.matchedTransitionSource(id: book.id, in: ns)
                        } else {
                            bookCover
                        }
                    }

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

                    if !isEditing {
                        VStack {
                            Spacer(minLength: 0)
                            HStack(spacing: 18) {
                                Image(systemName: "cloud")
                                    .font(.system(size: 16))
                                    .foregroundColor(DSColor.textSecondary)

                                Menu {
                                    Button { onEdit() } label: {
                                        Label(localized("編輯書籍資訊"), systemImage: "pencil")
                                    }
                                    Button(role: .destructive) { onDelete() } label: {
                                        Label(localized("刪除書籍"), systemImage: "trash")
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
                }
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Rectangle()
                .fill(Color(uiColor: .separator))
                .frame(height: 0.5)
        }
    }

    @ViewBuilder
    private var progressBadge: some View {
        if book.currentPosition < 0.01 {
            Text(localized("新增"))
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.blue)
                .clipShape(Capsule())
        } else if book.currentPosition >= 0.99 {
            Text(localized("已讀完"))
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
                .shadow(color: .black.opacity(0.08), radius: 15, x: 0, y: 10)
        } else {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(.secondarySystemBackground))
                    .shadow(color: .black.opacity(0.08), radius: 15, x: 0, y: 10)
                Text(book.title)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(DSColor.textSecondary)
                    .lineLimit(4)
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

}

// MARK: - Book Grid Cell
struct BookGridCell: View {
    let book: ReadingBook
    var transitionNamespace: Namespace.ID? = nil
    let onOpen: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onOpen) {
                ZStack(alignment: .topTrailing) {
                    Group {
                        if let ns = transitionNamespace {
                            coverView.matchedTransitionSource(id: book.id, in: ns)
                        } else {
                            coverView
                        }
                    }
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
                        Label(localized("編輯書籍資訊"), systemImage: "pencil")
                    }
                    Button(role: .destructive) { onDelete() } label: {
                        Label(localized("刪除書籍"), systemImage: "trash")
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

// MARK: - Bulk Add to Group Sheet
struct BulkAddToGroupSheet: View {
    let bookCount: Int
    let onConfirm: (String) -> Void

    @EnvironmentObject private var store: BookStore
    @Environment(\.presentationMode) private var dismiss
    @State private var groupInput: String = ""

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text(localized("分組名稱"))) {
                    TextField(localized("輸入分組名稱（留空＝未分組）"), text: $groupInput)
                    if !store.allGroups.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(store.allGroups, id: \.self) { g in
                                    Button(g) { groupInput = g }
                                        .font(.caption)
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
                        .font(.footnote)
                        .foregroundColor(DSColor.textSecondary)
                }
            }
            .navigationTitle(localized("加入分組"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(localized("取消")) { dismiss.wrappedValue.dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        onConfirm(groupInput)
                        dismiss.wrappedValue.dismiss()
                    } label: {
                        Text(localized("確定")).font(.body.weight(.semibold))
                    }
                }
            }
        }
    }
}
