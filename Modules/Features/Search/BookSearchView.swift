import SwiftUI

// MARK: - Book Search View

struct BookSearchView: View {
    var initialQuery: String = ""
    var showsCloseButton = false

    @EnvironmentObject var bookStore: BookStore
    @ObservedObject private var sourceStore = BookSourceStore.shared
    @StateObject private var aggregator = SearchAggregator()
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var selectedSourceId: UUID? = nil  // nil = all
    @State private var errorMsg: String? = nil
    @State private var submittedQuery = ""
    @ObservedObject private var gs = GlobalSettings.shared

    var enabledSources: [BookSource] { sourceStore.enabledSources }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var shouldShowEmptyResult: Bool {
        !submittedQuery.isEmpty && trimmedQuery == submittedQuery
    }

    var body: some View {
        AdaptiveContentContainer(maxWidth: DSLayout.readableExpandedWidth) {
            VStack(spacing: 0) {
                if enabledSources.count > 1 {
                    sourceSelector
                }

                Divider()

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
                    } else if shouldShowEmptyResult {
                        emptyResultView
                    } else {
                        hintView
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DSColor.background)
        }
        .background(DSColor.background.ignoresSafeArea())
        .navigationTitle(localized("搜索書籍"))
        .toolbarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: localized("輸入書名或作者"))
        .onSubmit(of: .search) { doSearch() }
        .onChange(of: query) { _, newValue in
            // Mirror the old clear button: emptying the field resets the search.
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                submittedQuery = ""
                aggregator.cancel()
            }
        }
        .toolbar {
            if showsCloseButton {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
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
        .onAppear {
            if !initialQuery.isEmpty && query.isEmpty {
                query = initialQuery
                doSearch()
            }
        }
    }

    // MARK: Progress Bar
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
                    if aggregator.progress.skipped > 0 {
                        Text(localized("暫跳") + " \(aggregator.progress.skipped)")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 2)
            }
        }
    }

    // MARK: Source Selector
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
                .lineLimit(1)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(selectedSourceId == id ? Color.blue : Color(UIColor.systemGray5))
                .foregroundColor(selectedSourceId == id ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Result List
    private var resultList: some View {
        List(aggregator.results) { book in
            NavigationLink {
                OnlineBookView(searchBook: book)
                    .environmentObject(bookStore)
            } label: {
                AggregatedResultRow(book: book)
            }
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        }
        .listStyle(.plain)
    }

    // MARK: Empty State
    private var emptyResultView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "magnifyingglass").font(.system(size: 48)).foregroundColor(
                Color.secondary.opacity(0.3))
            Text(localized("沒有找到") + "「\(submittedQuery)」").font(.headline)
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

    // MARK: Search Logic
    private func doSearch() {
        let q = trimmedQuery
        guard !q.isEmpty else { return }
        let sources =
            selectedSourceId == nil
            ? enabledSources
            : enabledSources.filter { $0.id == selectedSourceId }
        guard !sources.isEmpty else {
            errorMsg = localized("沒有可用的書源，請先啟用書源")
            return
        }

        submittedQuery = q
        aggregator.search(query: q, sources: sources)
    }
}

// MARK: - Aggregated Result Row

struct AggregatedResultRow: View {
    @ObservedObject var book: SearchBook
    @ObservedObject private var gs = GlobalSettings.shared

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // ── Cover ──
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

            // ── Info ──
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

            // ── Source Count Badge ──
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

// MARK: - Source Picker Sheet

struct SourcePickerSheet: View {
    @Environment(\.presentationMode) var dismiss
    let searchBook: SearchBook
    let onSelectOrigin: (BookOrigin) -> Void
    @ObservedObject private var gs = GlobalSettings.shared

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
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
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss.wrappedValue.dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
        }
    }
}

// MARK: - OnlineBook Identifiable (for sheet item)
extension OnlineBook: Hashable {
    static func == (lhs: OnlineBook, rhs: OnlineBook) -> Bool {
        lhs.id == rhs.id
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - SearchBook Identifiable (for sheet item)
extension SearchBook: Hashable {
    static func == (lhs: SearchBook, rhs: SearchBook) -> Bool {
        lhs.id == rhs.id
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
