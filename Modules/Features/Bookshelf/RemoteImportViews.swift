import SwiftUI

struct WebDAVImportView: View {
    var body: some View { RemoteLibraryBrowserView(kind: .webDAV) }
}

struct WebDAVDirectoryRoute: Hashable {
    let connectionID: String
    let url: URL
    let title: String
}

struct WebDAVDirectoryView: View {
    let route: WebDAVDirectoryRoute
    @ObservedObject private var catalogStore = RemoteLibraryConnectionStore.shared
    @State private var entries: [WebDAVBrowseClient.Entry] = []
    @State private var isLoading = true
    @State private var didLoad = false
    @State private var loadError: String?
    @State private var searchText = ""

    private var connection: RemoteLibraryConnection? {
        catalogStore.connection(id: route.connectionID)
    }

    private var visibleEntries: [WebDAVBrowseClient.Entry] {
        RemoteLibraryBrowsePresentation.filtered(entries, query: searchText)
    }

    var body: some View {
        List {
            if let loadError {
                Section {
                    Label(loadError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(DSColor.textSecondary)
                    Button(localized("重試")) { Task { await load() } }
                }
                .interfaceSectionSurface()
            }
            Section {
                ForEach(visibleEntries) { entry in row(for: entry) }
            }
            .interfaceSectionSurface()
        }
        .overlay {
            if isLoading && entries.isEmpty && loadError == nil {
                ProgressView(localized("正在載入書庫"))
            } else if !isLoading && visibleEntries.isEmpty && loadError == nil {
                ContentUnavailableView(
                    localized(searchText.isEmpty ? "此資料夾沒有內容" : "沒有搜尋結果"),
                    systemImage: "folder"
                )
            }
        }
        .navigationTitle(route.title)
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .bookshelf)
        .searchable(text: $searchText, prompt: localized("搜尋目前資料夾"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let connection {
                    Menu {
                        NavigationLink(localized("管理遠端書庫")) {
                            RemoteLibraryManagementView(connectionID: connection.id, directoryURL: route.url)
                        }
                        NavigationLink {
                            RemoteLibraryConnectionEditor(kind: .webDAV, connection: connection)
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
            guard note.userInfo?["connectionID"] as? String == route.connectionID else { return }
            Task { await load() }
        }
        .task(id: route.url) {
            // A reader push must not reset the folder, search or list position.
            guard !didLoad else { return }
            await load()
        }
        .refreshable { await load() }
    }

    @ViewBuilder
    private func row(for entry: WebDAVBrowseClient.Entry) -> some View {
        if entry.isDirectory {
            NavigationLink(value: WebDAVDirectoryRoute(connectionID: route.connectionID, url: entry.url, title: entry.name)) {
                Label(entry.name, systemImage: "folder.fill").foregroundStyle(DSColor.textPrimary)
            }
        } else {
            NavigationLink(value: RemoteLibraryBookRoute(entry: entry, connectionID: route.connectionID)) {
                HStack(spacing: DSSpacing.md) {
                    Image(systemName: entry.fileExtension == "pdf" ? "doc.richtext" : "book.closed")
                        .foregroundStyle(entry.isImportableBook ? DSColor.accent : DSColor.textSecondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: DSSpacing.xs) {
                        Text(entry.name).foregroundStyle(DSColor.textPrimary)
                        if entry.size > 0 {
                            Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                                .font(DSFont.caption).foregroundStyle(DSColor.textSecondary)
                        }
                        if !entry.isImportableBook {
                            Text(localized("此格式暫不支援閱讀"))
                                .font(DSFont.caption).foregroundStyle(DSColor.textSecondary)
                        }
                    }
                }
            }
        }
    }

    private func load() async {
        isLoading = true
        loadError = nil
        guard let connection else {
            loadError = localized("書庫連線已移除，請重新加入伺服器。")
            isLoading = false
            return
        }
        do {
            let result = try await RemoteLibraryConnectionStore.shared.webDAVClient(for: connection).list(route.url)
            try Task.checkCancellation()
            entries = result
            didLoad = true
        } catch {
            guard !Task.isCancelled else { return }
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}

#Preview {
    WebDAVImportView().environmentObject(BookStore())
}
