import SwiftUI

/// Feed routes freeze the selected location rather than resolving a live list.
struct OPDSFeedRoute: Hashable {
    let catalogID: String
    let url: String
    let title: String
}

struct OPDSImportView: View {
    var kind: RemoteLibraryKind = .opds

    var body: some View {
        RemoteLibraryBrowserView(kind: kind)
    }
}

/// Saved connections own browsing independently from backup destinations.
struct RemoteLibraryBrowserView: View {
    let kind: RemoteLibraryKind
    @Environment(\.appDependencies) private var dependencies
    @EnvironmentObject private var store: BookStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var catalogStore = RemoteLibraryConnectionStore.shared

    private var connections: [RemoteLibraryConnection] {
        catalogStore.catalogs.filter { $0.kind == kind }
    }

    var body: some View {
        NavigationStack {
            List {
                if kind == .calibre {
                    Section {
                        NavigationLink {
                            CalibreWirelessView(store: store, service: dependencies.calibreWireless)
                        } label: {
                            SettingsRowLabel(localized("電腦傳書"), systemImage: "desktopcomputer")
                        }
                    }.interfaceSectionSurface()
                    if connections.isEmpty {
                        // Receiving from the desktop is available without a
                        // Content Server connection. Keep the empty state in
                        // the list so it cannot cover that navigation row.
                        Section { emptyLibraryView }.interfaceSectionSurface()
                    }
                }
                Section {
                    ForEach(connections) { connection in
                        connectionLink(connection)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { catalogStore.remove(connection) } label: {
                                    Label(localized("刪除"), systemImage: "trash")
                                }
                            }
                    }
                }
                .interfaceSectionSurface()
                if kind == .opds {
                    Section(localized("範例目錄")) {
                        ForEach(OPDSCatalogStore.presets.filter { preset in
                            !connections.contains { $0.url == preset.url }
                        }, id: \.url) { preset in
                            Button {
                                catalogStore.add(name: preset.name, url: preset.url, username: nil, password: nil)
                            } label: {
                                Label(preset.name, systemImage: "plus")
                            }
                        }
                    }
                    .interfaceSectionSurface()
                }
            }
            .softScrollEdges()
            .overlay {
                if connections.isEmpty && kind == .webDAV { emptyLibraryView }
            }
            .navigationTitle(kind.libraryTitle)
            .toolbarTitleDisplayMode(.inline)
            .themedAppSurface(for: .bookshelf)
            .navigationDestination(for: OPDSFeedRoute.self) { route in
                OPDSFeedView(route: route)
            }
            .navigationDestination(for: WebDAVDirectoryRoute.self) { route in
                WebDAVDirectoryView(route: route)
            }
            .navigationDestination(for: RemoteLibraryBookRoute.self) { route in
                RemoteLibraryBookDetailView(item: route.item)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Label(localized("關閉"), systemImage: "xmark").labelStyle(.iconOnly)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        RemoteLibraryConnectionEditor(kind: kind)
                    } label: {
                        Label(localized("新增伺服器"), systemImage: "plus").labelStyle(.iconOnly)
                    }
                }
            }
        }
    }

    private var emptyLibraryView: some View {
        ContentUnavailableView {
            UnavailableLabel(localized("尚未加入書庫"), systemImage: "books.vertical")
        } description: {
            Text(localized("加入伺服器即可瀏覽書籍並開始閱讀。")).foregroundStyle(DSColor.textSecondary)
        } actions: {
            NavigationLink(localized("新增伺服器")) {
                RemoteLibraryConnectionEditor(kind: kind)
            }
        }
    }

    @ViewBuilder
    private func connectionLink(_ connection: RemoteLibraryConnection) -> some View {
        if kind == .webDAV, let root = catalogStore.webDAVClient(for: connection).rootURL {
            NavigationLink(value: WebDAVDirectoryRoute(connectionID: connection.id, url: root, title: connection.name)) {
                connectionLabel(connection)
            }
        } else {
            NavigationLink(value: OPDSFeedRoute(catalogID: connection.id, url: connection.url, title: connection.name)) {
                connectionLabel(connection)
            }
        }
    }

    private func connectionLabel(_ connection: RemoteLibraryConnection) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            Text(connection.name).foregroundStyle(DSColor.textPrimary)
            Text(connection.url).font(DSFont.caption).foregroundStyle(DSColor.textSecondary).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

