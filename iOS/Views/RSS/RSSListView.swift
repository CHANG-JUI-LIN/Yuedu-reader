import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct RSSListView: View {
    @StateObject private var store = RSSStore.shared
    @ObservedObject private var gs = GlobalSettings.shared

    @AppStorage("rss_main_feed_hide_read_feeds") private var hideReadFeeds = false
    @AppStorage("rss_main_feed_smart_feeds_expanded") private var smartFeedsExpanded = true
    @AppStorage("rss_main_feed_local_expanded") private var localFeedsExpanded = true

    @State private var expandedFolderIDs: Set<String> = []
    @State private var didSeedExpandedFolders = false
    @State private var showAddSheet = false
    @State private var showAddFolderSheet = false
    @State private var showOPMLImporter = false
    @State private var showOPMLExporter = false
    @State private var showJSONImporter = false
    @State private var showJSONExporter = false
    @State private var showJSONURLSheet = false
    @State private var searchText = ""
    @State private var importMessage = ""
    @State private var showImportResult = false
    @State private var didBackfillSourceMetadata = false
    @State private var safariURL: URL?
    @State private var sourceToRename: RSSSource?
    @State private var folderToRename: RSSFolder?
    @State private var sourceForInfo: RSSSource?
    @State private var deleteTarget: RSSDeleteTarget?
    @State private var isRefreshingAll = false
    @State private var refreshProgress = RSSRefreshProgress()

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private var folders: [RSSFolder] {
        store.orderedFolders()
    }

    private var visibleFolders: [RSSFolder] {
        folders.filter { folder in
            !hideReadFeeds || store.unreadCount(for: folder) > 0
        }
    }

    private var rootSources: [RSSSource] {
        visibleSources(store.rootSources())
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var searchResults: [RSSArticleRecord] {
        store.searchArticles(query: trimmedSearchText)
    }

    var body: some View {
        NavigationStack {
            List {
                if !trimmedSearchText.isEmpty {
                    searchSection
                }
                else {
                    smartFeedsSection
                    localFeedsSection
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(localized("RSS 訂閱"))
            .searchable(text: $searchText, prompt: localized("搜尋訂閱與文章"))
            .refreshable {
                await refreshAllSources()
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        hideReadFeeds.toggle()
                    } label: {
                        Image(systemName: hideReadFeeds ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                            .font(DSFont.toolbarIcon)
                    }
                    .tint(hideReadFeeds ? DSColor.accent : DSColor.textPrimary)
                    .accessibilityLabel(hideReadFeeds ? localized("顯示已讀訂閱") : localized("隱藏已讀訂閱"))
                }

                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            showAddSheet = true
                        } label: {
                            Label(localized("新增 RSS 訂閱"), systemImage: "plus")
                        }

                        Button {
                            showAddFolderSheet = true
                        } label: {
                            Label(localized("新增資料夾"), systemImage: "folder.badge.plus")
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(DSFont.toolbarIcon)
                    }
                    .tint(DSColor.accent)

                    Menu {
                        Button {
                            Task { await refreshAllSources() }
                        } label: {
                            Label(localized("刷新訂閱"), systemImage: "arrow.clockwise")
                        }
                        .disabled(isRefreshingAll || store.sources.isEmpty)

                        Button {
                            store.markAllRead()
                        } label: {
                            Label(localized("標記全部已讀"), systemImage: "checkmark.circle")
                        }
                        .disabled(store.totalUnreadCount() == 0)

                        Divider()

                        Button {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                showOPMLImporter = true
                            }
                        } label: {
                            Label(localized("匯入 OPML"), systemImage: "square.and.arrow.down")
                        }

                        Button {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                showOPMLExporter = true
                            }
                        } label: {
                            Label(localized("匯出 OPML"), systemImage: "square.and.arrow.up")
                        }
                        .disabled(store.sources.isEmpty)

                        Divider()

                        Button {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                showJSONImporter = true
                            }
                        } label: {
                            Label(localized("匯入 Legado JSON"), systemImage: "doc.badge.plus")
                        }

                        Button {
                            showJSONURLSheet = true
                        } label: {
                            Label(localized("從網址匯入 Legado JSON"), systemImage: "link.badge.plus")
                        }

                        Button {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                showJSONExporter = true
                            }
                        } label: {
                            Label(localized("匯出 Legado JSON"), systemImage: "doc.badge.arrow.up")
                        }
                        .disabled(store.sources.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(DSFont.toolbarIcon)
                    }
                    .tint(DSColor.accent)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if isRefreshingAll {
                    RSSRefreshProgressBar(progress: refreshProgress)
                }
            }
            .sheet(isPresented: $showAddSheet) {
                AddRSSSourceSheet(
                    isPresented: $showAddSheet,
                    store: store,
                    gs: gs,
                    folders: folders
                )
            }
            .sheet(isPresented: $showAddFolderSheet) {
                AddRSSFolderSheet(isPresented: $showAddFolderSheet, store: store)
            }
            .sheet(isPresented: $showJSONURLSheet) {
                ImportLegadoJSONURLSheet(isPresented: $showJSONURLSheet, store: store)
            }
            .sheet(item: $safariURL) { url in
                SafariView(url: url)
                    .ignoresSafeArea()
            }
            .sheet(item: $sourceToRename) { source in
                RenameRSSSourceSheet(source: source, store: store)
            }
            .sheet(item: $folderToRename) { folder in
                RenameRSSFolderSheet(folder: folder, store: store)
            }
            .sheet(item: $sourceForInfo) { source in
                RSSSourceInfoSheet(source: source, store: store)
            }
            .fileImporter(
                isPresented: $showOPMLImporter,
                allowedContentTypes: [UTType(tag: "opml", tagClass: .filenameExtension, conformingTo: .xml), .xml, .data].compactMap { $0 },
                allowsMultipleSelection: false,
                onCompletion: importOPML
            )
            .fileExporter(
                isPresented: $showOPMLExporter,
                document: RSSOPMLDocument(sources: store.sources.sorted(by: { $0.sortOrder < $1.sortOrder })),
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
                document: RSSJSONDocument(sources: store.sources.sorted(by: { $0.sortOrder < $1.sortOrder })),
                contentType: .json,
                defaultFilename: "yuedu-rss-legado.json"
            ) { _ in }
            .alert(localized("RSS 訂閱"), isPresented: $showImportResult) {
                Button(localized("確定"), role: .cancel) {}
            } message: {
                Text(importMessage)
            }
            .alert(
                deleteTarget?.title ?? localized("刪除"),
                isPresented: Binding(
                    get: { deleteTarget != nil },
                    set: { if !$0 { deleteTarget = nil } }
                ),
                presenting: deleteTarget
            ) { target in
                Button(localized("刪除"), role: .destructive) {
                    performDelete(target)
                }
                Button(localized("取消"), role: .cancel) {}
            } message: { target in
                Text(target.message)
            }
            .task {
                seedExpandedFoldersIfNeeded()
                await backfillMissingSourceMetadata()
            }
            .onChange(of: store.folders) { _, _ in
                seedExpandedFoldersIfNeeded()
            }
        }
    }

    private var searchSection: some View {
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

    private var smartFeedsSection: some View {
        Section {
            if smartFeedsExpanded {
                ForEach(RSSSmartFeedKind.allCases) { smartFeed in
                    NavigationLink(destination: RSSSmartFeedView(kind: smartFeed)) {
                        RSSMainFeedRow(
                            title: smartFeed.title,
                            unreadCount: store.unreadCount(for: smartFeed),
                            icon: .system(smartFeed.systemImage, tint: smartFeed.tintColor)
                        )
                    }
                    .contextMenu {
                        if store.unreadCount(for: smartFeed) > 0 {
                            Button {
                                store.markAllRead(smartFeed: smartFeed)
                            } label: {
                                Label(localized("標記全部已讀"), systemImage: "checkmark.circle")
                            }
                        }
                    }
                }
            }
        } header: {
            RSSMainFeedSectionHeader(
                title: localized("智慧訂閱"),
                unreadCount: 0,
                isExpanded: $smartFeedsExpanded
            )
        }
    }

    private var localFeedsSection: some View {
        Section {
            if localFeedsExpanded {
                if hideReadFeeds && visibleFolders.isEmpty && rootSources.isEmpty && !store.sources.isEmpty {
                    Text(localized("沒有未讀訂閱"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                }

                ForEach(visibleFolders) { folder in
                    folderRow(folder)

                    if expandedFolderIDs.contains(folder.id) {
                        ForEach(visibleSources(store.sources(in: folder))) { source in
                            sourceRow(source, indent: 16)
                        }
                        .onMove { offsets, destination in
                            store.moveSources(inFolderNamed: folder.name, fromOffsets: offsets, toOffset: destination)
                        }
                    }
                }

                ForEach(rootSources) { source in
                    sourceRow(source, indent: 0)
                }
                .onMove { offsets, destination in
                    store.moveSources(inFolderNamed: nil, fromOffsets: offsets, toOffset: destination)
                }
            }
        } header: {
            RSSMainFeedSectionHeader(
                title: localized("本機"),
                unreadCount: store.totalUnreadCount(),
                isExpanded: $localFeedsExpanded
            )
        }
    }

    private func folderRow(_ folder: RSSFolder) -> some View {
        let isExpanded = expandedFolderIDs.contains(folder.id)
        let unreadCount = store.unreadCount(for: folder)

        return Button {
            toggleFolder(folder)
        } label: {
            RSSMainFeedFolderRow(
                title: folder.name,
                unreadCount: unreadCount,
                isExpanded: isExpanded
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            if unreadCount > 0 {
                Button {
                    store.markAllRead(in: folder)
                } label: {
                    Label(localized("標記全部已讀"), systemImage: "checkmark.circle")
                }
            }

            Button {
                folderToRename = folder
            } label: {
                Label(localized("重新命名"), systemImage: "pencil")
            }

            Button(role: .destructive) {
                deleteTarget = .folder(folder)
            } label: {
                Label(localized("刪除"), systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                deleteTarget = .folder(folder)
            } label: {
                Label(localized("刪除"), systemImage: "trash")
            }

            Button {
                folderToRename = folder
            } label: {
                Label(localized("重新命名"), systemImage: "pencil")
            }
            .tint(.orange)
        }
    }

    private func sourceRow(_ source: RSSSource, indent: CGFloat) -> some View {
        NavigationLink(destination: RSSFeedView(source: source)) {
            RSSMainFeedRow(
                title: source.name,
                unreadCount: store.unreadCount(for: source.id),
                icon: .source(source),
                indent: indent
            )
        }
        .contextMenu {
            Button {
                sourceForInfo = source
            } label: {
                Label(localized("取得資訊"), systemImage: "info.circle")
            }

            if let homepageURL = source.homepageURL, URL(string: homepageURL) != nil {
                Button {
                    openURLString(homepageURL)
                } label: {
                    Label(localized("開啟首頁"), systemImage: "safari")
                }
            }

            Button {
                copyURLString(source.url)
            } label: {
                Label(localized("複製訂閱 URL"), systemImage: "doc.on.doc")
            }

            if let homepageURL = source.homepageURL, URL(string: homepageURL) != nil {
                Button {
                    copyURLString(homepageURL)
                } label: {
                    Label(localized("複製首頁 URL"), systemImage: "doc.on.doc")
                }
            }

            if store.unreadCount(for: source.id) > 0 {
                Button {
                    store.markAllRead(sourceID: source.id)
                } label: {
                    Label(localized("標記全部已讀"), systemImage: "checkmark.circle")
                }
            }

            Button {
                sourceToRename = source
            } label: {
                Label(localized("重新命名"), systemImage: "pencil")
            }

            Button(role: .destructive) {
                deleteTarget = .source(source)
            } label: {
                Label(localized("刪除"), systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if store.unreadCount(for: source.id) > 0 {
                Button {
                    store.markAllRead(sourceID: source.id)
                } label: {
                    Label(localized("標記全部已讀"), systemImage: "checkmark.circle")
                }
                .tint(.blue)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                deleteTarget = .source(source)
            } label: {
                Label(localized("刪除"), systemImage: "trash")
            }

            Button {
                sourceToRename = source
            } label: {
                Label(localized("重新命名"), systemImage: "pencil")
            }
            .tint(.orange)
        }
    }

    private func visibleSources(_ sources: [RSSSource]) -> [RSSSource] {
        sources.filter { source in
            !hideReadFeeds || store.unreadCount(for: source.id) > 0
        }
    }

    private func toggleFolder(_ folder: RSSFolder) {
        if expandedFolderIDs.contains(folder.id) {
            expandedFolderIDs.remove(folder.id)
        } else {
            expandedFolderIDs.insert(folder.id)
        }
    }

    private func seedExpandedFoldersIfNeeded() {
        guard !didSeedExpandedFolders else {
            expandedFolderIDs.formUnion(store.folders.map(\.id))
            return
        }
        didSeedExpandedFolders = true
        expandedFolderIDs = Set(store.folders.map(\.id))
    }

    private func performDelete(_ target: RSSDeleteTarget) {
        switch target {
        case .source(let source):
            store.removeSources(ids: [source.id])
        case .folder(let folder):
            store.removeFolder(folder, deleteSources: true)
        }
        deleteTarget = nil
    }

    private func source(for id: String) -> RSSSource? {
        store.source(id: id)
    }

    @MainActor
    private func backfillMissingSourceMetadata() async {
        guard !didBackfillSourceMetadata else { return }
        didBackfillSourceMetadata = true

        let candidates = store.sources.filter { source in
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

    @MainActor
    private func refreshAllSources() async {
        guard !isRefreshingAll else { return }
        let sources = store.sources.filter(\.enabled)
        guard !sources.isEmpty else { return }

        isRefreshingAll = true
        refreshProgress = RSSRefreshProgress(completed: 0, total: sources.count)
        defer {
            isRefreshingAll = false
        }

        for source in sources {
            let fetcher = RSSFetcher()
            await fetcher.fetchItems(from: source, metadata: store.feedMetadata(for: source.id))
            if fetcher.error == nil {
                if let response = fetcher.response {
                    store.applyFeedResponse(response, for: source.id)
                } else {
                    store.mergeFetchedItems(fetcher.items, for: source.id)
                }
            }
            refreshProgress.completed += 1
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

    private func openURLString(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        safariURL = url
    }

    private func copyURLString(_ urlString: String) {
        UIPasteboard.general.string = urlString
    }
}

private struct RSSRefreshProgress: Equatable {
    var completed: Int = 0
    var total: Int = 0
}

private enum RSSDeleteTarget: Identifiable {
    case source(RSSSource)
    case folder(RSSFolder)

    var id: String {
        switch self {
        case .source(let source):
            return "source-\(source.id)"
        case .folder(let folder):
            return "folder-\(folder.id)"
        }
    }

    var title: String {
        switch self {
        case .source:
            return localized("刪除訂閱源")
        case .folder:
            return localized("刪除資料夾")
        }
    }

    var message: String {
        switch self {
        case .source(let source):
            return String(format: localized("確定要刪除「%@」訂閱源嗎？"), source.name)
        case .folder(let folder):
            return String(format: localized("確定要刪除「%@」資料夾以及其中的訂閱源嗎？"), folder.name)
        }
    }
}

private extension RSSSmartFeedKind {
    var tintColor: Color {
        switch self {
        case .today:
            return .blue
        case .allUnread:
            return DSColor.accent
        case .starred:
            return .yellow
        }
    }
}

private enum RSSMainFeedIcon {
    case source(RSSSource)
    case system(String, tint: Color)
}

private struct RSSMainFeedSectionHeader: View {
    let title: String
    let unreadCount: Int
    @Binding var isExpanded: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .rotationEffect(.degrees(isExpanded ? 0 : -90))

            Text(title)
                .font(.footnote.weight(.semibold))

            Spacer()

            if !isExpanded && unreadCount > 0 {
                Text(unreadCount.formatted())
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

private struct RSSMainFeedFolderRow: View {
    let title: String
    let unreadCount: Int
    let isExpanded: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 0 : -90))
                .frame(width: 12)

            Image(systemName: "folder")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(DSColor.accent)
                .frame(width: 24, height: 24)

            Text(title)
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer()

            if !isExpanded && unreadCount > 0 {
                Text(unreadCount.formatted())
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct RSSMainFeedRow: View {
    let title: String
    let unreadCount: Int
    let icon: RSSMainFeedIcon
    var indent: CGFloat = 0

    var body: some View {
        HStack(spacing: 12) {
            iconView

            Text(title)
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer()

            if unreadCount > 0 {
                Text(unreadCount.formatted())
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, indent)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var iconView: some View {
        switch icon {
        case .source(let source):
            RSSFaviconView(source: source, size: 24)
                .frame(width: 28, height: 28)
        case .system(let imageName, let tint):
            Image(systemName: imageName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}

private struct RSSRefreshProgressBar: View {
    let progress: RSSRefreshProgress

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(String(format: localized("已刷新 %d / %d"), progress.completed, progress.total))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

private struct RSSSearchResultRow: View {
    let article: RSSArticleRecord
    let source: RSSSource?
    let dateFormatter: DateFormatter

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let source {
                RSSFaviconView(source: source, size: 24)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(article.title)
                    .font(.body)
                    .fontWeight(article.isRead ? .regular : .semibold)
                    .foregroundColor(.primary)
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
                .foregroundColor(.secondary)

                if !article.summary.isEmpty {
                    Text(article.summary)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(.vertical, 4)
        }
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
    private static let rootFolderID = "__rss_root_folder__"

    @Binding var isPresented: Bool
    @ObservedObject var store: RSSStore
    @ObservedObject var gs: GlobalSettings
    let folders: [RSSFolder]

    @State private var name = ""
    @State private var url = ""
    @State private var selectedFolderID = Self.rootFolderID
    @State private var isLoading = false

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text(localized("來源名稱（選填）"))) {
                    TextField(localized("留空將自動從 RSS 抓取"), text: $name)
                }
                Section(header: Text(localized("RSS 網址"))) {
                    TextField("https://", text: $url)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
                Section(header: Text(localized("資料夾"))) {
                    Picker(localized("資料夾"), selection: $selectedFolderID) {
                        Text(localized("無資料夾")).tag(Self.rootFolderID)
                        ForEach(folders) { folder in
                            Text(folder.name).tag(folder.id)
                        }
                    }
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
                        Task { await addSource() }
                    }
                    .foregroundColor(DSColor.accent)
                    .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
                }
            }
            .overlay {
                if isLoading {
                    ProgressView(localized("正在抓取 RSS 資訊…"))
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    @MainActor
    private func addSource() async {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return }

        isLoading = true
        defer { isLoading = false }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var finalName = trimmedName

        if finalName.isEmpty {
            let tempSource = RSSSource(name: "Temp", url: trimmedURL, sortOrder: 0)
            let fetcher = RSSFetcher()
            await fetcher.fetchItems(from: tempSource, metadata: nil)

            if case let .updated(_, _, feedInfo) = fetcher.response, let feedTitle = feedInfo?.title, !feedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                finalName = feedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let firstItemTitle = fetcher.items.first?.title, !firstItemTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                finalName = firstItemTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let host = URL(string: trimmedURL)?.host {
                finalName = host
            } else {
                finalName = "RSS Source"
            }
        }

        let folder = folders.first { $0.id == selectedFolderID }
        let source = RSSSource(
            name: finalName,
            url: trimmedURL,
            sortOrder: store.nextSourceSortOrder(in: folder),
            sourceGroup: folder?.name
        )
        store.addSource(source)
        isPresented = false
    }
}

private struct AddRSSFolderSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject var store: RSSStore

    @State private var name = ""

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text(localized("資料夾名稱"))) {
                    TextField(localized("資料夾名稱"), text: $name)
                }
            }
            .navigationTitle(localized("新增資料夾"))
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
                        addFolder()
                    }
                    .foregroundColor(DSColor.accent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func addFolder() {
        _ = store.addFolder(named: name)
        isPresented = false
    }
}

private struct RenameRSSSourceSheet: View {
    let source: RSSSource
    @ObservedObject var store: RSSStore
    @Environment(\.dismiss) private var dismiss

    @State private var name: String

    init(source: RSSSource, store: RSSStore) {
        self.source = source
        self.store = store
        _name = State(initialValue: source.name)
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text(localized("來源名稱"))) {
                    TextField(localized("來源名稱"), text: $name)
                }
            }
            .navigationTitle(localized("重新命名"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(localized("取消")) {
                        dismiss()
                    }
                    .foregroundColor(DSColor.accent)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(localized("完成")) {
                        var updated = source
                        updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        store.updateSource(updated)
                        dismiss()
                    }
                    .foregroundColor(DSColor.accent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct RenameRSSFolderSheet: View {
    let folder: RSSFolder
    @ObservedObject var store: RSSStore
    @Environment(\.dismiss) private var dismiss

    @State private var name: String

    init(folder: RSSFolder, store: RSSStore) {
        self.folder = folder
        self.store = store
        _name = State(initialValue: folder.name)
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text(localized("資料夾名稱"))) {
                    TextField(localized("資料夾名稱"), text: $name)
                }
            }
            .navigationTitle(localized("重新命名"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(localized("取消")) {
                        dismiss()
                    }
                    .foregroundColor(DSColor.accent)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(localized("完成")) {
                        var updated = folder
                        updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        store.updateFolder(updated)
                        dismiss()
                    }
                    .foregroundColor(DSColor.accent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct RSSSourceInfoSheet: View {
    let source: RSSSource
    @ObservedObject var store: RSSStore
    @Environment(\.dismiss) private var dismiss

    private var currentSource: RSSSource {
        store.source(id: source.id) ?? source
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text(localized("基本資訊"))) {
                    LabeledContent(localized("來源名稱"), value: currentSource.name)
                    LabeledContent(localized("RSS 網址"), value: currentSource.url)
                    if let homepageURL = currentSource.homepageURL, !homepageURL.isEmpty {
                        LabeledContent(localized("首頁"), value: homepageURL)
                    }
                    if let faviconURL = currentSource.displayFaviconURL, !faviconURL.isEmpty {
                        LabeledContent(localized("圖示"), value: faviconURL)
                    }
                    if let group = currentSource.sourceGroup, !group.isEmpty {
                        LabeledContent(localized("資料夾"), value: group)
                    }
                }

                Section {
                    Button {
                        UIPasteboard.general.string = currentSource.url
                    } label: {
                        Label(localized("複製訂閱 URL"), systemImage: "doc.on.doc")
                    }

                    if let homepageURL = currentSource.homepageURL, let url = URL(string: homepageURL) {
                        Button {
                            UIApplication.shared.open(url)
                        } label: {
                            Label(localized("開啟首頁"), systemImage: "safari")
                        }
                    }
                }
            }
            .navigationTitle(localized("取得資訊"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(localized("完成")) {
                        dismiss()
                    }
                    .foregroundColor(DSColor.accent)
                }
            }
        }
    }
}

#Preview {
    RSSListView()
}
