import SwiftUI
import UniformTypeIdentifiers

struct RSSListView: View {
    @StateObject private var store = RSSStore.shared
    @ObservedObject private var gs = GlobalSettings.shared

    @State private var showAddSheet = false
    @State private var showOPMLImporter = false
    @State private var showOPMLExporter = false
    @State private var showJSONImporter = false
    @State private var showJSONExporter = false
    @State private var showJSONURLSheet = false
    @State private var searchText = ""
    @State private var importMessage = ""
    @State private var showImportResult = false
    @State private var didBackfillSourceMetadata = false
    @State private var showSafari = false
    @State private var safariURL: URL?

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private var sortedSources: [RSSSource] {
        store.sources.sorted(by: { $0.sortOrder < $1.sortOrder })
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var searchResults: [RSSArticleRecord] {
        store.searchArticles(query: trimmedSearchText)
    }

    var body: some View {
        List {
            if !trimmedSearchText.isEmpty {
                Section(localized("搜尋結果")) {
                    if searchResults.isEmpty {
                        ContentUnavailableView(
                            localized("沒有搜尋結果"),
                            systemImage: "magnifyingglass"
                        )
                    } else {
                        ForEach(searchResults) { article in
                            NavigationLink(destination: RSSArticleReaderView(articleID: article.id)) {
                                RSSSearchResultRow(
                                    article: article,
                                    source: source(for: article.sourceId),
                                    dateFormatter: dateFormatter
                                )
                            }
                            .simultaneousGesture(TapGesture().onEnded {
                                store.markRead(articleId: article.id, isRead: true)
                            })
                        }
                    }
                }
            }

            if sortedSources.isEmpty && trimmedSearchText.isEmpty {
                ContentUnavailableView(
                    localized("沒有訂閱源"),
                    systemImage: "newspaper",
                    description: Text(localized("新增第一個 RSS 訂閱"))
                )
            }

            ForEach(sortedSources) { source in
                if source.isLegadoRuleBased {
                    Button {
                        if let url = URL(string: source.url) {
                            safariURL = url
                            showSafari = true
                        }
                    } label: {
                        RSSSourceRow(
                            source: source,
                            unreadCount: store.unreadCount(for: source.id),
                            lastFetchedAt: store.lastFetchedAt(for: source.id),
                            dateFormatter: dateFormatter
                        )
                    }
                    .buttonStyle(.plain)
                } else {
                    NavigationLink(destination: RSSFeedView(source: source)) {
                        RSSSourceRow(
                            source: source,
                            unreadCount: store.unreadCount(for: source.id),
                            lastFetchedAt: store.lastFetchedAt(for: source.id),
                            dateFormatter: dateFormatter
                        )
                    }
                }
            }
            .onDelete(perform: deleteSources)
        }
        .navigationTitle(localized("RSS 訂閱"))
        .searchable(text: $searchText, prompt: localized("搜尋 RSS"))
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        showAddSheet = true
                    } label: {
                        Label(localized("新增 RSS 訂閱"), systemImage: "plus")
                    }

                    Button {
                        showOPMLImporter = true
                    } label: {
                        Label(localized("匯入 OPML"), systemImage: "square.and.arrow.down")
                    }

                    Button {
                        showOPMLExporter = true
                    } label: {
                        Label(localized("匯出 OPML"), systemImage: "square.and.arrow.up")
                    }
                    .disabled(sortedSources.isEmpty)

                    Divider()

                    Button {
                        showJSONImporter = true
                    } label: {
                        Label(localized("匯入 Legado JSON"), systemImage: "doc.badge.plus")
                    }

                    Button {
                        showJSONURLSheet = true
                    } label: {
                        Label(localized("從網址匯入 Legado JSON"), systemImage: "link.badge.plus")
                    }

                    Button {
                        showJSONExporter = true
                    } label: {
                        Label(localized("匯出 Legado JSON"), systemImage: "doc.badge.arrow.up")
                    }
                    .disabled(sortedSources.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .foregroundColor(DSColor.accent)
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddRSSSourceSheet(isPresented: $showAddSheet, store: store, gs: gs)
        }
        .sheet(isPresented: $showJSONURLSheet) {
            ImportLegadoJSONURLSheet(isPresented: $showJSONURLSheet, store: store)
        }
        .fileImporter(
            isPresented: $showOPMLImporter,
            allowedContentTypes: [.xml, .data],
            allowsMultipleSelection: false,
            onCompletion: importOPML
        )
        .fileExporter(
            isPresented: $showOPMLExporter,
            document: RSSOPMLDocument(sources: sortedSources),
            contentType: .xml,
            defaultFilename: "yuedu-rss.opml"
        ) { _ in }
        .fileImporter(
            isPresented: $showJSONImporter,
            allowedContentTypes: [.json, .data],
            allowsMultipleSelection: false,
            onCompletion: importLegadoJSON
        )
        .fileExporter(
            isPresented: $showJSONExporter,
            document: RSSJSONDocument(sources: sortedSources),
            contentType: .json,
            defaultFilename: "yuedu-rss-legado.json"
        ) { _ in }
        .alert(localized("RSS 訂閱"), isPresented: $showImportResult) {
            Button(localized("確定"), role: .cancel) {}
        } message: {
            Text(importMessage)
        }
        .sheet(isPresented: $showSafari) {
            if let url = safariURL {
                SafariView(url: url)
                    .ignoresSafeArea()
            }
        }
        .task {
            await backfillMissingSourceMetadata()
        }
    }

