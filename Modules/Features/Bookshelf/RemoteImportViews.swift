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
    @StateObject private var model: WebDAVBrowseModel
    @State private var searchText = ""

    /// - Parameter list: replaces the server request, for previews.
    init(route: WebDAVDirectoryRoute, list: ((URL) async throws -> [WebDAVBrowseClient.Entry])? = nil) {
        self.route = route
        _model = StateObject(wrappedValue: WebDAVBrowseModel(route: route, list: list))
    }

    private var entries: [WebDAVBrowseClient.Entry] { model.entries }
    private var isLoading: Bool { model.isLoading }
    private var didLoad: Bool { model.didLoad }
    private var loadError: String? { model.loadError }

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
        .softScrollEdges()
        .overlay {
            if isLoading && entries.isEmpty && loadError == nil {
                ProgressView(localized("正在載入書庫"))
            } else if !isLoading && visibleEntries.isEmpty && loadError == nil {
                ContentUnavailableView {
                    UnavailableLabel(localized(searchText.isEmpty ? "此資料夾沒有內容" : "沒有搜尋結果"), systemImage: "folder")
                }
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
        await model.load()
    }
}

#Preview {
    WebDAVImportView().environmentObject(BookStore())
}

#Preview("WebDAV folder") {
    let folder = URL(string: "https://dav.example.com/books/")!
    NavigationStack {
        WebDAVDirectoryView(
            route: WebDAVDirectoryRoute(connectionID: "preview", url: folder, title: "Books"),
            list: { _ in
                [
                    .init(url: folder.appendingPathComponent("Fiction/"), name: "Fiction", isDirectory: true, size: 0),
                    .init(url: folder.appendingPathComponent("Essays/"), name: "Essays", isDirectory: true, size: 0),
                    .init(url: folder.appendingPathComponent("Three-Body.epub"), name: "Three-Body.epub",
                          isDirectory: false, size: 1_843_200),
                ]
            }
        )
    }
    .environmentObject(BookStore())
}

#Preview("WebDAV folder, failed") {
    NavigationStack {
        WebDAVDirectoryView(
            route: WebDAVDirectoryRoute(connectionID: "preview", url: URL(string: "https://dav.example.com/books/")!, title: "Books"),
            list: { _ in throw URLError(.cannotConnectToHost) }
        )
    }
    .environmentObject(BookStore())
}