struct RemoteLibraryConnectionEditor: View {
    let kind: RemoteLibraryKind
    var connection: RemoteLibraryConnection?
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var catalogStore = RemoteLibraryConnectionStore.shared
    @State private var name: String
    @State private var url: String
    @State private var username: String
    @State private var password: String
    @State private var syncProgress: Bool
    @State private var isTesting = false
    @State private var testResult: String?
    @State private var testTask: Task<Void, Never>?

    init(kind: RemoteLibraryKind, connection: RemoteLibraryConnection? = nil) {
        self.kind = kind
        self.connection = connection
        _syncProgress = State(initialValue: connection?.syncProgress ?? false)
        _name = State(initialValue: connection?.name ?? "")
        _url = State(initialValue: connection?.url ?? "")
        _username = State(initialValue: connection?.username ?? "")
        _password = State(initialValue: connection.flatMap { RemoteLibraryConnectionStore.shared.password(for: $0) } ?? "")
    }

    private var normalizedURL: URL? { RemoteLibraryConnection.normalizedURL(url, kind: kind) }

    var body: some View {
        Form {
            Section {
                TextField(localized("伺服器名稱（選填）"), text: $name)
                TextField(localized("伺服器網址"), text: $url)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            } header: {
                Text(localized("伺服器設定"))
                    .foregroundStyle(DSColor.textSecondary)
            } footer: {
                if kind == .calibre {
                    Text(localized("輸入 Calibre 或 Calibre-Web 伺服器網址；完整 OPDS 網址也可使用。"))
                        .dsSectionFooter()
                } else if kind == .webDAV {
                    Text(localized("書庫連線獨立儲存，修改此處不會變更 WebDAV 同步設定。"))
                        .dsSectionFooter()
                }
            }
            .interfaceSectionSurface()
            Section(localized("認證（選填）")) {
                TextField(localized("使用者名稱"), text: $username)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField(localized("密碼"), text: $password)
            }
            .interfaceSectionSurface()
            if kind == .calibre {
                Section {
                    Toggle(localized("回傳至 Calibre 網頁閱讀器"), isOn: $syncProgress)
                } footer: {
                    Text(localized("使用 Calibre 內容伺服器帳號回傳 EPUB 位置，可在電腦的網頁閱讀器續讀。") + "\n\n" + localized("Calibre 桌面獨立閱讀器與 Calibre-Web 不支援此續讀方式。"))
                        .dsSectionFooter()
                }.interfaceSectionSurface()
            }
            Section {
                Button(action: testConnection) {
                    HStack {
                        Text(localized("測試連線"))
                        Spacer()
                        if isTesting { ProgressView() }
                    }
                }
                .disabled(normalizedURL == nil || isTesting)
                if let testResult { Text(testResult).foregroundStyle(DSColor.textSecondary) }
            }
            .interfaceSectionSurface()
        }
        .softScrollEdges()
        .navigationTitle(localized(connection == nil ? "新增伺服器" : "編輯伺服器"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .bookshelf)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: save) {
                    Label(localized("儲存"), systemImage: "checkmark").labelStyle(.iconOnly)
                }
                .disabled(normalizedURL == nil)
            }
        }
        .onDisappear { testTask?.cancel() }
        .onChange(of: url) { _, _ in testTask?.cancel(); isTesting = false; testResult = nil }
        .onChange(of: username) { _, _ in testTask?.cancel(); isTesting = false; testResult = nil }
        .onChange(of: password) { _, _ in testTask?.cancel(); isTesting = false; testResult = nil }
    }

    private func save() {
        guard let url = normalizedURL else { return }
        if var connection {
            connection.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if connection.name.isEmpty { connection.name = url.host ?? url.absoluteString }
            connection.url = url.absoluteString
            connection.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
            connection.syncProgress = syncProgress
            catalogStore.update(connection, password: password)
        } else {
            var added = catalogStore.add(name: name, url: url.absoluteString, username: username, password: password, kind: kind)
            added.syncProgress = syncProgress
            catalogStore.update(added, password: nil)
        }
        dismiss()
    }

    private func testConnection() {
        guard let url = normalizedURL else { return }
        isTesting = true
        testResult = nil
        let user = username
        let secret = password
        testTask = Task { @MainActor in
            do {
                try await catalogStore.testConnection(url: url, kind: kind, username: user, password: secret)
                try Task.checkCancellation()
                testResult = localized("連線成功")
            } catch {
                guard !Task.isCancelled else { return }
                testResult = error.localizedDescription
            }
            isTesting = false
            if let testResult { UIAccessibility.post(notification: .announcement, argument: testResult) }
        }
    }
}

