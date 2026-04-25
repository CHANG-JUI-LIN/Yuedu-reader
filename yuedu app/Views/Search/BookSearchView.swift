import SwiftUI

// MARK: - 書籍搜索視圖

struct BookSearchView: View {
    @EnvironmentObject var bookStore: BookStore
    @ObservedObject private var sourceStore = BookSourceStore.shared
    @StateObject private var aggregator = SearchAggregator()
    @Environment(\.presentationMode) var dismiss

    @State private var query = ""
    @State private var selectedSourceId: UUID? = nil  // nil = 全部
    @State private var selectedBook: SearchBook? = nil
    @State private var openingOnlineBook: OnlineBook? = nil  // 用於打開書籍詳情
    @State private var errorMsg: String? = nil
    @FocusState private var searchFocused: Bool
    @ObservedObject private var gs = GlobalSettings.shared

    var enabledSources: [BookSource] { sourceStore.enabledSources }

    var body: some View {
        NavigationView {
            AdaptiveSheetContainer(maxWidth: 900) {
                VStack(spacing: 0) {
                    // 搜索欄
                    searchBar
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)

                    // 書源選擇
                    if enabledSources.count > 1 {
                        sourceSelector
                    }

                    Divider()

                    // 結果或提示
                    ZStack {
                        if !aggregator.results.isEmpty {
                            resultList
                                .overlay(alignment: .top) {
                                    if aggregator.isSearching {
                                        progressBar
                                    }
                                }
                        } else if aggregator.isSearching {
                            VStack(spacing: 12) {
                                Spacer()
                                ProgressView(localized("搜索中…"))
                                Spacer()
                            }
                        } else if !query.isEmpty {
                            emptyResultView
                        } else {
                            hintView
                        }
                    }
                }
            }
            .navigationTitle(localized("搜索書籍"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(localized("關閉")) { dismiss.wrappedValue.dismiss() }
                }
            }
            .sheet(item: $selectedBook) { book in
                AdaptiveSheetContainer(maxWidth: 760) {
                    SourcePickerSheet(
                        searchBook: book,
                        onSelectOrigin: { origin in
                            openOnlineBook(from: book, origin: origin)
                        })
                }
            }
            .sheet(item: $openingOnlineBook) { onlineBook in
                AdaptiveSheetContainer(maxWidth: 900) {
                    OnlineBookView(book: onlineBook)
                        .environmentObject(bookStore)
                }
            }
            .alert(
                localized("搜索失敗"),
                isPresented: Binding(get: { errorMsg != nil }, set: { if !$0 { errorMsg = nil } })
            ) {
                Button(localized("確認")) { errorMsg = nil }
            } message: {
                Text(errorMsg ?? "")
            }
        }
        .navigationViewStyle(.stack)
        .onAppear { searchFocused = true }
    }

    // MARK: 搜索欄
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            TextField(localized("輸入書名或作者"), text: $query)
                .focused($searchFocused)
                .submitLabel(.search)
                .onSubmit { doSearch() }
            if !query.isEmpty {
                Button {
                    query = ""
                    aggregator.cancel()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: 進度條
    private var progressBar: some View {
        VStack(spacing: 0) {
            ProgressView(value: aggregator.progress.fraction)
                .progressViewStyle(.linear)
                .tint(.blue)
                .frame(height: 2)

            if aggregator.progress.total > 0 {
                HStack {
                    Spacer()
                    Text("\(aggregator.progress.completed)/\(aggregator.progress.total)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    if aggregator.progress.timedOut > 0 {
                        Text(localized("超時") + " \(aggregator.progress.timedOut)")
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                    }
                    if aggregator.progress.failed > 0 {
                        Text(localized("失敗") + " \(aggregator.progress.failed)")
                            .font(.system(size: 10))
                            .foregroundColor(.red)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 2)
            }
        }
    }

    // MARK: 書源選擇器
    private var sourceSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                sourceChip(id: nil, name: localized("全部"))
                ForEach(enabledSources) { src in
                    sourceChip(id: src.id, name: src.bookSourceName)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Color(UIColor.systemBackground))
    }

    @ViewBuilder
    private func sourceChip(id: UUID?, name: String) -> some View {
        Button {
            selectedSourceId = id
        } label: {
            Text(name)
                .font(.caption)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(selectedSourceId == id ? Color.blue : Color(UIColor.systemGray5))
                .foregroundColor(selectedSourceId == id ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: 結果列表
    private var resultList: some View {
        List(aggregator.results) { book in
            Button {
                if book.origins.count == 1 {
                    // 只有一個來源，直接打開書籍詳情
                    openOnlineBook(from: book, origin: book.origins[0])
                } else {
                    // 多個來源，顯示來源選擇
                    selectedBook = book
                }
            } label: {
                AggregatedResultRow(book: book)
            }
            .buttonStyle(.plain)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        }
        .listStyle(.plain)
    }

    // MARK: 空狀態
    private var emptyResultView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "magnifyingglass").font(.system(size: 48)).foregroundColor(
                Color.secondary.opacity(0.3))
            Text(localized("沒有找到") + "「\(query)」").font(.headline)
            Text(localized("嘗試換個關鍵字，或切換書源")).font(.subheadline).foregroundColor(.secondary)
            Spacer()
        }
    }

    private var hintView: some View {
        VStack(spacing: 16) {
            Spacer()
            if enabledSources.isEmpty {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 48))
                    .foregroundColor(.orange)
                Text(localized("尚未設置書源")).font(.headline)
                Text(localized("請先在書源管理中新增並啟用書源")).font(.subheadline).foregroundColor(.secondary)
            } else {
                Image(systemName: "text.magnifyingglass").font(.system(size: 48)).foregroundColor(
                    Color.secondary.opacity(0.3))
                Text(localized("輸入書名或作者搜索")).font(.subheadline).foregroundColor(.secondary)
                Text(localized("已啟用") + " \(enabledSources.count) " + localized("個書源")).font(.caption)
                    .foregroundColor(
                        Color.secondary.opacity(0.7))
            }
            Spacer()
        }
    }

    // MARK: 搜索邏輯
    private func doSearch() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let sources =
            selectedSourceId == nil
            ? enabledSources
            : enabledSources.filter { $0.id == selectedSourceId }
        guard !sources.isEmpty else {
            errorMsg = localized("沒有可用的書源，請先啟用書源")
            return
        }

        aggregator.search(query: q, sources: sources)
    }

    // MARK: 打開書籍詳情
    private func openOnlineBook(from book: SearchBook, origin: BookOrigin) {
        let onlineBook = OnlineBook(
            name: book.name,
            author: book.author,
            intro: origin.intro.isEmpty ? book.intro : origin.intro,
            coverUrl: origin.coverUrl.isEmpty ? book.coverUrl : origin.coverUrl,
            bookUrl: origin.bookUrl,
            tocUrl: origin.tocUrl,
            wordCount: origin.wordCount,
            lastChapter: origin.lastChapter,
            kind: origin.kind,
            sourceId: origin.sourceId,
            sourceName: origin.sourceName
        )
        // 先關閉 SourcePickerSheet（如果有打開的話），再打開書籍詳情
        selectedBook = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            openingOnlineBook = onlineBook
        }
    }
}

