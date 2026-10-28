import SwiftUI

/// 全書搜尋's sheet: the searches made in this book, the search running now, and its hits
/// by chapter. The search itself belongs to `ReaderBookSearchSession`, which the reader keeps,
/// so the last results are still here when the sheet opens again.
struct ReaderBookSearchView: View {
    @Bindable var session: ReaderBookSearchSession
    /// The selection's words when 搜尋 came from the text menu; searched as soon as it opens.
    let initialQuery: String
    /// Whether 替換規則 change this book's text, so turning them off can find anything.
    let offersReplaceRules: Bool
    let onSearch: (String) -> Void
    /// The sheet opened without words of its own: the reader refreshes stale results.
    let onReopen: () -> Void
    let onSelect: (Int) -> Void
    let onClose: () -> Void

    @State private var query: String
    @AppStorage private var history: RecentSearchQueries

    init(
        session: ReaderBookSearchSession,
        historyKey: String,
        initialQuery: String = "",
        offersReplaceRules: Bool,
        onSearch: @escaping (String) -> Void,
        onReopen: @escaping () -> Void,
        onSelect: @escaping (Int) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.session = session
        self.initialQuery = initialQuery
        self.offersReplaceRules = offersReplaceRules
        self.onSearch = onSearch
        self.onReopen = onReopen
        self.onSelect = onSelect
        self.onClose = onClose
        _query = State(initialValue: initialQuery.isEmpty ? session.query : initialQuery)
        _history = AppStorage(wrappedValue: RecentSearchQueries(), historyKey)
    }

