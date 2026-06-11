import SwiftUI

// MARK: - OPDS Import
//
// Entry point from the bookshelf "+ → 從 OPDS 匯入". Lists saved catalogs, lets the
// user add/remove them, and pushes into `OPDSFeedView` to browse, search and import.

/// A pushed feed location. Carries the catalog id (not the client) so the value
/// stays Hashable; `OPDSFeedView` rebuilds the client from the store + Keychain.
struct OPDSFeedRoute: Hashable {
    let catalogID: String
    let url: String
    let title: String
}

struct OPDSImportView: View {
    @EnvironmentObject var store: BookStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var catalogStore = OPDSCatalogStore.shared
    @State private var showAddSheet = false

    private var presetsNotAdded: [OPDSCatalog] {
        OPDSCatalogStore.presets.filter { preset in
            !catalogStore.catalogs.contains { $0.url == preset.url }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if catalogStore.catalogs.isEmpty {
                    emptyState
                } else {
                    catalogList
                }
            }
            .navigationTitle(localized("從 OPDS 匯入"))
            .toolbarTitleDisplayMode(.large)
            .navigationDestination(for: OPDSFeedRoute.self) { route in
                OPDSFeedView(route: route).environmentObject(store)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(localized("取消")) { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showAddSheet = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showAddSheet) {
                AddOPDSCatalogSheet(catalogStore: catalogStore)
            }
        }
    }

    private var catalogList: some View {
        List {
            Section {
                ForEach(catalogStore.catalogs) { catalog in
                    NavigationLink(value: OPDSFeedRoute(catalogID: catalog.id, url: catalog.url, title: catalog.name)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(catalog.name).foregroundColor(DSColor.textPrimary)
                            Text(catalog.url)
                                .font(DSFont.caption).foregroundColor(DSColor.textSecondary).lineLimit(1)
                        }
                    }
                }
                .onDelete { catalogStore.remove(atOffsets: $0) }
            }
            if !presetsNotAdded.isEmpty {
                Section(header: Text(localized("範例目錄"))) {
                    ForEach(presetsNotAdded, id: \.url) { preset in
                        Button {
                            catalogStore.add(name: preset.name, url: preset.url, username: nil, password: nil)
                        } label: {
                            Label(preset.name, systemImage: "plus")
                                .foregroundColor(DSColor.accent)
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(localized("尚未加入 OPDS 目錄"), systemImage: "books.vertical")
        } description: {
            Text(localized("加入 OPDS 目錄即可瀏覽並下載書籍。"))
        } actions: {
            Button(localized("新增 OPDS 目錄")) { showAddSheet = true }
                .buttonStyle(.borderedProminent)
            ForEach(OPDSCatalogStore.presets, id: \.url) { preset in
                Button(localized("加入範例：") + preset.name) {
                    catalogStore.add(name: preset.name, url: preset.url, username: nil, password: nil)
                }
            }
        }
    }
}

// MARK: - Add Catalog Sheet

struct AddOPDSCatalogSheet: View {
    @ObservedObject var catalogStore: OPDSCatalogStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var url = ""
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text(localized("目錄資訊"))) {
                    TextField(localized("目錄名稱（選填）"), text: $name)
                    TextField(localized("OPDS 目錄網址"), text: $url)
                        .autocapitalization(.none).disableAutocorrection(true).keyboardType(.URL)
                }
                Section(header: Text(localized("認證（選填）"))) {
                    TextField(localized("使用者名稱"), text: $username)
                        .autocapitalization(.none).disableAutocorrection(true)
                    SecureField(localized("密碼"), text: $password)
                }
            }
            .navigationTitle(localized("新增 OPDS 目錄"))
            .toolbarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(localized("取消")) { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(localized("加入目錄")) {
                        catalogStore.add(name: name, url: url, username: username, password: password)
                        dismiss()
                    }
                    .disabled(OPDSClient.url(from: url) == nil)
                }
            }
        }
    }
}

// MARK: - Feed Browser

struct OPDSFeedView: View {
    @EnvironmentObject var store: BookStore
    let route: OPDSFeedRoute

    @State private var entries: [OPDSEntry] = []
    @State private var nextPageURL: URL?
    @State private var searchDescURL: URL?
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var loadError: String?
    @State private var searchText = ""

    @State private var importingID: String?
    @State private var importedIDs: Set<String> = []
    @State private var failedID: String?

    private var client: OPDSClient {
        if let catalog = OPDSCatalogStore.shared.catalog(id: route.catalogID) {
            return OPDSCatalogStore.shared.client(for: catalog)
        }
        return OPDSClient(username: nil, password: nil)
    }

