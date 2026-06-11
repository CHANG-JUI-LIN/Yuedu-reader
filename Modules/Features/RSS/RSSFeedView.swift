import SwiftUI
import SafariServices

// MARK: - SafariView

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

// MARK: - RSSSmartFeedView

struct RSSSmartFeedView: View {
    let kind: RSSSmartFeedKind

    @StateObject private var store = RSSStore.shared

    @State private var filter: RSSArticleTimelineFilter = .all
    @State private var searchText = ""
    @State private var selectedArticleID: String?

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private var articles: [RSSArticleRecord] {
        filter.apply(to: store.articles(for: kind), query: searchText)
    }

    private var unreadCount: Int {
        store.unreadCount(for: kind)
    }

    var body: some View {
        Group {
            if articles.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: kind.systemImage)
                        .font(.largeTitle)
                        .foregroundColor(DSColor.textSecondary)

                    Text(emptyMessage)
                        .foregroundColor(DSColor.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(articles) { article in
                        if let source = store.source(id: article.sourceId) {
                            Button {
                                store.markRead(articleId: article.id, isRead: true)
                                selectedArticleID = article.id
                            } label: {
                                RSSArticleRow(
                                    source: source,
                                    article: article,
                                    timeFormatter: timeFormatter
                                )
                            }
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .swipeActions(edge: .leading) {
                                Button {
                                    store.toggleFavorite(articleId: article.id)
                                } label: {
                                    Label(
                                        article.isFavorite ? localized("取消收藏") : localized("收藏"),
                                        systemImage: article.isFavorite ? "star.slash" : "star"
                                    )
                                }
                                .tint(.yellow)
                            }
                            .swipeActions(edge: .trailing) {
                                Button {
                                    store.markRead(articleId: article.id, isRead: !article.isRead)
                                } label: {
                                    Label(
                                        article.isRead ? localized("標為未讀") : localized("標為已讀"),
                                        systemImage: article.isRead ? "envelope.badge" : "envelope.open"
                                    )
                                }
                                .tint(.blue)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .toolbarTitleDisplayMode(.inlineLarge)
        .toolbar(.hidden, for: .tabBar)
        .navigationDestination(item: $selectedArticleID) { articleID in
            RSSArticleReaderView(articleID: articleID)
        }
        .rssFeedSearchBarIfAvailable(searchText: $searchText)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(kind.title)
                        .font(.headline.weight(.semibold))
                        .foregroundColor(DSColor.textPrimary)
                        .lineLimit(1)

                    Text("\(unreadCount) \(localized("未讀"))")
                        .font(.caption)
                        .foregroundColor(DSColor.textSecondary)
                }
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Picker("", selection: $filter) {
                        ForEach(RSSArticleTimelineFilter.allCases) { filter in
                            Label(filter.title, systemImage: filter.systemImage)
                                .tag(filter)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()

                    Divider()

                    Button {
                        store.markAllRead(smartFeed: kind)
                    } label: {
                        Label(localized("標記全部已讀"), systemImage: "checkmark.circle")
                    }
                    .disabled(unreadCount == 0)
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(DSFont.toolbarIcon)
                }
                .foregroundColor(DSColor.textPrimary)
                .id("\(Locale.autoupdatingCurrent.identifier)_rss_smart_filter")
            }
        }
    }

    private var emptyMessage: String {
        switch filter {
        case .all:
            switch kind {
            case .today:
                return localized("沒有今日文章")
            case .allUnread:
                return localized("沒有未讀文章")
            case .starred:
                return localized("沒有加星文章")
            }
        case .unread:
            return localized("沒有未讀文章")
        case .read:
            return localized("沒有已讀文章")
        case .favorite:
            return localized("沒有收藏文章")
        }
    }
}

// MARK: - RSSFeedView

struct RSSFeedView: View {
    let source: RSSSource

    @StateObject private var fetcher = RSSFetcher()
    @StateObject private var store = RSSStore.shared

    @State private var filter: RSSArticleTimelineFilter = .all
    @State private var searchText = ""
    @State private var selectedArticleID: String?

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private var currentSource: RSSSource {
        store.sources.first { $0.id == source.id } ?? source
    }

    private var articles: [RSSArticleRecord] {
        filter.apply(to: store.articles(for: currentSource.id), query: searchText)
    }

    private var unreadCount: Int {
        store.unreadCount(for: currentSource.id)
    }
    var body: some View {
        List {
            if fetcher.isLoading && articles.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: 300)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            } else if let errorMsg = fetcher.error, articles.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(DSColor.textSecondary)

                    Text(errorMsg)
                        .foregroundColor(DSColor.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .frame(maxWidth: .infinity, minHeight: 300)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            } else if articles.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "newspaper")
                        .font(.largeTitle)
                        .foregroundColor(DSColor.textSecondary)

                    Text(emptyMessage)
                        .foregroundColor(DSColor.textSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: 300)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            } else {
                ForEach(articles) { article in
                    Button {
                        store.markRead(articleId: article.id, isRead: true)
                        selectedArticleID = article.id
                    } label: {
                        RSSArticleRow(
                            source: currentSource,
                            article: article,
                            timeFormatter: timeFormatter
                        )
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .swipeActions(edge: .leading) {
                        Button {
                            store.toggleFavorite(articleId: article.id)
                        } label: {
                            Label(
                                article.isFavorite ? localized("取消收藏") : localized("收藏"),
                                systemImage: article.isFavorite ? "star.slash" : "star"
                            )
                        }
                        .tint(.yellow)
                    }
                    .swipeActions(edge: .trailing) {
                        Button {
                            store.markRead(articleId: article.id, isRead: !article.isRead)
                        } label: {
                            Label(
                                article.isRead ? localized("標為未讀") : localized("標為已讀"),
                                systemImage: article.isRead ? "envelope.badge" : "envelope.open"
                            )
                        }
                        .tint(.blue)
                    }
                }
            }
        }
        .listStyle(.plain)
        .refreshable {
            await refresh()
        }
        .toolbarTitleDisplayMode(.inlineLarge)
        .toolbar(.hidden, for: .tabBar)
        .navigationDestination(item: $selectedArticleID) { articleID in
            RSSArticleReaderView(articleID: articleID)
        }
        .rssFeedSearchBarIfAvailable(searchText: $searchText)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(currentSource.name)
                        .font(.headline.weight(.semibold))
                        .foregroundColor(DSColor.textPrimary)
                        .lineLimit(1)

