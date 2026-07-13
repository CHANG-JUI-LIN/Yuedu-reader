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
    @State private var showOPMLImportSheet = false
    @State private var showOPMLExporter = false
    @State private var showJSONImporter = false
    @State private var showJSONExporter = false
    @State private var showJSONURLSheet = false
    @State private var importMessage = ""
    @State private var showImportResult = false
    @State private var didBackfillSourceMetadata = false
    @State private var safariURL: URL?
    @State private var sourceToEdit: RSSSource?
    @State private var folderToRename: RSSFolder?
    @State private var sourceForInfo: RSSSource?
    @State private var deleteTarget: RSSDeleteTarget?
    @State private var isRefreshingAll = false
    @State private var refreshProgress = RSSRefreshProgress()
    @State private var showSettings = false
    @State private var showOrganize = false

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

    var body: some View {
        NavigationStack {
            ZStack {
                PageBackgroundView(scope: .rss)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        smartFeedsSection
                        localFeedsSection
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 36)
                }
                .scrollIndicators(.visible)
            }
            .navigationTitle(localized("RSS 訂閱"))
            .toolbarTitleDisplayModeInlineLargeOrInline()
            .pageBackgroundToolbar(for: .rss)
            .toolbar {
                // Two separate glass pills. A ToolbarSpacer (iOS 26+) breaks the
                // auto-merge so the add (+) and options (…) menus sit in their own
                // glass instead of fusing into one.
                ToolbarItem(placement: .topBarTrailing) {
                    RSSHomeAddMenu(
                        isRefreshingAll: isRefreshingAll,
                        hasSources: !store.sources.isEmpty,
                        onAddSource: { showAddSheet = true },
                        onAddFolder: { showAddFolderSheet = true },
                        onRefresh: { Task { await refreshAllSources() } },
                        onImportOPML: { showOPMLImportSheet = true },
                        onImportJSON: {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                showJSONImporter = true
                            }
                        }
                    )
                }

                if #available(iOS 26.0, *) {
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    RSSHomeTopMenu(
                        hideReadFeeds: hideReadFeeds,
                        hasSources: !store.sources.isEmpty,
                        hasUnreadArticles: store.totalUnreadCount() > 0,
                        onToggleHideRead: { hideReadFeeds.toggle() },
                        onMarkAllRead: { store.markAllRead() },
                        onOrganize: { showOrganize = true },
                        onExportOPML: {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                showOPMLExporter = true
                            }
                        },
                        onExportJSON: {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                showJSONExporter = true
                            }
                        },
                        onSettings: { showSettings = true }
                    )
                }
            }
            .refreshable {
                await refreshAllSources()
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
            .sheet(isPresented: $showOPMLImportSheet) {
                RSSOPMLImportSheet(
                    isPresented: $showOPMLImportSheet,
                    onFileCompletion: importOPML,
                    onDataImport: { data in
                        importOPMLData(data)
                    }
                )
            }
            .sheet(item: $safariURL) { url in
                SafariView(url: url)
                    .ignoresSafeArea()
            }
            .sheet(item: $sourceToEdit) { source in
                EditRSSSourceSheet(source: source, store: store)
            }
            .sheet(isPresented: $showOrganize) {
                RSSOrganizeSheet(store: store)
            }
            .sheet(item: $folderToRename) { folder in
                RenameRSSFolderSheet(folder: folder, store: store)
            }
            .sheet(item: $sourceForInfo) { source in
                RSSSourceInfoSheet(source: source, store: store)
            }
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
            .sheet(isPresented: $showSettings) {
                RSSSettingsContentView(isPresented: $showSettings)
            }
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

    private var smartFeedsSection: some View {
        RSSHomeSection(
            title: localized("訂閱"),
            unreadCount: 0,
            isExpanded: $smartFeedsExpanded
        ) {
            ForEach(RSSSmartFeedKind.allCases) { smartFeed in
                NavigationLink(destination: RSSSmartFeedView(kind: smartFeed)) {
                    RSSMainFeedRow(
                        title: smartFeed.title,
                        unreadCount: store.unreadCount(for: smartFeed),
                        icon: .system(smartFeed.systemImage, tint: smartFeed.tintColor)
                    )
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if store.unreadCount(for: smartFeed) > 0 {
                        Button {
                            store.markAllRead(smartFeed: smartFeed)
                        } label: {
                            Label(localized("標記全部已讀"), systemImage: "checkmark.circle")
                        }
                    }
                }
                .overlay(alignment: .bottom) {
                    RSSHomeDivider()
                }
            }
        }
    }

    private var localFeedsSection: some View {
        RSSHomeSection(
            title: localized("本機"),
            unreadCount: store.totalUnreadCount(),
            isExpanded: $localFeedsExpanded
        ) {
            if hideReadFeeds && visibleFolders.isEmpty && rootSources.isEmpty && !store.sources.isEmpty {
                Text(localized("沒有未讀訂閱"))
                    .font(DSFont.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 14)
            }

            ForEach(visibleFolders) { folder in
                folderRow(folder)
                    .overlay(alignment: .bottom) {
                        RSSHomeDivider()
                    }

                if expandedFolderIDs.contains(folder.id) {
                    ForEach(visibleSources(store.sources(in: folder))) { source in
                        sourceRow(source, indent: 36)
                            .overlay(alignment: .bottom) {
                                RSSHomeDivider()
                            }
                    }
                }
            }

            ForEach(rootSources) { source in
                sourceRow(source, indent: 0)
                    .overlay(alignment: .bottom) {
                        RSSHomeDivider()
                    }
            }
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
        .buttonStyle(.plain)
        .tint(.primary)
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
                sourceToEdit = source
            } label: {
                Label(localized("編輯訂閱"), systemImage: "pencil")
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
                .tint(DSColor.accent)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                deleteTarget = .source(source)
            } label: {
                Label(localized("刪除"), systemImage: "trash")
            }

            Button {
                sourceToEdit = source
            } label: {
                Label(localized("編輯訂閱"), systemImage: "pencil")
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
            store.applyResolvedFeedURL(fetcher.resolvedFeedURL, homepageURL: fetcher.resolvedHomepageURL, to: source.id)
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
                store.applyResolvedFeedURL(fetcher.resolvedFeedURL, homepageURL: fetcher.resolvedHomepageURL, to: source.id)
                let currentSource = store.source(id: source.id) ?? source
                let newArticles: [RSSArticleRecord]
                if let response = fetcher.response {
                    newArticles = store.applyFeedResponse(response, for: source.id)
                } else {
                    newArticles = store.mergeFetchedItems(fetcher.items, for: source.id)
                }
                RSSNotificationManager.shared.notifyNewArticles(newArticles, source: currentSource)
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
            let addedSources = store.addSourcesReturningAdded(sources)
            importMessage = String(format: localized("已匯入 %d 個訂閱源"), addedSources.count)
            showImportResult = true
            Task { await refreshImportedSources(addedSources) }
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
            importOPMLData(data)
        } catch {
            importMessage = String(format: localized("OPML 匯入失敗：%@"), error.localizedDescription)
            showImportResult = true
        }
    }

    private func importOPMLData(_ data: Data) {
        do {
            let sources = try RSSOPMLParser.parse(data: data)
            let addedSources = store.addSourcesReturningAdded(sources)
            importMessage = String(format: localized("已匯入 %d 個訂閱源"), addedSources.count)
            showImportResult = true
            Task { await refreshImportedSources(addedSources) }
        } catch {
            importMessage = String(format: localized("OPML 匯入失敗：%@"), error.localizedDescription)
            showImportResult = true
        }
    }

    @MainActor
    private func refreshImportedSources(_ sources: [RSSSource]) async {
        for source in sources where source.enabled {
            let fetcher = RSSFetcher()
            await fetcher.fetchItems(from: source, metadata: nil)
            guard fetcher.error == nil else { continue }

            store.applyResolvedFeedURL(fetcher.resolvedFeedURL, homepageURL: fetcher.resolvedHomepageURL, to: source.id)
            if let response = fetcher.response {
                store.applyFeedResponse(response, for: source.id)
            } else {
                store.mergeFetchedItems(fetcher.items, for: source.id)
            }
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

private struct RSSHomeCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct RSSHomeSection<Content: View>: View {
    let title: String
    let unreadCount: Int
    @Binding var isExpanded: Bool
    let content: Content

    init(
        title: String,
        unreadCount: Int,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.unreadCount = unreadCount
        self._isExpanded = isExpanded
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    Text(title)
                        .font(DSFont.title3.weight(.bold))
                        .foregroundStyle(.primary)

                    Spacer()

                    if !isExpanded && unreadCount > 0 {
                        Text(unreadCount.formatted())
                            .font(DSFont.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }

                    Image(systemName: "chevron.down")
                        .font(DSFont.fixed(size: 17, weight: .bold))
                        .foregroundStyle(.primary)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                }
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                RSSHomeCard {
                    VStack(spacing: 0) {
                        content
                    }
                }
            }
        }
    }
}

private struct RSSHomeDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 58)
    }
}

