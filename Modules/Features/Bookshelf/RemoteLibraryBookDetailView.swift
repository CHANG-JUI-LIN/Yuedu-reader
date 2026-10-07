import SwiftUI

/// A selected item is an immutable snapshot, including bounded display metadata.
/// It never re-reads a changing OPDS result list while constructing a destination.
struct RemoteLibraryBookRoute: Hashable {
    let item: RemoteLibraryItem

    init(item: RemoteLibraryItem) { self.item = item }

    init(entry: OPDSEntry, connectionID: String) {
        item = RemoteLibraryItem(
            id: entry.id,
            connectionID: connectionID,
            title: String(entry.title.prefix(500)),
            author: entry.author.map { String($0.prefix(500)) },
            summary: entry.summary.map { OnlineBookDetailPresentationPolicy.sanitizeIntro($0, indentParagraphs: false) },
            coverURL: entry.coverURL ?? entry.thumbnailURL,
            alternateURL: entry.alternateURL,
            formats: entry.acquisitions.sorted { $0.preference < $1.preference }.map {
                RemoteLibraryFormat(url: $0.url, fileExtension: $0.importExtension ?? $0.url.pathExtension,
                                    mimeType: $0.type, size: $0.size)
            }
        )
    }

    init(entry: WebDAVBrowseClient.Entry, connectionID: String) {
        item = RemoteLibraryItem(
            id: entry.id,
            connectionID: connectionID,
            title: String((entry.name as NSString).deletingPathExtension.prefix(500)),
            author: nil,
            summary: nil,
            coverURL: nil,
            formats: [RemoteLibraryFormat(
                url: entry.url,
                fileExtension: entry.fileExtension == "markdown" ? "md" : entry.fileExtension,
                mimeType: RemoteLibraryBrowsePresentation.mimeType(for: entry.fileExtension),
                size: entry.size > 0 ? entry.size : nil
            )]
        )
    }
}

enum RemoteLibraryBrowsePresentation {
    static func filtered(_ entries: [WebDAVBrowseClient.Entry], query: String) -> [WebDAVBrowseClient.Entry] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return entries }
        return entries.filter { $0.name.localizedStandardContains(term) }
    }

    static func mimeType(for fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "epub": "application/epub+zip"
        case "pdf": "application/pdf"
        case "txt": "text/plain"
        case "md", "markdown": "text/markdown"
        default: "application/octet-stream"
        }
    }

    static func preferredFormat(in item: RemoteLibraryItem) -> RemoteLibraryFormat? {
        let order = ["epub": 0, "pdf": 1, "txt": 2, "md": 3]
        return item.formats.filter(\.isSupported).min {
            (order[$0.fileExtension] ?? 9) < (order[$1.fileExtension] ?? 9)
        } ?? item.formats.first
    }
}

struct RemoteLibraryBookDetailView: View {
    private let storefront: Bool
    private let authors: [GutenbergAuthor]
    private let artworkTitle: String?
    private let artworkAuthor: String?
    @State private var item: RemoteLibraryItem
    @State private var writeCapabilities: RemoteLibraryWriteCapabilities?
    @Environment(\.appDependencies) private var dependencies
    @EnvironmentObject private var store: BookStore
    @ObservedObject private var catalogStore = RemoteLibraryConnectionStore.shared
    @State private var selectedFormatID: String
    @State private var action: RemoteLibraryDetailAction?
    @State private var actionTask: Task<Void, Never>?
    @State private var message: String?
    @State private var actionFailed = false
    @State private var readerBookID: UUID?
    @State private var introExpanded = false
    @Environment(\.publicLibrarySheet) private var sheet

    init(item: RemoteLibraryItem, storefront: Bool = false, authors: [GutenbergAuthor] = [],
         artworkTitle: String? = nil, artworkAuthor: String? = nil) {
        self.storefront = storefront
        self.authors = authors
        self.artworkTitle = artworkTitle
        self.artworkAuthor = artworkAuthor
        _item = State(initialValue: item)
        _selectedFormatID = State(initialValue: RemoteLibraryBrowsePresentation.preferredFormat(in: item)?.id ?? "")
    }

    private var selectedFormat: RemoteLibraryFormat? { item.formats.first { $0.id == selectedFormatID } }
    private var book: ReadingBook? {
        selectedFormat.flatMap { dependencies.remoteLibrary.book(for: item, format: $0, store: store) }
    }
    private var isOnShelf: Bool { book.map { book in store.books.contains { $0.id == book.id } } ?? false }
    private var isOffline: Bool { book.map { dependencies.remoteLibrary.hasOfflineCopy($0) } ?? false }
    private var canAct: Bool { selectedFormat?.isSupported == true && action == nil }
    private var connection: RemoteLibraryConnection? {
        catalogStore.connection(id: item.connectionID)
    }