    private func deleteSources(at offsets: IndexSet) {
        let ids = offsets.compactMap { index -> String? in
            guard sortedSources.indices.contains(index) else { return nil }
            return sortedSources[index].id
        }
        store.removeSources(ids: ids)
    }

    private func source(for id: String) -> RSSSource? {
        store.sources.first { $0.id == id }
    }

    @MainActor
    private func backfillMissingSourceMetadata() async {
        guard !didBackfillSourceMetadata else { return }
        didBackfillSourceMetadata = true

        let candidates = sortedSources.filter { source in
            !source.isLegadoRuleBased && (
                source.homepageURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false ||
                source.faviconURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            )
        }

        for source in candidates {
            let fetcher = RSSFetcher()
            await fetcher.fetchItems(from: source, metadata: store.feedMetadata(for: source.id))
            guard let response = fetcher.response else { continue }
            store.applyFeedResponse(response, for: source.id)
        }
    }

    private func importLegadoJSON(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let shouldStopAccessing = url.startAccessingSecurityScopedResource()
            defer {
                if shouldStopAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let data = try Data(contentsOf: url)
            let sources = try LegadoSourceJSONParser.parse(data: data)
            let addedCount = store.addSources(sources)
            importMessage = String(format: localized("已匯入 %d 個訂閱源"), addedCount)
            showImportResult = true
        } catch {
            importMessage = String(format: localized("Legado JSON 匯入失敗：%@"), error.localizedDescription)
            showImportResult = true
        }
    }

    private func importOPML(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let shouldStopAccessing = url.startAccessingSecurityScopedResource()
            defer {
                if shouldStopAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let data = try Data(contentsOf: url)
            let sources = try RSSOPMLParser.parse(data: data)
            let addedCount = store.addSources(sources)
            importMessage = String(format: localized("已匯入 %d 個訂閱源"), addedCount)
            showImportResult = true
        } catch {
            importMessage = String(format: localized("OPML 匯入失敗：%@"), error.localizedDescription)
            showImportResult = true
        }
    }
}

private struct RSSSearchResultRow: View {
    let article: RSSArticleRecord
    let source: RSSSource?
    let dateFormatter: DateFormatter

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let source {
                RSSFaviconView(source: source, size: 26)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(article.title)
                    .font(.headline)
                    .fontWeight(article.isRead ? .regular : .semibold)
                    .foregroundColor(DSColor.textPrimary)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 8) {
                    if let source {
                        Text(source.name)
                    }
                    if let pubDate = article.pubDate {
                        Text(dateFormatter.string(from: pubDate))
                    }
                }
                .font(.caption)
                .foregroundColor(DSColor.textSecondary)