private struct RSSHomeAddMenu: View {
    let isRefreshingAll: Bool
    let hasSources: Bool
    let onAddSource: () -> Void
    let onAddFolder: () -> Void
    let onRefresh: () -> Void
    let onImportOPML: () -> Void
    let onImportJSON: () -> Void

    var body: some View {
        Menu {
            Button {
                onAddSource()
            } label: {
                Label(localized("新增 RSS 訂閱"), systemImage: "plus")
            }

            Button {
                onAddFolder()
            } label: {
                Label(localized("新增資料夾"), systemImage: "folder.badge.plus")
            }

            Divider()

            Button {
                onImportOPML()
            } label: {
                Label(localized("匯入 OPML"), systemImage: "square.and.arrow.down")
            }

            Button {
                onImportJSON()
            } label: {
                Label(localized("匯入 Legado JSON"), systemImage: "doc.badge.plus")
            }

            Divider()

            Button {
                onRefresh()
            } label: {
                Label(localized("刷新全部訂閱"), systemImage: "arrow.clockwise")
            }
            .disabled(isRefreshingAll || !hasSources)
        } label: {
            Image(systemName: "plus")
        }
        .accessibilityLabel(localized("新增或匯入"))
    }
}

private struct RSSHomeTopMenu: View {
    let hideReadFeeds: Bool
    let hasSources: Bool
    let hasUnreadArticles: Bool
    let onToggleHideRead: () -> Void
    let onMarkAllRead: () -> Void
    let onOrganize: () -> Void
    let onExportOPML: () -> Void
    let onExportJSON: () -> Void
    let onSettings: () -> Void

