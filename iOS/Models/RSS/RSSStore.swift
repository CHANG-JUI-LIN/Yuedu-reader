import Foundation
import Combine
import SwiftUI

final class RSSStore: ObservableObject {
    static let shared = RSSStore()

    @Published var sources: [RSSSource] = []
    @Published private var cachedArticlesBySource: [String: [RSSArticleRecord]] = [:]
    @Published private var articleStatuses: [String: RSSArticleStatus] = [:]
    @Published private var feedMetadataBySource: [String: RSSFeedFetchMetadata] = [:]

    private let sourceStorageURL: URL
    private let articleStorageURL: URL
    private let statusStorageURL: URL
    private let feedMetadataStorageURL: URL

    init(storageDirectory: URL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!) {
        sourceStorageURL = storageDirectory.appendingPathComponent("rss_sources.json")
        articleStorageURL = storageDirectory.appendingPathComponent("rss_articles.json")
        statusStorageURL = storageDirectory.appendingPathComponent("rss_article_status.json")
        feedMetadataStorageURL = storageDirectory.appendingPathComponent("rss_feed_metadata.json")
        load()
    }

    func addSource(_ source: RSSSource) {
        sources.append(source)
        save()
    }

    func addSources(_ newSources: [RSSSource]) -> Int {
        guard !newSources.isEmpty else { return 0 }
        var existingURLs = Set(sources.map(\.url))
        var nextSortOrder = (sources.map(\.sortOrder).max() ?? -1) + 1
        var added = 0

        for var source in newSources where !existingURLs.contains(source.url) {
            source.sortOrder = nextSortOrder
            nextSortOrder += 1
            sources.append(source)
            existingURLs.insert(source.url)
            added += 1
        }

        if added > 0 {
            save()
        }
        return added
    }

    func removeSource(at offsets: IndexSet) {
        let ids = offsets.compactMap { index -> String? in
            guard sources.indices.contains(index) else { return nil }
            return sources[index].id
        }
        removeSources(ids: ids)
    }

    func removeSources(ids: [String]) {
        guard !ids.isEmpty else { return }
        let sourceIDs = Set(ids)
        let articleIDs = sourceIDs.flatMap { cachedArticlesBySource[$0]?.map(\.id) ?? [] }

        sources.removeAll { sourceIDs.contains($0.id) }
        for sourceID in sourceIDs {
            cachedArticlesBySource[sourceID] = nil
            feedMetadataBySource[sourceID] = nil
        }
        for articleID in articleIDs {
            articleStatuses[articleID] = nil
        }
        save()
    }

    func updateSource(_ source: RSSSource) {
        if let index = sources.firstIndex(where: { $0.id == source.id }) {
            sources[index] = source
            save()
        }
    }

    func mergeFetchedItems(_ items: [RSSItem], for sourceID: String) {
        let existingByID = Dictionary(uniqueKeysWithValues: (cachedArticlesBySource[sourceID] ?? []).map { ($0.id, $0) })
        let fetchedAt = Date()
        cachedArticlesBySource[sourceID] = items.map { item in
            var record = RSSArticleRecord(item: item, fetchedAt: fetchedAt, status: articleStatuses[item.id])
            if let oldRecord = existingByID[item.id] {
                record.fullText = oldRecord.fullText
                record.fullTextHTML = oldRecord.fullTextHTML
                record.fullTextFetchedAt = oldRecord.fullTextFetchedAt

                if articleStatuses[item.id] == nil {
                    record.isRead = oldRecord.isRead
                    record.isFavorite = oldRecord.isFavorite
                    record.lastOpenedAt = oldRecord.lastOpenedAt
                    record.readerScrollY = oldRecord.readerScrollY
                }
            }
            return record
        }
        save()
    }

    func applyFeedResponse(_ response: RSSFeedResponse, for sourceID: String) {
        switch response {
        case .notModified:
            var metadata = feedMetadataBySource[sourceID] ?? RSSFeedFetchMetadata()
            metadata.lastFetchedAt = Date()
            feedMetadataBySource[sourceID] = metadata
            save()

        case .updated(let items, let metadata, let feedInfo):
            feedMetadataBySource[sourceID] = metadata
            applyFeedInfo(feedInfo, to: sourceID)
            mergeFetchedItems(items, for: sourceID)
        }
    }

    func articles(for sourceID: String) -> [RSSArticleRecord] {
        (cachedArticlesBySource[sourceID] ?? [])
            .map { $0.applying(status: articleStatuses[$0.id]) }
            .sorted { lhs, rhs in
                (lhs.pubDate ?? lhs.fetchedAt) > (rhs.pubDate ?? rhs.fetchedAt)
            }
    }

    func status(for articleID: String) -> RSSArticleStatus? {
        articleStatuses[articleID]
    }

    func markRead(articleId: String, isRead: Bool) {
        var status = articleStatuses[articleId] ?? RSSArticleStatus(articleId: articleId)
        status.isRead = isRead
        if isRead {
            status.lastOpenedAt = Date()
        }
        articleStatuses[articleId] = status
        updateCachedArticle(articleId: articleId, status: status)
        save()
    }

