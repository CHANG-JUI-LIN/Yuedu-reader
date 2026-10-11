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
            },
            authorNames: entry.authorNames.prefix(20).map { String($0.prefix(500)) },
            language: entry.language,
            identifiers: Array(entry.identifiers.prefix(10))
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

/// A Gutenberg book's page in the store's card carousel (`PublicLibraryBookSheet`), kept while
/// the carousel is off (Phase 5 plan, decision 27). Every other library item opens 作品詳情,
/// which replaced this view's pushed list page (decision 28).
struct RemoteLibraryBookDetailView: View {
    private let authors: [GutenbergAuthor]
    private let artworkTitle: String?
    private let artworkAuthor: String?
    /// The store card's cover, so the hero is the cover the card grew from.
    private let artworkCoverURL: URL?
    private let item: RemoteLibraryItem
    @Environment(\.appDependencies) private var dependencies
    @EnvironmentObject private var store: BookStore
    @State private var selectedFormatID: String
    @StateObject private var actions = RemoteLibraryActionModel()
    @State private var introExpanded = false
    /// Whether the copy's offline file exists, checked when the copy or its file changes
    /// rather than on every body evaluation (unified library 2c).
    @State private var offlineFileExists = false
    @Environment(\.publicLibrarySheet) private var sheet

    init(item: RemoteLibraryItem, authors: [GutenbergAuthor] = [],
         artworkTitle: String? = nil, artworkAuthor: String? = nil, artworkCoverURL: URL? = nil) {
        self.authors = authors
        self.artworkTitle = artworkTitle
        self.artworkAuthor = artworkAuthor
        self.artworkCoverURL = artworkCoverURL
        self.item = item
        _selectedFormatID = State(initialValue: RemoteLibraryBrowsePresentation.preferredFormat(in: item)?.id ?? "")
    }

    private var selectedFormat: RemoteLibraryFormat? { item.formats.first { $0.id == selectedFormatID } }
    private var book: ReadingBook? {
        selectedFormat.flatMap { dependencies.remoteLibrary.book(for: item, format: $0, store: store) }
    }
    /// The copy comes from `CopyLookup`, so whether it is on the shelf is its own field.
    private var isOnShelf: Bool { book?.isInBookshelf ?? false }
    private var isOffline: Bool { book != nil && offlineFileExists }
    private var offlineProbe: String { "\(book?.id.uuidString ?? "")|\(book?.remoteSource?.offlineFilename ?? "")" }
    private var action: RemoteLibraryActionModel.Action? { actions.action }
    private var message: String? { actions.message }
    private var actionFailed: Bool { actions.failed }
    private var canAct: Bool { selectedFormat?.isSupported == true && action == nil }

    var body: some View {
        storefrontBody
            .onChange(of: selectedFormatID) { _, _ in actions.clearMessage() }
            .task(id: offlineProbe) {
                offlineFileExists = book.map { dependencies.remoteLibrary.hasOfflineCopy($0) } ?? false
            }
            .onDisappear { actions.cancelForDisappearance() }
    }

    private var readAction: BookDetailAction {
        BookDetailAction(title: localized(book?.lastOpenedDate == nil ? "開始閱讀" : "繼續閱讀"), systemImage: "book",
                         isBusy: action == .read, isEnabled: canAct, action: { begin(.read) })
    }

    private var storefrontBody: some View {
        BookDetailScaffold(title: item.title, compactAction: readAction) {
            BookDetailHero(artworkShape: .book,
                cover: PublicLibraryCoverArtwork(title: artworkTitle ?? item.title, author: artworkAuthor ?? item.author,
                                                 coverURL: artworkCoverURL),
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
        } actions: {
            Button { begin(.addToShelf) } label: {
                BookDetailCardIcon(title: localized(isOnShelf ? "已加入書架" : "加入書架"), systemImage: isOnShelf ? "checkmark" : "plus")
            }.disabled(!canAct || isOnShelf)
            Menu {
                Picker(localized("格式"), selection: $selectedFormatID) {
                    ForEach(item.formats) { format in Text(formatLabel(format)).tag(format.id) }
                }.disabled(action != nil)
                if let url = item.alternateURL { ShareLink(item: url) }
            } label: {
                BookDetailCardIcon(title: localized("書庫操作"), systemImage: "ellipsis")
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

    private func begin(_ selectedAction: RemoteLibraryActionModel.Action) {
        guard canAct, let format = selectedFormat else { return }
        actions.begin(selectedAction, item: item, format: format, service: dependencies.remoteLibrary, store: store) { id in
            sheet?.openReader(id)
        }
    }

    private func cancelAction() {
        actions.cancel()
    }
}

#Preview {
    NavigationStack {
        RemoteLibraryBookDetailView(item: RemoteLibraryItem(
            id: "preview", connectionID: PublicLibraryID.gutenberg.rawValue, title: "紅樓夢",
            author: "曹雪芹", summary: nil, coverURL: nil,
            formats: [RemoteLibraryFormat(url: URL(string: "https://example.com/book.epub")!,
                                          fileExtension: "epub", mimeType: "application/epub+zip", size: nil)]
        ))
    }
    .environmentObject(BookStore())
}