struct OPDSFeedView: View {
    let route: OPDSFeedRoute
    @ObservedObject private var catalogStore = RemoteLibraryConnectionStore.shared
    @StateObject private var model: OPDSBrowseModel
    @State private var searchText = ""
    @State private var requestTask: Task<Void, Never>?

    init(route: OPDSFeedRoute) {
        self.route = route
        _model = StateObject(wrappedValue: OPDSBrowseModel(route: route))
    }

    private var entries: [OPDSEntry] { model.entries }
    private var nextPageURL: URL? { model.nextPageURL }
    private var isLoading: Bool { model.isLoading }
    private var isLoadingMore: Bool { model.isLoadingMore }
    private var didLoad: Bool { model.didLoad }
    private var loadError: String? { model.loadError }
    private var failedWhileLoadingMore: Bool { model.failedWhileLoadingMore }

    private var connection: RemoteLibraryConnection? {
        catalogStore.connection(id: route.catalogID)
    }

    var body: some View {
        List {
            if let loadError {
                Section {
                    Label(loadError, systemImage: "exclamationmark.triangle").foregroundStyle(DSColor.textSecondary)
                    Button(localized("重試")) {
                        if failedWhileLoadingMore {
                            requestTask = Task { await loadMore() }
                        } else { submitSearch() }
                    }
                    .disabled(isLoading || isLoadingMore)
                }
                .interfaceSectionSurface()
            }
            Section {
                ForEach(entries) { entry in row(for: entry) }
                if nextPageURL != nil {
                    Button {
                        requestTask = Task { await loadMore() }
                    } label: {
                        HStack {
                            Text(localized("載入更多"))
                            Spacer()
                            if isLoadingMore { ProgressView() }
                        }
                    }
                    .disabled(isLoadingMore || isLoading)
                }
            }
            .interfaceSectionSurface()
        }
        .softScrollEdges()
        .overlay {
            if isLoading && entries.isEmpty && loadError == nil {
                ProgressView(localized("正在載入書庫"))
            } else if !isLoading && entries.isEmpty && loadError == nil {
                ContentUnavailableView {
                    UnavailableLabel(localized("此目錄沒有內容"), systemImage: "books.vertical")
                }
            }
        }
        .navigationTitle(route.title)
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .bookshelf)
        .searchable(text: $searchText, prompt: localized("搜尋此目錄"))
        .onSubmit(of: .search, submitSearch)
        .submitScope()
        .onChange(of: searchText) { oldValue, newValue in
            if !oldValue.isEmpty && newValue.isEmpty { submitSearch() }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let connection, PublicLibrary.connection(id: connection.id) == nil {
                    Menu {
                        if let url = URL(string: route.url) {
                            NavigationLink(localized("管理遠端書庫")) {
                                RemoteLibraryManagementView(connectionID: connection.id, directoryURL: url)
                            }
                        }
                        NavigationLink {
                            RemoteLibraryConnectionEditor(kind: connection.kind, connection: connection)
                        } label: {
                            Label(localized("編輯伺服器"), systemImage: "slider.horizontal.3")
                        }
                    } label: {
                        Label(localized("書庫操作"), systemImage: "ellipsis.circle").labelStyle(.iconOnly)
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .remoteLibraryDidChange)) { note in
            guard note.userInfo?["connectionID"] as? String == route.catalogID else { return }
            submitSearch()
        }
        .refreshable { await loadInitial() }
        .task(id: route.url) {
            // Returning from a book keeps the loaded page and search intact.
            guard !didLoad else { return }
            await loadInitial()
        }
    }