    func updateReaderScrollY(articleId: String, scrollY: Double) {
        var status = articleStatuses[articleId] ?? RSSArticleStatus(articleId: articleId)
        let normalizedScrollY = max(0, scrollY)
        guard abs(status.readerScrollY - normalizedScrollY) > 1 else { return }
        status.readerScrollY = normalizedScrollY
        articleStatuses[articleId] = status
        updateCachedArticle(articleId: articleId, status: status)
        save()
    }

    func toggleFavorite(articleId: String) {
        var status = articleStatuses[articleId] ?? RSSArticleStatus(articleId: articleId)
        status.isFavorite.toggle()
        articleStatuses[articleId] = status
        updateCachedArticle(articleId: articleId, status: status)
        save()
    }

    func unreadCount(for sourceID: String) -> Int {
        articles(for: sourceID).filter { !$0.isRead }.count
    }

    func lastFetchedAt(for sourceID: String) -> Date? {
        feedMetadataBySource[sourceID]?.lastFetchedAt ?? cachedArticlesBySource[sourceID]?.map(\.fetchedAt).max()
    }

    func feedMetadata(for sourceID: String) -> RSSFeedFetchMetadata? {
        feedMetadataBySource[sourceID]
    }

    func searchArticles(query: String) -> [RSSArticleRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let allArticles = sources.flatMap { articles(for: $0.id) }
        guard !trimmed.isEmpty else {
            return allArticles
        }
        return allArticles.filter { article in
            let sourceName = sources.first(where: { $0.id == article.sourceId })?.name ?? ""
            return article.title.localizedCaseInsensitiveContains(trimmed)
                || article.summary.localizedCaseInsensitiveContains(trimmed)
                || sourceName.localizedCaseInsensitiveContains(trimmed)
                || (article.author?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }

    func article(id articleID: String) -> RSSArticleRecord? {
        for sourceID in cachedArticlesBySource.keys {
            if let article = cachedArticlesBySource[sourceID]?.first(where: { $0.id == articleID }) {
                return article.applying(status: articleStatuses[articleID])
            }
        }
        return nil
    }

    func updateFullText(articleId: String, text: String, html: String? = nil, fetchedAt: Date = Date()) {
        for sourceID in cachedArticlesBySource.keys {
            guard let index = cachedArticlesBySource[sourceID]?.firstIndex(where: { $0.id == articleId }) else {
                continue
            }
            cachedArticlesBySource[sourceID]?[index].fullText = text
            cachedArticlesBySource[sourceID]?[index].fullTextHTML = html
            cachedArticlesBySource[sourceID]?[index].fullTextFetchedAt = fetchedAt
        }
        save()
    }

    private func updateCachedArticle(articleId: String, status: RSSArticleStatus) {
        for sourceID in cachedArticlesBySource.keys {
            guard let index = cachedArticlesBySource[sourceID]?.firstIndex(where: { $0.id == articleId }) else {
                continue
            }
            cachedArticlesBySource[sourceID]?[index] = cachedArticlesBySource[sourceID]![index].applying(status: status)
        }
    }

    private func applyFeedInfo(_ feedInfo: RSSFeedInfo?, to sourceID: String) {
        guard let feedInfo,
              let index = sources.firstIndex(where: { $0.id == sourceID }) else {
            return
        }

        var source = sources[index]
        var didChange = false
        let baseURL = URL(string: source.url)

        if let homepageURL = normalizedURLString(feedInfo.homepageURL, relativeTo: baseURL),
           source.homepageURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            source.homepageURL = homepageURL
            didChange = true
        }

        let iconBaseURL = source.homepageURL.flatMap(URL.init(string:)) ?? baseURL
        if let faviconURL = normalizedURLString(feedInfo.faviconURL, relativeTo: iconBaseURL),
           source.faviconURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            source.faviconURL = faviconURL
            didChange = true
        }

        if let title = feedInfo.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty,
           shouldReplaceSourceName(source.name, url: source.url) {
            source.name = title
            didChange = true
        }

        if didChange {
            sources[index] = source
        }
    }

    private func normalizedURLString(_ value: String?, relativeTo baseURL: URL?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }

        if let url = URL(string: value), url.scheme != nil {
            return url.absoluteString
        }
        return URL(string: value, relativeTo: baseURL)?.absoluteURL.absoluteString
    }

    private func shouldReplaceSourceName(_ name: String, url: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == url
    }

    private func load() {
        sources = load([RSSSource].self, from: sourceStorageURL) ?? []
        cachedArticlesBySource = load([String: [RSSArticleRecord]].self, from: articleStorageURL) ?? [:]
        articleStatuses = load([String: RSSArticleStatus].self, from: statusStorageURL) ?? [:]
        feedMetadataBySource = load([String: RSSFeedFetchMetadata].self, from: feedMetadataStorageURL) ?? [:]
    }

    private func save() {
        save(sources, to: sourceStorageURL)
        save(cachedArticlesBySource, to: articleStorageURL)
        save(articleStatuses, to: statusStorageURL)
        save(feedMetadataBySource, to: feedMetadataStorageURL)
    }

    private func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func save<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