    var body: some View {
        Menu {
            Button {
                onMarkAllRead()
            } label: {
                Label(localized("標記全部已讀"), systemImage: "checkmark.circle")
            }
            .disabled(!hasUnreadArticles)

            Button {
                onToggleHideRead()
            } label: {
                Label(
                    hideReadFeeds ? localized("顯示已讀訂閱") : localized("隱藏已讀訂閱"),
                    systemImage: hideReadFeeds ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
                )
            }

            Button {
                onOrganize()
            } label: {
                Label(localized("整理訂閱"), systemImage: "arrow.up.arrow.down")
            }
            .disabled(!hasSources)

            Divider()

            Button {
                onExportOPML()
            } label: {
                Label(localized("匯出 OPML"), systemImage: "square.and.arrow.up")
            }
            .disabled(!hasSources)

            Button {
                onExportJSON()
            } label: {
                Label(localized("匯出 Legado JSON"), systemImage: "doc.badge.arrow.up")
            }
            .disabled(!hasSources)

            Divider()

            Button {
                onSettings()
            } label: {
                Label(localized("設定"), systemImage: "gearshape")
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel(localized("更多"))
    }
}

private struct RSSSettingsContentView: View {
    @Binding var isPresented: Bool

    var body: some View {
        SettingsView()
            .environmentObject(BookStore())
            .environmentObject(SubscriptionStore.shared)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        isPresented = false
                    } label: {
                        Label(localized("完成"), systemImage: "checkmark")
                            .labelStyle(.iconOnly)
                    }
                    .accessibilityLabel(localized("完成"))
                }
            }
    }
}

private struct RSSOPMLImportSheet: View {
    @Binding var isPresented: Bool
    let onFileCompletion: (Result<[URL], Error>) -> Void
    let onDataImport: (Data) -> Void

    @State private var showFileImporter = false
    @State private var urlString = ""
    @State private var isLoading = false
    @State private var message = ""
    @State private var showMessage = false