                    Text("\(unreadCount) \(localized("未讀"))")
                        .font(.caption)
                        .foregroundColor(DSColor.textSecondary)
                }
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Picker("", selection: $filter) {
                        ForEach(RSSArticleTimelineFilter.allCases) { filter in
                            Label(filter.title, systemImage: filter.systemImage)
                                .tag(filter)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()

                    Divider()

                    Button {
                        Task { await refresh() }
                    } label: {
                        Label(localized("刷新訂閱"), systemImage: "arrow.clockwise")
                    }
                    .disabled(fetcher.isLoading)
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(DSFont.toolbarIcon)
                }
                .foregroundColor(DSColor.textPrimary)
                .id("\(Locale.autoupdatingCurrent.identifier)_rss_filter")
            }
        }
        .task(id: source.id) {
            if store.articles(for: source.id).isEmpty {
                await refresh()
            }
        }
    }

    private var emptyMessage: String {
        switch filter {
        case .all:
            return localized("目前沒有文章")
        case .unread:
            return localized("沒有未讀文章")
        case .read:
            return localized("沒有已讀文章")
        case .favorite:
            return localized("沒有收藏文章")
        }
    }

    private func refresh() async {
        await fetcher.fetchItems(from: currentSource, metadata: store.feedMetadata(for: currentSource.id))
        if fetcher.error == nil {
            store.applyResolvedFeedURL(fetcher.resolvedFeedURL, homepageURL: fetcher.resolvedHomepageURL, to: currentSource.id)
            let notificationSource = store.source(id: currentSource.id) ?? currentSource
            let newArticles: [RSSArticleRecord]
            if let response = fetcher.response {
                newArticles = store.applyFeedResponse(response, for: currentSource.id)
            } else {
                newArticles = store.mergeFetchedItems(fetcher.items, for: currentSource.id)
            }
            RSSNotificationManager.shared.notifyNewArticles(newArticles, source: notificationSource)
        }
    }
}

enum RSSArticleTimelineFilter: String, CaseIterable, Identifiable {
    case all
    case unread
    case read
    case favorite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return localized("全部文章")
        case .unread:
            return localized("未讀文章")
        case .read:
            return localized("已讀文章")
        case .favorite:
            return localized("收藏文章")
        }
    }

    var systemImage: String {
        switch self {
        case .all:
            return "tray.full"
        case .unread:
            return "circle.fill"
        case .read:
            return "checkmark.circle"
        case .favorite:
            return "star.fill"
        }
    }

    func apply(to records: [RSSArticleRecord], query: String = "") -> [RSSArticleRecord] {
        let filtered: [RSSArticleRecord]
        switch self {
        case .all:
            filtered = records
        case .unread:
            filtered = records.filter { !$0.isRead }
        case .read:
            filtered = records.filter(\.isRead)
        case .favorite:
            filtered = records.filter(\.isFavorite)
        }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return filtered }

        return filtered.filter { article in
            article.title.localizedCaseInsensitiveContains(trimmedQuery)
                || article.summary.localizedCaseInsensitiveContains(trimmedQuery)
                || (article.author?.localizedCaseInsensitiveContains(trimmedQuery) ?? false)
        }
    }
}

private struct RSSArticleRow: View {
    let source: RSSSource
    let article: RSSArticleRecord
    let timeFormatter: DateFormatter

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                statusIndicator
                    .frame(width: 12, height: 12)
                    .padding(.top, 4)