    var body: some View {
        List {
            if let loadError {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(loadError, systemImage: "exclamationmark.triangle")
                            .foregroundColor(DSColor.textSecondary)
                        Button(localized("重試")) { Task { await loadInitial() } }
                            .foregroundColor(DSColor.accent)
                    }
                    .padding(.vertical, 4)
                }
            }
            ForEach(entries) { entry in
                row(for: entry)
            }
            if nextPageURL != nil && loadError == nil {
                loadMoreRow
            }
        }
        .overlay {
            if isLoading && entries.isEmpty && loadError == nil {
                ProgressView().controlSize(.large)
            } else if !isLoading && entries.isEmpty && loadError == nil {
                ContentUnavailableView(localized("此目錄沒有內容"), systemImage: "books.vertical")
            }
        }
        .navigationTitle(route.title)
        .toolbarTitleDisplayMode(.large)
        .searchableWhen(searchDescURL != nil, text: $searchText, prompt: localized("搜尋此目錄"))
        .onSubmit(of: .search) { Task { await runSearch() } }
        .task(id: route.url) { await loadInitial() }
    }

    // MARK: Rows

    @ViewBuilder
    private func row(for entry: OPDSEntry) -> some View {
        if entry.isNavigation, let dest = entry.navigationURL {
            NavigationLink(value: OPDSFeedRoute(catalogID: route.catalogID, url: dest.absoluteString, title: entry.title)) {
                Label(entry.title, systemImage: "folder.fill")
                    .foregroundColor(DSColor.textPrimary)
            }
        } else {
            Button {
                importEntry(entry)
            } label: {
                HStack(spacing: 12) {
                    BookCoverImage(
                        coverURL: entry.displayCoverURL?.absoluteString ?? "",
                        title: entry.title,
                        sourceHeaders: client.coverHeaders
                    )
                    .frame(width: 44, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title).foregroundColor(DSColor.textPrimary).lineLimit(2)
                        if let author = entry.author {
                            Text(author).font(DSFont.caption).foregroundColor(DSColor.textSecondary).lineLimit(1)
                        }
                        if entry.bestAcquisition == nil {
                            Text(localized("此格式暫不支援匯入"))
                                .font(DSFont.caption).foregroundColor(DSColor.textSecondary)
                        }
                    }
                    Spacer()
                    trailingStatus(for: entry)
                }
            }
            .disabled(entry.bestAcquisition == nil || importingID != nil)
        }
    }

    @ViewBuilder
    private func trailingStatus(for entry: OPDSEntry) -> some View {
        if importingID == entry.id {
            ProgressView()
        } else if importedIDs.contains(entry.id) {
            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
        } else if failedID == entry.id {
            Image(systemName: "exclamationmark.circle.fill").foregroundColor(.red)
        } else if entry.bestAcquisition != nil {
            Image(systemName: "arrow.down.circle").foregroundColor(DSColor.accent)
        }
    }

    private var loadMoreRow: some View {
        Button {
            Task { await loadMore() }
        } label: {
            HStack {
                Spacer()
                if isLoadingMore {
                    ProgressView()
                } else {
                    Text(localized("載入更多")).foregroundColor(DSColor.accent)
                }
                Spacer()
            }
        }
        .disabled(isLoadingMore)
    }

    // MARK: Loading

    private func loadInitial() async {
        await MainActor.run { isLoading = true; loadError = nil }
        guard let url = URL(string: route.url) else {
            await MainActor.run { loadError = OPDSError.invalidURL.errorDescription; isLoading = false }
            return
        }
        do {
            let feed = try await client.fetchFeed(url)
            await MainActor.run {
                self.entries = feed.entries
                self.nextPageURL = feed.nextPageURL
                self.searchDescURL = feed.searchDescriptionURL
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.loadError = (error as? OPDSError)?.errorDescription ?? error.localizedDescription
                self.isLoading = false
            }
        }
    }

    private func loadMore() async {
        guard let next = nextPageURL, !isLoadingMore else { return }
        await MainActor.run { isLoadingMore = true }
        do {
            let feed = try await client.fetchFeed(next)
            await MainActor.run {
                self.entries.append(contentsOf: feed.entries)
                self.nextPageURL = feed.nextPageURL
                self.isLoadingMore = false
            }
        } catch {
            await MainActor.run { self.isLoadingMore = false }
        }
    }

    private func runSearch() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { await loadInitial(); return }
        guard let descURL = searchDescURL else { return }
        await MainActor.run { isLoading = true; loadError = nil }
        do {
            guard let searchURL = try await client.searchFeedURL(descriptionURL: descURL, query: query) else {
                await MainActor.run { loadError = localized("此目錄不支援搜尋"); isLoading = false }
                return
            }
            let feed = try await client.fetchFeed(searchURL)
            await MainActor.run {
                self.entries = feed.entries
                self.nextPageURL = feed.nextPageURL
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.loadError = (error as? OPDSError)?.errorDescription ?? error.localizedDescription
                self.isLoading = false
            }
        }
    }

    // MARK: Import

    private func importEntry(_ entry: OPDSEntry) {
        guard let acquisition = entry.bestAcquisition, importingID == nil else { return }
        importingID = entry.id
        failedID = nil
        Task { @MainActor in
            do {
                let tempURL = try await client.download(acquisition)
                let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
                switch acquisition.importExtension {
                case "epub":
                    try await store.importEpub(url: tempURL, title: title, author: entry.author)
                case "md":
                    try store.importMarkdown(url: tempURL, title: title)
                default:
                    try store.importTxt(url: tempURL, title: title)
                }
                try? FileManager.default.removeItem(at: tempURL)
                importedIDs.insert(entry.id)
                importingID = nil
            } catch {
                failedID = entry.id
                importingID = nil
            }
        }
    }
}

// MARK: - Conditional searchable

private extension View {
    /// Applies `.searchable` only when `enabled`. The toggle happens once after the
    /// feed loads (search support is discovered then), which is acceptable churn.
    @ViewBuilder
    func searchableWhen(_ enabled: Bool, text: Binding<String>, prompt: String) -> some View {
        if enabled {
            self.searchable(text: text, prompt: prompt)
        } else {
            self
        }
    }
}