    var body: some View {
        NavigationStack {
            content
                .background(PageBackgroundView(scope: .settings).ignoresSafeArea())
                .pageBackgroundToolbar(for: .settings)
                .navigationTitle(localized("搜尋書籍"))
                .toolbarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
        }
        .searchable(text: $query, prompt: Text(localized("Search Book")))
        .onSubmit(of: .search) { submit(query) }
        .onChange(of: query) { _, newValue in
            // The field's own clear button: back to the recent searches.
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { session.clear() }
        }
        .onChange(of: session.options) {
            guard !session.query.isEmpty else { return }
            onSearch(session.query)
        }
        .task {
            if initialQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                onReopen()
            } else {
                submit(initialQuery)
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if session.query.isEmpty {
            recentSearches
        } else {
            switch session.phase {
            case .failed(let error):
                failure(error)
            case .finished where session.hits.isEmpty:
                ContentUnavailableView {
                    UnavailableLabel(localized("無搜尋結果"), systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text(noResultsDescription).foregroundStyle(DSColor.textSecondary)
                }
            case .idle, .searching, .finished:
                results
            }
        }
    }

    @ViewBuilder
    private var recentSearches: some View {
        if history.queries.isEmpty {
            ContentUnavailableView {
                UnavailableLabel(localized("搜尋書籍"), systemImage: "magnifyingglass")
            } description: {
                Text(localized("輸入關鍵字搜尋整本書。")).foregroundStyle(DSColor.textSecondary)
            }
        } else {
            List {
                Section {
                    ForEach(history.queries, id: \.self) { recent in
                        Button {
                            query = recent
                            submit(recent)
                        } label: {
                            Label(recent, systemImage: "clock.arrow.circlepath")
                                .foregroundStyle(DSColor.textPrimary)
                        }
                        .interfaceSectionSurface()
                    }
                    .onDelete { history = history.removing(atOffsets: $0) }
                } header: {
                    HStack {
                        Text(localized("最近搜索"))
                        Spacer()
                        Button(localized("清除")) { history = RecentSearchQueries() }
                            .font(DSFont.footnote)
                    }
                }
            }
            .softScrollEdges()
            .listStyle(.insetGrouped)
            // Hiding the list background alone leaves each row painting its own
            // opaque system fill over the `PageBackgroundView` below. docs/design.md §4.1.
            .scrollContentBackground(.hidden)
        }
    }

    private var results: some View {
        List {
            Section {
                status
                    .interfaceSectionSurface()
            } footer: {
                if let note = resultsNote {
                    Text(note).dsSectionFooter()
                }
            }
            ForEach(session.sections) { section in
                Section {
                    ForEach(section.rows) { row in
                        hitRow(row.hit, index: row.index)
                    }
                } header: {
                    Text(section.title)
                }
            }
        }
        .softScrollEdges()
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private var status: some View {
        if session.phase == .searching {
            ProgressView(
                value: Double(session.searchedChapterCount),
                total: Double(max(session.totalChapterCount, 1))
            ) {
                Text(localized("正在搜尋…"))
                    .font(DSFont.subheadline)
                    .foregroundStyle(DSColor.textPrimary)
            } currentValueLabel: {
                Text(String(format: localized("已搜尋 %d／%d 章"),
                            session.searchedChapterCount, session.totalChapterCount))
                    .font(DSFont.caption)
                    .foregroundStyle(DSColor.textSecondary)
                    .monospacedDigit()
            }
        } else {
            Text(String(format: localized("共 %d 個結果"), session.hits.count))
                .font(DSFont.subheadline)
                .foregroundStyle(DSColor.textPrimary)
                .monospacedDigit()
        }
    }

    private func hitRow(_ hit: ReaderBookSearchHit, index: Int) -> some View {
        Button {
            onSelect(index)
        } label: {
            Text(attributedSnippet(hit.snippet))
                .font(DSFont.subheadline)
                .foregroundStyle(DSColor.textPrimary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .interfaceSectionSurface()
    }

    private func failure(_ error: ReaderBookSearchError) -> some View {
        let title: String, message: String
        switch error {
        case .invalidPattern:
            title = localized("正規表示式有誤")
            message = localized("檢查表示式的寫法後再試一次。")
        case .timedOut:
            title = localized("搜尋已停止")
            message = localized("這個正規表示式運算太久，換個寫法再試一次。")
        case .unsupported:
            title = localized("無法搜尋")
            message = localized("這本書沒有可以搜尋的文字。")
        }
        return ContentUnavailableView {
            UnavailableLabel(title, systemImage: "exclamationmark.magnifyingglass")
        } description: {
            Text(message).foregroundStyle(DSColor.textSecondary)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .accessibilityLabel(localized("關閉"))
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if session.phase == .searching {
                Button(localized("停止")) { session.stop() }
            }
            Menu {
                Toggle(localized("正則表達式"), isOn: $session.options.isRegex)
                if offersReplaceRules {
                    Toggle(localized("套用替換規則"), isOn: $session.options.appliesReplaceRules)
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
            }
            .accessibilityLabel(localized("搜尋選項"))
        }
    }

    // MARK: - Text

    private var unsearchedNote: String? {
        let count = session.notDownloadedChapterCount
        return count > 0 ? String(format: localized("有 %d 章尚未下載，未搜尋。"), count) : nil
    }

    /// What the count leaves out: chapters not on the device, and hits past the limit.
    private var resultsNote: String? {
        var parts: [String] = []
        if let unsearchedNote { parts.append(unsearchedNote) }
        if session.reachedHitLimit {
            parts.append(String(format: localized("只列出前 %d 個結果。"), ReaderBookSearchSession.hitLimit))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private var noResultsDescription: String {
        [localized("換個關鍵字再試一次。"), unsearchedNote].compactMap { $0 }.joined(separator: "\n")
    }

    private func attributedSnippet(_ snippet: ReaderBookSearchSnippet) -> AttributedString {
        var text = AttributedString((snippet.continuesBefore ? "…" : "") + snippet.leading)
        var match = AttributedString(snippet.match)
        match.font = DSFont.subheadline.weight(.semibold)
        match.foregroundColor = DSColor.accent
        text.append(match)
        text.append(AttributedString(snippet.trailing + (snippet.continuesAfter ? "…" : "")))
        return text
    }

    private func submit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        history = history.recording(trimmed)
        onSearch(trimmed)
    }
}

#Preview {
    ReaderBookSearchView(
        session: ReaderBookSearchSession(),
        historyKey: "preview_reader_search_history",
        offersReplaceRules: true,
        onSearch: { _ in },
        onReopen: {},
        onSelect: { _ in },
        onClose: {}
    )
}

#Preview("Results") {
    let session = ReaderBookSearchSession()
    let chapters = ["風起了，風停了，天色漸暗。", "沒有那個字。", "又起風了，吹過山崗。"]
    return ReaderBookSearchView(
        session: session,
        historyKey: "preview_reader_search_history",
        initialQuery: "風",
        offersReplaceRules: false,
        onSearch: { query in
            session.search(
                query,
                chapterTitles: ["第一章", "第二章", "第三章"],
                signature: .init(source: ReaderAISourceIdentity(bookID: UUID(), sourceID: nil, source: "preview", chapters: []),
                                 conversion: .original, rulesRevision: 0)
            ) { index, _ in .init(text: chapters[index], status: .available) }
        },
        onReopen: {},
        onSelect: { _ in },
        onClose: {}
    )
}