    private var opmlContentTypes: [UTType] {
        var contentTypes: [UTType] = []
        if let opmlByExtension = UTType(filenameExtension: "opml") {
            contentTypes.append(opmlByExtension)
        }
        if let registeredOPML = UTType("org.opml.opml") {
            contentTypes.append(registeredOPML)
        }
        contentTypes.append(.xml)
        return contentTypes
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text(localized("OPML 網址"))) {
                    TextField("https://example.com/subscriptions.opml", text: $urlString)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button {
                        Task { await importFromURL() }
                    } label: {
                        Label(localized("從網址匯入 OPML"), systemImage: "link.badge.plus")
                    }
                    .disabled(urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
                }

                Section(header: Text(localized("本機文件"))) {
                    Button {
                        showFileImporter = true
                    } label: {
                        Label(localized("選取 OPML 文件"), systemImage: "doc.badge.plus")
                    }
                }

                if showMessage {
                    Section {
                        Text(message)
                            .foregroundColor(message.hasPrefix("❌") ? .red : DSColor.textPrimary)
                    }
                }
            }
                .navigationTitle(localized("匯入 OPML"))
                .toolbarTitleDisplayMode(.inline)
                .themedAppSurface(for: .rss)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            isPresented = false
                        } label: {
                            Image(systemName: "xmark")
                        }
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
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: opmlContentTypes,
                allowsMultipleSelection: false
            ) { result in
                isPresented = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    onFileCompletion(result)
                }
            }
        }
    }

    @MainActor
    private func importFromURL() async {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            message = "❌ \(localized("RSS URL 無效"))"
            showMessage = true
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let httpResponse = response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode) {
                throw URLError(.badServerResponse)
            }

            isPresented = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                onDataImport(data)
            }
        } catch {
            message = "❌ \(String(format: localized("OPML 匯入失敗：%@"), error.localizedDescription))"
            showMessage = true
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
                .font(DSFont.fixed(size: 11, weight: .semibold))
                .rotationEffect(.degrees(isExpanded ? 0 : -90))

            Text(title)
                .font(DSFont.footnote.weight(.semibold))

            Spacer()

            if !isExpanded && unreadCount > 0 {
                Text(unreadCount.formatted())
                    .font(DSFont.footnote.weight(.semibold))
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
        HStack(spacing: 10) {
            Image(systemName: "folder")
                .font(DSFont.fixed(size: 20, weight: .semibold))
                .foregroundStyle(DSColor.accent)
                .frame(width: 32, height: 32)

            Text(title)
                .font(DSFont.body)
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer()

            if !isExpanded && unreadCount > 0 {
                Text(unreadCount.formatted())
                    .font(DSFont.body)
                    .foregroundStyle(.secondary)
            }

            Image(systemName: "chevron.down")
                .font(DSFont.fixed(size: 13, weight: .bold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 0 : -90))
                .frame(width: 16)
        }
        .padding(.horizontal, 24)
        .frame(minHeight: 56)
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
        HStack(spacing: 10) {
            iconView

            Text(title)
                .font(DSFont.body)
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer()

            if unreadCount > 0 {
                Text(unreadCount.formatted())
                    .font(DSFont.body)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 24 + indent)
        .padding(.trailing, 24)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var iconView: some View {
        switch icon {
        case .source(let source):
            RSSFaviconView(source: source, size: 26)
                .frame(width: 32, height: 32)
        case .system(let imageName, let tint):
            Image(systemName: imageName)
                .font(DSFont.fixed(size: 24, weight: .regular))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
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
                .font(DSFont.footnote)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
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
        NavigationStack {
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
            .toolbarTitleDisplayMode(.inline)
            .themedAppSurface(for: .rss)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await importFromURL() }
                    } label: {
                        Image(systemName: "checkmark")
                    }
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
        NavigationStack {
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
            .toolbarTitleDisplayMode(.inline)
            .themedAppSurface(for: .rss)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await addSource() }
                    } label: {
                        Image(systemName: "checkmark")
                    }
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
        await refreshInitialArticles(for: source)
        isPresented = false
    }

    @MainActor
    private func refreshInitialArticles(for source: RSSSource) async {
        let fetcher = RSSFetcher()
        await fetcher.fetchItems(from: source, metadata: nil)
        guard fetcher.error == nil else { return }

        store.applyResolvedFeedURL(fetcher.resolvedFeedURL, homepageURL: fetcher.resolvedHomepageURL, to: source.id)
        if let response = fetcher.response {
            store.applyFeedResponse(response, for: source.id)
        } else {
            store.mergeFetchedItems(fetcher.items, for: source.id)
        }
    }
}

private struct AddRSSFolderSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject var store: RSSStore

    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text(localized("資料夾名稱"))) {
                    TextField(localized("資料夾名稱"), text: $name)
                }
            }
            .navigationTitle(localized("新增資料夾"))
            .toolbarTitleDisplayMode(.inline)
            .themedAppSurface(for: .rss)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        addFolder()
                    } label: {
                        Image(systemName: "checkmark")
                    }
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
        NavigationStack {
            Form {
                Section(header: Text(localized("資料夾名稱"))) {
                    TextField(localized("資料夾名稱"), text: $name)
                }
            }
            .navigationTitle(localized("重新命名"))
            .toolbarTitleDisplayMode(.inline)
            .themedAppSurface(for: .rss)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        var updated = folder
                        updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        store.updateFolder(updated)
                        dismiss()
                    } label: {
                        Image(systemName: "checkmark")
                    }
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
        NavigationStack {
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
            .toolbarTitleDisplayMode(.inline)
            .themedAppSurface(for: .rss)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Label(localized("完成"), systemImage: "checkmark")
                            .labelStyle(.iconOnly)
                    }
                    .accessibilityLabel(localized("完成"))
                    .foregroundColor(DSColor.accent)
                }
            }
        }
    }
}

#Preview {
    RSSListView()
}