                VStack(alignment: .leading, spacing: 6) {
                    Text(article.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? localized("暫無資料") : article.title.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundColor(DSColor.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    if !article.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(article.summary.trimmingCharacters(in: .whitespacesAndNewlines))
                            .font(.subheadline)
                            .foregroundColor(DSColor.textSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }

                    HStack(alignment: .center, spacing: 6) {
                        RSSFaviconView(source: source, size: 16)
                        
                        Text(metadataText)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(DSColor.textSecondary)
                            .lineLimit(1)
                        
                        if let pubDate = article.pubDate {
                            Text("•")
                                .font(.caption)
                                .foregroundColor(DSColor.textSecondary)
                            Text(timeFormatter.string(from: pubDate))
                                .font(.caption)
                                .foregroundColor(DSColor.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
                if let imageURL = article.imageURL, let url = URL(string: imageURL)?.upgradedToHTTPS() {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else if phase.error != nil {
                            Color.clear
                        } else {
                            Color.gray.opacity(0.1)
                        }
                    }
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .padding(.leading, 4)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            
            Divider()
                .padding(.leading, 38)
                .opacity(0.5)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if article.isFavorite {
            Image(systemName: "star.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.yellow)
        } else if !article.isRead {
            Circle()
                .fill(DSColor.accent)
        } else {
            Color.clear
        }
    }

    private var metadataText: String {
        if let author = article.author?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty {
            return "\(source.name) - \(author)"
        }
        return source.name
    }
}


private struct RSSFeedSearchBarIOS18: ViewModifier {
    @Binding var searchText: String

    func body(content: Content) -> some View {
        content
            .searchable(
                text: $searchText,
                placement: .toolbar,
                prompt: localized("搜尋文章")
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
    }
}

@available(iOS 26.0, *)
private struct RSSFeedSearchBar: ViewModifier {
    @Binding var searchText: String

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        content
            .searchable(
                text: $searchText,
                placement: .toolbar,
                prompt: localized("搜尋文章")
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .toolbar {
                DefaultToolbarItem(
                    kind: .search,
                    placement: .bottomBar
                )
            }
        #else
        content
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: localized("搜尋文章")
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #endif
    }
}

private extension View {
    @ViewBuilder
    func rssFeedSearchBarIfAvailable(searchText: Binding<String>) -> some View {
        if #available(iOS 26.0, *) {
            self.modifier(RSSFeedSearchBar(searchText: searchText))
        } else {
            self.modifier(RSSFeedSearchBarIOS18(searchText: searchText))
        }
    }
}

@available(iOS 26.0, *)
private extension View {
    func rssFeedSearchBar(searchText: Binding<String>) -> some View {
        modifier(RSSFeedSearchBar(searchText: searchText))
    }
}
// MARK: - URL Identifiable conformance for sheet(item:)

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

#Preview("BBC RSS") {
    NavigationStack {
        RSSFeedView(source: RSSSource(
            name: "BBC",
            url: "https://feedx.net/rss/bbc.xml",
            sortOrder: 0
        ))
    }
}

#Preview("RSS Timeline Rows") {
    let source = RSSSource(
        id: "source-1",
        name: "Daring Fireball",
        url: "https://daringfireball.net/feeds/main",
        sortOrder: 0
    )
    let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()
    let now = Date()
    return List {
        RSSArticleRow(
            source: source,
            article: RSSArticleRecord(item: RSSItem(
                id: "1",
                title: "Broadcast Booths Around Baseball Tip Their Caps to John Sterling",
                link: "https://example.com/1",
                pubDate: now,
                description: "Daring Fireball",
                author: nil,
                sourceId: source.id
            )),
            timeFormatter: formatter
        )
        .listRowInsets(EdgeInsets())

        RSSArticleRow(
            source: source,
            article: RSSArticleRecord(
                item: RSSItem(
                    id: "2",
                    title: "A supercut of context-free intertitles from Adam Curtis movies",
                    link: "https://example.com/2",
                    pubDate: now,
                    description: "kottke.org",
                    author: nil,
                    sourceId: source.id
                ),
                status: RSSArticleStatus(articleId: "2", isRead: true)
            ),
            timeFormatter: formatter
        )
        .listRowInsets(EdgeInsets())

        RSSArticleRow(
            source: source,
            article: RSSArticleRecord(
                item: RSSItem(
                    id: "3",
                    title: "SpaceX data center follow-up",
                    link: "https://example.com/3",
                    pubDate: now,
                    description: "Stephen Hackett blogs about the Anthropic data center follow-up.",
                    author: "Manton Reece",
                    sourceId: source.id
                ),
                status: RSSArticleStatus(articleId: "3", isFavorite: true)
            ),
            timeFormatter: formatter
        )
        .listRowInsets(EdgeInsets())
    }
    .listStyle(.plain)
}
