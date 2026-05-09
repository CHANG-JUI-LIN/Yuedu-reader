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
        Group {
            if fetcher.isLoading && articles.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            } else if let errorMsg = fetcher.error, articles.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(DSColor.textSecondary)

                    Text(errorMsg)
                        .foregroundColor(DSColor.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    Button(localized("重試")) {
                        Task { await refresh() }
                    }
                    .foregroundColor(DSColor.accent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            } else if articles.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "newspaper")
                        .font(.largeTitle)
                        .foregroundColor(DSColor.textSecondary)

                    Text(emptyMessage)
                        .foregroundColor(DSColor.textSecondary)

                    Button(localized("重新載入")) {
                        Task { await refresh() }
                    }
                    .foregroundColor(DSColor.accent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            } else {
                List {
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
                .listStyle(.plain)
                .refreshable {
                    await refresh()
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .navigationDestination(item: $selectedArticleID) { articleID in
            RSSArticleReaderView(articleID: articleID)
        }
        .safeAreaInset(edge: .bottom) {
            RSSFeedSearchDock(searchText: $searchText)
                .padding(.horizontal, 26)
                .padding(.top, 8)
                .padding(.bottom, 12)
        }
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
            if let response = fetcher.response {
                store.applyFeedResponse(response, for: currentSource.id)
            } else {
                store.mergeFetchedItems(fetcher.items, for: currentSource.id)
            }
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
        HStack(alignment: .top, spacing: 8) {
            statusIndicator
                .frame(width: 16, height: 16)
                .padding(.top, 18)

            RSSFaviconView(source: source, size: 36)
                .padding(.top, 10)

            VStack(spacing: 0) {
                Divider()
                    .opacity(0.3)

                VStack(alignment: .leading, spacing: 4) {
                    articleContentText
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(metadataText)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if let pubDate = article.pubDate {
                            Text(timeFormatter.string(from: pubDate))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                    .font(.caption)
                    .foregroundColor(DSColor.textSecondary)
                }
                .padding(.top, 7)
                .padding(.trailing, 12)
                .padding(.bottom, 10)
            }
        }
        .padding(.leading, 12)
        .frame(minHeight: 72, alignment: .top)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var articleContentText: Text {
        let title = article.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = article.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleText = Text(title.isEmpty ? localized("暫無資料") : title)
            .font(.headline)
            .foregroundColor(DSColor.textPrimary)

        guard !summary.isEmpty else {
            return titleText
        }

        return titleText
            + Text("\n\(summary)")
                .font(.body)
                .foregroundColor(DSColor.textSecondary)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if article.isFavorite {
            Image(systemName: "star.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.yellow)
        } else if !article.isRead {
            Circle()
                .fill(DSColor.accent)
                .frame(width: 14, height: 14)
        } else {
            Color.clear
        }
    }

    private var metadataText: String {
        if let author = article.author?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty {
            return author
        }
        return source.name
    }
}

private struct RSSFeedSearchDock: View {
    @Binding var searchText: String

    var body: some View {
        HStack(spacing: 14) {
            RSSFeedSearchBar(searchText: $searchText)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(DSColor.textPrimary)
                        .frame(width: 54, height: 54)
                        .background(.regularMaterial, in: Circle())
                        .shadow(color: .black.opacity(0.08), radius: 16, x: 0, y: 8)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct RSSFeedSearchBar: View {
    @Binding var searchText: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 23, weight: .semibold))
                .foregroundColor(DSColor.textPrimary)

            TextField(localized("搜尋文章"), text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.title3)
                .foregroundColor(DSColor.textPrimary)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity)
        .frame(height: 58)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.08), radius: 18, x: 0, y: 8)
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