// MARK: - 聚合搜索結果行

struct AggregatedResultRow: View {
    @ObservedObject var book: SearchBook
    @ObservedObject private var gs = GlobalSettings.shared

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // ── 封面 ──
            AsyncImage(url: URL(string: book.coverUrl)) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                        .frame(width: 72, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .shadow(color: .black.opacity(0.12), radius: 3, x: 0, y: 1)
                default:
                    placeholderCover
                }
            }
            .frame(width: 72, height: 96)

            // ── 資訊區 ──
            VStack(alignment: .leading, spacing: 3) {
                Text(book.displayName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                if !book.author.isEmpty {
                    Text(book.author)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }

                if !book.intro.isEmpty {
                    let introForList = book.displayIntro
                    if !introForList.isEmpty {
                        Text(introForList)
                            .font(.system(size: 12))
                            .foregroundColor(Color.secondary.opacity(0.8))
                            .lineLimit(2)
                            .padding(.top, 2)
                    }
                }

                Spacer(minLength: 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // ── 來源數量標籤 ──
            VStack(alignment: .trailing) {
                HStack(spacing: 3) {
                    Image(systemName: "globe").font(.system(size: 9))
                    Text("\(book.origins.count) " + localized("源"))
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundColor(book.origins.count > 1 ? .white : .secondary)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(
                    book.origins.count > 1
                        ? AnyShapeStyle(Color.blue.opacity(0.85))
                        : AnyShapeStyle(Color(UIColor.systemGray5))
                )
                .clipShape(Capsule())
                Spacer()
            }
        }
        .padding(.vertical, 10)
        .frame(minHeight: 96)
    }

    private var placeholderCover: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color(UIColor.systemGray6))
            .frame(width: 72, height: 96)
            .overlay(
                Text(book.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(6)
            )
    }
}

// MARK: - 來源選擇 Sheet

struct SourcePickerSheet: View {
    @Environment(\.presentationMode) var dismiss
    let searchBook: SearchBook
    let onSelectOrigin: (BookOrigin) -> Void
    @ObservedObject private var gs = GlobalSettings.shared

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 書籍基本資訊
                HStack(alignment: .top, spacing: 12) {
                    AsyncImage(url: URL(string: searchBook.coverUrl)) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().scaledToFill()
                                .frame(width: 60, height: 80)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        default:
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.secondary.opacity(0.2))
                                .frame(width: 60, height: 80)
                                .overlay(
                                    Text(String(searchBook.displayName.prefix(1)))
                                        .font(.title2).foregroundColor(.secondary))
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(searchBook.displayName).font(.headline)
                        Text(searchBook.author).font(.subheadline).foregroundColor(.secondary)
                        if !searchBook.intro.isEmpty {
                            Text(searchBook.intro).font(.caption).foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer()
                }
                .padding()

                Divider()

                // 來源列表
                List(searchBook.origins) { origin in
                    Button {
                        dismiss.wrappedValue.dismiss()
                        onSelectOrigin(origin)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(origin.sourceName)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundColor(.primary)
                                if !origin.lastChapter.isEmpty {
                                    Text(origin.lastChapter)
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13))
                                .foregroundColor(Color.secondary.opacity(0.5))
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
            .navigationTitle(localized("選擇來源") + "（\(searchBook.origins.count) " + localized("個") + "）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(localized("關閉")) { dismiss.wrappedValue.dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - OnlineBook Identifiable (用於 sheet item)
extension OnlineBook: Hashable {
    static func == (lhs: OnlineBook, rhs: OnlineBook) -> Bool {
        lhs.id == rhs.id
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - SearchBook Identifiable (用於 sheet item)
extension SearchBook: Hashable {
    static func == (lhs: SearchBook, rhs: SearchBook) -> Bool {
        lhs.id == rhs.id
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