    @ViewBuilder
    private func row(for entry: OPDSEntry) -> some View {
        if entry.isNavigation, let dest = entry.navigationURL {
            NavigationLink(value: OPDSFeedRoute(catalogID: route.catalogID, url: dest.absoluteString, title: entry.title)) {
                if let thumbnail = PublicLibrary.listCoverURL(entry.displayCoverURL, connectionID: route.catalogID) {
                    HStack(spacing: DSSpacing.md) {
                        BookCoverImage(coverURL: thumbnail.absoluteString, title: entry.title, author: entry.author,
                                       session: connection.map { catalogStore.httpClient(for: $0).session })
                            .frame(width: DSLayout.searchResultCoverWidth, height: DSLayout.searchResultCoverHeight)
                            .accessibilityHidden(true)
                        Text(entry.title).foregroundStyle(DSColor.textPrimary)
                    }
                } else {
                    Label(entry.title, systemImage: "folder.fill").foregroundStyle(DSColor.textPrimary)
                }
            }
        } else {
            NavigationLink(value: RemoteLibraryBookRoute(entry: entry, connectionID: route.catalogID)) {
                HStack(spacing: DSSpacing.md) {
                    BookCoverImage(
                        coverURL: PublicLibrary.listCoverURL(entry.displayCoverURL, connectionID: route.catalogID)?.absoluteString ?? "",
                        title: entry.title,
                        author: entry.author,
                        session: connection.map { RemoteLibraryConnectionStore.shared.httpClient(for: $0).session }
                    )
                    .frame(width: DSLayout.searchResultCoverWidth, height: DSLayout.searchResultCoverHeight)
                    .clipShape(RoundedRectangle(cornerRadius: DSRadius.sm))
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: DSSpacing.xs) {
                        Text(entry.title).foregroundStyle(DSColor.textPrimary).lineLimit(2)
                        if let author = entry.author {
                            Text(author).font(DSFont.caption).foregroundStyle(DSColor.textSecondary).lineLimit(1)
                        }
                        if entry.bestAcquisition == nil {
                            Text(localized("此格式暫不支援閱讀")).font(DSFont.caption).foregroundStyle(DSColor.textSecondary)
                        }
                    }
                }
            }
        }
    }

    private func submitSearch() {
        requestTask?.cancel()
        requestTask = Task { await loadInitial() }
    }

    private func loadInitial() async { await model.load(query: searchText) }
    private func loadMore() async { await model.loadMore() }

}

extension RemoteLibraryKind {
    var libraryTitle: String {
        switch self {
        case .opds: localized("OPDS 書庫")
        case .webDAV: localized("WebDAV 書庫")
        case .calibre: localized("Calibre 書庫")
        }
    }
}

#Preview {
    OPDSImportView().environmentObject(BookStore())
}

#Preview("Built-in Gutenberg feed") {
    NavigationStack {
        OPDSFeedView(route: OPDSFeedRoute(catalogID: PublicLibraryID.gutenberg.rawValue,
            url: PublicLibrary.gutenberg.url, title: localized("Project Gutenberg")))
    }.environmentObject(BookStore())
}