    var body: some View {
        Group {
            if storefront { storefrontBody }
            else {
                libraryList.navigationDestination(item: $readerBookID) { id in
                    BookReaderView(bookId: id).environmentObject(store)
                        .environment(\.readerNavigator, nil)
                        .environment(\.readerUsesParentNavigationStack, true)
                        .navigationBarBackButtonHidden(true)
                        .reservingNavigationBackSwipe()
                }
            }
        }
        .onChange(of: selectedFormatID) { _, _ in message = nil }
        .onDisappear { actionTask?.cancel() }
    }

    private var libraryList: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: DSSpacing.lg) {
                    BookCoverImage(
                        coverURL: item.coverURL?.absoluteString ?? "",
                        title: item.title,
                        author: item.author,
                        session: connection.map { RemoteLibraryConnectionStore.shared.httpClient(for: $0).session }
                    )
                    .frame(width: DSLayout.searchResultCoverWidth, height: DSLayout.searchResultCoverHeight)
                    .clipShape(RoundedRectangle(cornerRadius: DSRadius.sm))
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: DSSpacing.sm) {
                        Text(item.title).font(DSFont.headline).foregroundStyle(DSColor.textPrimary)
                        if let author = item.author, !author.isEmpty {
                            Text(author).font(DSFont.subheadline).foregroundStyle(DSColor.textSecondary)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                if let size = selectedFormat?.size, size > 0 {
                    ThemedLabeledContent(localized("檔案大小"), value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                }
            }
            .interfaceSectionSurface()
            Section {
                Picker(localized("格式"), selection: $selectedFormatID) {
                    ForEach(item.formats) { format in
                        Text(formatLabel(format)).tag(format.id)
                    }
                }
                .disabled(action != nil)
                Button { begin(.read) } label: {
                    Label(localized(book?.lastOpenedDate == nil ? "開始閱讀" : "繼續閱讀"), systemImage: "book")
                }
                .disabled(!canAct)
                Button { begin(.addToShelf) } label: {
                    Label(localized(isOnShelf ? "已加入書架" : "加入書架"), systemImage: isOnShelf ? "checkmark.circle" : "plus")
                }
                .disabled(!canAct || isOnShelf)
                Button { begin(.download) } label: {
                    Label(localized(isOffline ? "已下載" : "下載供離線閱讀"), systemImage: isOffline ? "checkmark.circle" : "arrow.down.circle")
                }
                .disabled(!canAct || isOffline)
            } footer: {
                Text(localized("閱讀不會自動加入書架；加入書架不會下載整本書。"))
                    .dsSectionFooter()
            }
            .interfaceSectionSurface()
            if let capabilities = writeCapabilities, capabilities.canEditMetadata || capabilities.canMove {
                Section {
                    NavigationLink {
                        RemoteLibraryBookEditor(item: item, capabilities: capabilities) { updated in
                            item = updated
                            selectedFormatID = RemoteLibraryBrowsePresentation.preferredFormat(in: updated)?.id ?? ""
                        }
                    } label: {
                        SettingsRowLabel(localized("編輯遠端資料"), systemImage: "pencil")
                    }.disabled(action != nil)
                }.interfaceSectionSurface()
            }
            if connection?.syncProgress == true, let book, selectedFormat?.fileExtension == "epub" {
                CalibreProgressStatusView(bookID: book.id, service: dependencies.calibreProgress)
            }
            if let action {
                Section {
                    ProgressView(action.progressTitle)
                    Button(localized("取消"), role: .cancel) { cancelAction() }
                }
                .interfaceSectionSurface()
            }
            if let message {
                Section {
                    Label(message, systemImage: actionFailed ? "exclamationmark.triangle" : "checkmark.circle")
                        .foregroundStyle(actionFailed ? DSColor.destructive : DSColor.textSecondary)
                }
                .interfaceSectionSurface()
            }
            if selectedFormat?.isSupported != true {
                Section {
                    Label(localized("此格式暫不支援閱讀"), systemImage: "doc.badge.ellipsis")
                        .foregroundStyle(DSColor.textSecondary)
                }
                .interfaceSectionSurface()
            }
            if let url = item.alternateURL {
                Section {
                    Link(localized("在書庫網站查看"), destination: url)
                }.interfaceSectionSurface()
            }
            if let summary = item.summary, !summary.isEmpty {
                Section(localized("簡介")) {
                    Text(summary).font(DSFont.body).foregroundStyle(DSColor.textPrimary)
                }
                .interfaceSectionSurface()
            }
        }
        .softScrollEdges()
        .task(id: item.connectionID) {
            do {
                writeCapabilities = try await dependencies.remoteLibraryWriting.capabilities(connectionID: item.connectionID, directoryURL: nil)
            } catch {
                // Capability discovery cannot block reading. Explicit management
                // surfaces expose its error and retry action.
                writeCapabilities = nil
            }
        }
        .navigationTitle(localized("書籍詳情"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .bookshelf)
    }

    private var readAction: BookDetailAction {
        BookDetailAction(title: localized(book?.lastOpenedDate == nil ? "開始閱讀" : "繼續閱讀"), systemImage: "book",
                         isBusy: action == .read, isEnabled: canAct, action: { begin(.read) })
    }

    private var storefrontBody: some View {
        BookDetailScaffold(title: item.title, compactAction: readAction) {
            BookDetailHero(artworkShape: .book,
                cover: GeneratedBookCover(title: artworkTitle ?? item.title, author: artworkAuthor ?? item.author),
                title: item.title, author: item.author ?? "", meta: localized("Project Gutenberg"),
                primary: readAction,
                secondary: BookDetailAction(title: localized(isOffline ? "已下載" : "下載"),
                    systemImage: isOffline ? "checkmark.circle" : "arrow.down.circle",
                    isBusy: action == .download, isEnabled: canAct && !isOffline, action: { begin(.download) }),
                authorActions: authors.map { author in
                    BookDetailAuthorAction(id: author.id, name: author.name, action: { sheet?.openAuthor(.gutenberg(author)) })
                }, artworkHeight: sheet?.artworkHeight)
        } content: {
            Section {
                BookDetailInfoStrip(items: infoItems)
                if let action {
                    ProgressView(action.progressTitle)
                    Button(localized("取消"), role: .cancel) { cancelAction() }
                }
                if let message {
                    Text(message).font(DSFont.subheadline)
                        .foregroundStyle(actionFailed ? DSColor.destructive : DSColor.textSecondary)
                }
            } footer: {
                Text(localized("閱讀不會自動加入書架；加入書架不會下載整本書。"))
                    .dsSectionFooter().padding(.horizontal, DSSpacing.lg)
            }
            if let summary = item.summary, !summary.isEmpty {
                BookDetailIntroSection(text: summary, isExpanded: $introExpanded)
            }
            if let url = item.alternateURL {
                Link(localized("在書庫網站查看"), destination: url)
                    .font(DSFont.subheadline).padding(.horizontal, DSSpacing.lg)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { begin(.addToShelf) } label: {
                    Label(localized(isOnShelf ? "已加入書架" : "加入書架"), systemImage: isOnShelf ? "checkmark" : "plus")
                        .labelStyle(.iconOnly)
                }.disabled(!canAct || isOnShelf)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker(localized("格式"), selection: $selectedFormatID) {
                        ForEach(item.formats) { format in Text(formatLabel(format)).tag(format.id) }
                    }.disabled(action != nil)
                    if let url = item.alternateURL { ShareLink(item: url) }
                } label: {
                    Label(localized("書庫操作"), systemImage: "ellipsis").labelStyle(.iconOnly)
                }
            }
        }
    }

    private var infoItems: [BookDetailInfoItem] {
        var result = [BookDetailInfoItem(id: "format", label: localized("格式"), value: selectedFormat?.displayName ?? "")]
        if let size = selectedFormat?.size, size > 0 {
            result.append(BookDetailInfoItem(id: "size", label: localized("檔案大小"),
                value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))
        }
        return result
    }

    private func formatLabel(_ format: RemoteLibraryFormat) -> String {
        let name = format.displayName.isEmpty ? String(format.mimeType.prefix(120)) : format.displayName
        return format.isSupported ? name : name + " · " + localized("不支援")
    }

    private func begin(_ selectedAction: RemoteLibraryDetailAction) {
        guard canAct, let format = selectedFormat else { return }
        action = selectedAction
        message = nil
        actionFailed = false
        actionTask = Task { @MainActor in
            do {
                switch selectedAction {
                case .read:
                    let result = try await dependencies.remoteLibrary.read(item: item, format: format, store: store)
                    try Task.checkCancellation()
                    if storefront { sheet?.openReader(result.id) }
                    else { readerBookID = result.id }
                case .addToShelf:
                    _ = try dependencies.remoteLibrary.addToShelf(item: item, format: format, store: store)
                    message = localized("已加入書架")
                case .download:
                    _ = try await dependencies.remoteLibrary.downloadOffline(item: item, format: format, store: store)
                    try Task.checkCancellation()
                    message = localized("下載完成")
                }
            } catch {
                if Task.isCancelled {
                    message = localized("已取消")
                } else {
                    actionFailed = true
                    message = error.localizedDescription
                }
            }
            action = nil
            if let message { UIAccessibility.post(notification: .announcement, argument: message) }
        }
    }

    private func cancelAction() {
        actionTask?.cancel()
        // Do not start another action until the cancelled service operation has
        // completed its cleanup and the task above clears the active operation.
        message = localized("正在取消")
    }
}

private enum RemoteLibraryDetailAction {
    case read, addToShelf, download

    var progressTitle: String {
        switch self {
        case .read: localized("正在開啟書籍")
        case .addToShelf: localized("加入書架")
        case .download: localized("正在下載書籍")
        }
    }
}

#Preview {
    NavigationStack {
        RemoteLibraryBookDetailView(item: RemoteLibraryItem(
            id: "preview", connectionID: "preview", title: localized("書籍詳情"),
            author: nil, summary: nil, coverURL: nil,
            formats: [RemoteLibraryFormat(url: URL(string: "https://example.com/book.epub")!,
                                          fileExtension: "epub", mimeType: "application/epub+zip", size: nil)]
        ))
    }
    .environmentObject(BookStore())
}