                if !article.summary.isEmpty {
                    Text(article.summary)
                        .font(.subheadline)
                        .foregroundColor(DSColor.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

private struct RSSSourceRow: View {
    let source: RSSSource
    let unreadCount: Int
    let lastFetchedAt: Date?
    let dateFormatter: DateFormatter

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RSSFaviconView(source: source, size: 30)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(source.name)
                        .font(.headline)
                        .foregroundColor(DSColor.textPrimary)

                    if unreadCount > 0 {
                        Text("\(unreadCount) \(localized("未讀"))")
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(DSColor.accent, in: Capsule())
                    }
                }

                Text(source.url)
                    .font(.caption)
                    .foregroundColor(DSColor.textSecondary)
                    .lineLimit(1)

                Text(lastFetchedText)
                    .font(.caption2)
                    .foregroundColor(DSColor.textSecondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var lastFetchedText: String {
        guard let lastFetchedAt else {
            return localized("尚未更新")
        }
        return "\(localized("最後更新")) \(dateFormatter.string(from: lastFetchedAt))"
    }
}

// MARK: - JSON Document

struct RSSJSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .data] }
    static var writableContentTypes: [UTType] { [.json] }

    var data: Data

    init(sources: [RSSSource]) {
        data = (try? LegadoSourceJSONParser.export(sources: sources)) ?? Data()
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - Import Legado JSON URL Sheet

private struct ImportLegadoJSONURLSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject var store: RSSStore

    @State private var urlString = ""
    @State private var isLoading = false
    @State private var message = ""
    @State private var showMessage = false

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text(localized("Legado JSON 網址"))) {
                    TextField("https://.../sources/xxx.json", text: $urlString)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }

                if showMessage {
                    Section {
                        Text(message)
                            .foregroundColor(message.hasPrefix("❌") ? .red : DSColor.textPrimary)
                    }
                }
            }
            .navigationTitle(localized("從網址匯入 Legado JSON"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(localized("取消")) {
                        isPresented = false
                    }
                    .foregroundColor(DSColor.accent)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(localized("匯入")) {
                        Task { await importFromURL() }
                    }
                    .foregroundColor(DSColor.accent)
                    .disabled(urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
                }
            }
            .disabled(isLoading)
            .overlay {
                if isLoading {
                    ProgressView(localized("匯入中，請稍候…"))
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    @MainActor
    private func importFromURL() async {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else {
            message = "❌ \(localized("RSS URL 無效"))"
            showMessage = true
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let sources = try LegadoSourceJSONParser.parse(data: data)
            let addedCount = store.addSources(sources)
            message = "\(localized("成功匯入")) \(addedCount) \(localized("個訂閱源"))"
            showMessage = true
            isPresented = false
        } catch {
            message = "❌ \(String(format: localized("Legado JSON 匯入失敗：%@"), error.localizedDescription))"
            showMessage = true
        }
    }
}

// MARK: - Add Source Sheet

private struct AddRSSSourceSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject var store: RSSStore
    @ObservedObject var gs: GlobalSettings

    @State private var name = ""
    @State private var url = ""

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text(localized("來源名稱"))) {
                    TextField(localized("例如：科技新聞"), text: $name)
                }
                Section(header: Text(localized("RSS 網址"))) {
                    TextField("https://", text: $url)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
            }
            .navigationTitle(localized("新增 RSS 訂閱"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(localized("取消")) {
                        isPresented = false
                    }
                    .foregroundColor(DSColor.accent)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(localized("新增")) {
                        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmedName.isEmpty, !trimmedURL.isEmpty else { return }
                        let source = RSSSource(
                            name: trimmedName,
                            url: trimmedURL,
                            sortOrder: store.sources.count
                        )
                        store.addSource(source)
                        isPresented = false
                    }
                    .foregroundColor(DSColor.accent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        RSSListView()
    }
}
