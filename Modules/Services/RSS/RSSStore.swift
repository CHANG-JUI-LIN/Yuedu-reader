import Foundation
import Combine
import SwiftUI

@MainActor
final class RSSStore: ObservableObject {
    static let shared = RSSStore()

    @Published var sources: [RSSSource] = []
    @Published var folders: [RSSFolder] = []
    @Published private var cachedArticlesBySource: [String: [RSSArticleRecord]] = [:]
    @Published private var articleStatuses: [String: RSSArticleStatus] = [:]
    @Published private var feedMetadataBySource: [String: RSSFeedFetchMetadata] = [:]

    private let sourceStorageURL: URL
    private let folderStorageURL: URL
    private let articleStorageURL: URL
    private let statusStorageURL: URL
    private let feedMetadataStorageURL: URL

    init(storageDirectory: URL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!) {
        sourceStorageURL = storageDirectory.appendingPathComponent("rss_sources.json")
        folderStorageURL = storageDirectory.appendingPathComponent("rss_folders.json")
        articleStorageURL = storageDirectory.appendingPathComponent("rss_articles.json")
        statusStorageURL = storageDirectory.appendingPathComponent("rss_article_status.json")
        feedMetadataStorageURL = storageDirectory.appendingPathComponent("rss_feed_metadata.json")
        load()
    }

    func addSource(_ source: RSSSource) {
        if let groupName = normalizedFolderName(source.sourceGroup) {
            ensureFolderExists(named: groupName)
        }
        sources.append(source)
        save()
    }

    func addSources(_ newSources: [RSSSource]) -> Int {
        addSourcesReturningAdded(newSources).count
    }

    func addSourcesReturningAdded(_ newSources: [RSSSource]) -> [RSSSource] {
        guard !newSources.isEmpty else { return [] }
        var existingURLs = Set(sources.map(\.url))
        var addedSources: [RSSSource] = []

        for var source in newSources where !existingURLs.contains(source.url) {
            let groupName = normalizedFolderName(source.sourceGroup)
            source.sourceGroup = groupName
            if let groupName {
                ensureFolderExists(named: groupName)
            }
            source.sortOrder = nextSourceSortOrder(inFolderNamed: groupName)
            sources.append(source)
            existingURLs.insert(source.url)
            addedSources.append(source)
        }

        if !addedSources.isEmpty {
            save()
        }
        return addedSources
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
            var normalized = source
            normalized.sourceGroup = normalizedFolderName(source.sourceGroup)
            if let groupName = normalized.sourceGroup {
                ensureFolderExists(named: groupName)
            }
            sources[index] = normalized
            save()
        }
    }

    func applyResolvedFeedURL(_ feedURL: String?, homepageURL: String?, to sourceID: String) {
        guard let index = sources.firstIndex(where: { $0.id == sourceID }) else { return }

        var source = sources[index]
        var didChange = false

        if let feedURL,
           !feedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           source.url != feedURL {
            source.url = feedURL
            didChange = true
        }

        if let homepageURL,
           !homepageURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           source.homepageURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            source.homepageURL = homepageURL
            didChange = true
        }

        if didChange {
            sources[index] = source
            saveRefreshResult(.sources)
        }
    }

    func addFolder(named name: String) -> Bool {
        guard let name = normalizedFolderName(name),
              !folders.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            return false
        }

        folders.append(RSSFolder(name: name, sortOrder: nextFolderSortOrder()))
        save()
        return true
    }

    func updateFolder(_ folder: RSSFolder) {
        guard let index = folders.firstIndex(where: { $0.id == folder.id }),
              let newName = normalizedFolderName(folder.name) else {
            return
        }

        let oldName = folders[index].name
        folders[index].name = newName
        for sourceIndex in sources.indices where sourceGroup(sources[sourceIndex].sourceGroup, matches: oldName) {
            sources[sourceIndex].sourceGroup = newName
        }
        save()
    }

    func removeFolder(_ folder: RSSFolder, deleteSources: Bool = true) {
        guard let index = folders.firstIndex(where: { $0.id == folder.id }) else { return }
        folders.remove(at: index)
        if deleteSources {
            let ids = sources.filter { sourceGroup($0.sourceGroup, matches: folder.name) }.map(\.id)
            if ids.isEmpty {
                save()
            } else {
                removeSources(ids: ids)
            }
        } else {
            for sourceIndex in sources.indices where sourceGroup(sources[sourceIndex].sourceGroup, matches: folder.name) {
                sources[sourceIndex].sourceGroup = nil
            }
            save()
        }
    }

    func rootSources() -> [RSSSource] {
        sources(inFolderNamed: nil)
    }

    func sources(in folder: RSSFolder) -> [RSSSource] {
        sources(inFolderNamed: folder.name)
    }

    func moveSources(inFolderNamed folderName: String?, fromOffsets sourceOffsets: IndexSet, toOffset destination: Int) {
        var ordered = sources(inFolderNamed: normalizedFolderName(folderName))
        ordered.move(fromOffsets: sourceOffsets, toOffset: destination)

        for (sortOrder, source) in ordered.enumerated() {
            guard let index = sources.firstIndex(where: { $0.id == source.id }) else { continue }
            sources[index].sortOrder = sortOrder
        }
        save()
    }

    func moveFolders(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        var ordered = orderedFolders()
        ordered.move(fromOffsets: offsets, toOffset: destination)

        for (sortOrder, folder) in ordered.enumerated() {
            guard let index = folders.firstIndex(where: { $0.id == folder.id }) else { continue }
            folders[index].sortOrder = sortOrder
        }
        save()
    }

    func orderedFolders() -> [RSSFolder] {
        folders.sorted { lhs, rhs in
            if lhs.sortOrder == rhs.sortOrder {
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            return lhs.sortOrder < rhs.sortOrder
        }
    }

    func nextSourceSortOrder(in folder: RSSFolder?) -> Int {
        nextSourceSortOrder(inFolderNamed: folder?.name)
    }

    @discardableResult
    func mergeFetchedItems(_ items: [RSSItem], for sourceID: String) -> [RSSArticleRecord] {
        let existingRecords = cachedArticlesBySource[sourceID] ?? []

        // Real-world feeds (and Legado custom-rule sources whose uniqueID
        // falls back to link then title) routinely emit duplicate GUIDs, which
        // become duplicate RSSItem.id. A prior build persisted those duplicates
        // into cachedArticlesBySource, and the uniqueKeysWithValues initializer
        // traps on duplicate keys — Crashlytics 5dd3bb... (main-thread
        // assertionFailure inside _NativeDictionary.merge). Build the lookup
        // crash-safely so an already-corrupted cache self-heals on the next
        // refresh instead of taking the app down. This is an invariant guard
        // for cached article records (keyed by id must be unique); it is not a
        // retry/alternate path and stays even after the parser is hardened,
        // because feed GUIDs are external data we cannot trust to be unique.
        let existingByID = Dictionary(existingRecords.map { ($0.id, $0) },
                                      uniquingKeysWith: { first, _ in first })

        let hadExistingCache = !existingRecords.isEmpty
        let fetchedAt = Date()

        // Same root cause: dedupe incoming items by id (keep first occurrence /
        // feed order) so we never persist duplicate records in the first place.
        var seenIDs = Set<String>()
        let dedupedItems = items.filter { seenIDs.insert($0.id).inserted }

        let mergedRecords = dedupedItems.map { item in
            var record = RSSArticleRecord(item: item, fetchedAt: fetchedAt, status: articleStatuses[item.id])
            if let oldRecord = existingByID[item.id] {
                // First seen, not last fetched: re-stamping every record made every refresh
                // look like a change and rewrote the whole article file (below).
                record.fetchedAt = oldRecord.fetchedAt
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
        if mergedRecords != existingRecords {
            cachedArticlesBySource[sourceID] = mergedRecords
            saveRefreshResult(.articles)
        }
        guard hadExistingCache else { return [] }
        return mergedRecords.filter { record in
            existingByID[record.id] == nil && !record.isRead
        }
    }

    @discardableResult
    func applyFeedResponse(_ response: RSSFeedResponse, for sourceID: String) -> [RSSArticleRecord] {
        switch response {
        case .notModified:
            var metadata = feedMetadataBySource[sourceID] ?? RSSFeedFetchMetadata()
            metadata.lastFetchedAt = Date()
            feedMetadataBySource[sourceID] = metadata
            saveRefreshResult(.feedMetadata)
            return []

        case .updated(let items, let metadata, let feedInfo):
            feedMetadataBySource[sourceID] = metadata
            saveRefreshResult(.feedMetadata)
            applyFeedInfo(feedInfo, to: sourceID)
            return mergeFetchedItems(items, for: sourceID)
        }
    }

    func articles(for sourceID: String) -> [RSSArticleRecord] {
        (cachedArticlesBySource[sourceID] ?? [])
            .map { $0.applying(status: articleStatuses[$0.id]) }
            .sorted { lhs, rhs in
                (lhs.pubDate ?? lhs.fetchedAt) > (rhs.pubDate ?? rhs.fetchedAt)
            }
    }

    func articles(for smartFeed: RSSSmartFeedKind) -> [RSSArticleRecord] {
        allArticles().filter { article in
            switch smartFeed {
            case .today:
                return Calendar.current.isDateInToday(article.pubDate ?? article.fetchedAt)
            case .allUnread:
                return !article.isRead
            case .starred:
                return article.isFavorite
            }
        }
    }

    func allArticles() -> [RSSArticleRecord] {
        sources
            .flatMap { articles(for: $0.id) }
            .sorted { lhs, rhs in
                (lhs.pubDate ?? lhs.fetchedAt) > (rhs.pubDate ?? rhs.fetchedAt)
            }
    }

    func status(for articleID: String) -> RSSArticleStatus? {
        articleStatuses[articleID]
    }

    var firestoreArticleStatusesSnapshot: [RSSArticleStatus] {
        Array(articleStatuses.values)
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
        if isRead {
            RSSNotificationManager.shared.removeDeliveredNotification(articleID: articleId)
        }
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

    func markAllRead(sourceID: String? = nil, isRead: Bool = true) {
        let articles = sourceID.map { self.articles(for: $0) } ?? allArticles()
        markAllRead(articleIDs: articles.map(\.id), isRead: isRead)
    }

    func markAllRead(in folder: RSSFolder, isRead: Bool = true) {
        let ids = sources(in: folder).flatMap { articles(for: $0.id).map(\.id) }
        markAllRead(articleIDs: ids, isRead: isRead)
    }

    func markAllRead(smartFeed: RSSSmartFeedKind, isRead: Bool = true) {
        markAllRead(articleIDs: articles(for: smartFeed).map(\.id), isRead: isRead)
    }

    func markAllRead(articleIDs: [String], isRead: Bool = true) {
        guard !articleIDs.isEmpty else { return }

        let now = Date()
        for articleID in articleIDs {
            var status = articleStatuses[articleID] ?? RSSArticleStatus(articleId: articleID)
            status.isRead = isRead
            if isRead {
                status.lastOpenedAt = now
            }
            articleStatuses[articleID] = status
            updateCachedArticle(articleId: articleID, status: status)
        }
        save()
        if isRead {
            RSSNotificationManager.shared.removeDeliveredNotifications(articleIDs: articleIDs)
        }
    }

    /// Counted through the status overlay directly. `articles(for:)` copies every article to
    /// apply its status and sorts them; the counts are read in the root view's body (the RSS
    /// badge) and per row of the RSS list, so that was ~7.6 ms per total over 10 000
    /// articles (Debug simulator). Same answer: `applying(status:)` takes `isRead` from the
    /// status when there is one.
    func unreadCount(for sourceID: String) -> Int {
        (cachedArticlesBySource[sourceID] ?? []).reduce(0) { count, article in
            count + (isRead(article) ? 0 : 1)
        }
    }

    private func isRead(_ article: RSSArticleRecord) -> Bool {
        articleStatuses[article.id]?.isRead ?? article.isRead
    }

    func unreadCount(for folder: RSSFolder) -> Int {
        sources(in: folder).reduce(0) { partial, source in
            partial + unreadCount(for: source.id)
        }
    }

    func unreadCount(for smartFeed: RSSSmartFeedKind) -> Int {
        var count = 0
        for source in sources {
            for article in cachedArticlesBySource[source.id] ?? [] where !isRead(article) {
                switch smartFeed {
                case .today:
                    if Calendar.current.isDateInToday(article.pubDate ?? article.fetchedAt) { count += 1 }
                case .allUnread:
                    count += 1
                case .starred:
                    if articleStatuses[article.id]?.isFavorite ?? article.isFavorite { count += 1 }
                }
            }
        }
        return count
    }

    func totalUnreadCount() -> Int {
        sources.reduce(0) { partial, source in
            partial + unreadCount(for: source.id)
        }
    }

    func lastFetchedAt(for sourceID: String) -> Date? {
        feedMetadataBySource[sourceID]?.lastFetchedAt ?? cachedArticlesBySource[sourceID]?.map(\.fetchedAt).max()
    }

    func feedMetadata(for sourceID: String) -> RSSFeedFetchMetadata? {
        feedMetadataBySource[sourceID]
    }

    /// Drops cached conditional-GET metadata (etag/last-modified) for a source.
    /// Call this when the feed URL changes so the next fetch is unconditional and
    /// a stale validator can't trigger a false `notModified` against the new URL.
    func clearFeedMetadata(for sourceID: String) {
        guard feedMetadataBySource[sourceID] != nil else { return }
        feedMetadataBySource[sourceID] = nil
        save()
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

    func source(id sourceID: String) -> RSSSource? {
        sources.first { $0.id == sourceID }
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
            saveRefreshResult(.sources)
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

    private func sources(inFolderNamed folderName: String?) -> [RSSSource] {
        let normalizedName = normalizedFolderName(folderName)
        return sources
            .filter { sourceGroup($0.sourceGroup, matches: normalizedName) }
            .sorted { lhs, rhs in
                if lhs.sortOrder == rhs.sortOrder {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhs.sortOrder < rhs.sortOrder
            }
    }

    private func normalizedFolderName(_ value: String?) -> String? {
        guard let name = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            return nil
        }
        return name
    }

    private func sourceGroup(_ sourceGroup: String?, matches folderName: String?) -> Bool {
        switch (normalizedFolderName(sourceGroup), normalizedFolderName(folderName)) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return lhs.caseInsensitiveCompare(rhs) == .orderedSame
        default:
            return false
        }
    }

    @discardableResult
    private func ensureFolderExists(named name: String) -> Bool {
        guard let name = normalizedFolderName(name),
              !folders.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            return false
        }
        folders.append(RSSFolder(name: name, sortOrder: nextFolderSortOrder()))
        return true
    }

    private func nextFolderSortOrder() -> Int {
        (folders.map(\.sortOrder).max() ?? -1) + 1
    }

    private func nextSourceSortOrder(inFolderNamed folderName: String?) -> Int {
        let normalizedName = normalizedFolderName(folderName)
        return (sources
            .filter { normalizedFolderName($0.sourceGroup) == normalizedName }
            .map(\.sortOrder)
            .max() ?? -1) + 1
    }

    private func backfillFoldersFromSources() {
        var didChange = false
        for source in sources {
            guard let groupName = normalizedFolderName(source.sourceGroup) else { continue }
            didChange = ensureFolderExists(named: groupName) || didChange
        }
        if didChange {
            save()
        }
    }

    private func load() {
        sources = load([RSSSource].self, from: sourceStorageURL) ?? []
        folders = load([RSSFolder].self, from: folderStorageURL) ?? []
        cachedArticlesBySource = load([String: [RSSArticleRecord]].self, from: articleStorageURL) ?? [:]
        articleStatuses = load([String: RSSArticleStatus].self, from: statusStorageURL) ?? [:]
        feedMetadataBySource = load([String: RSSFeedFetchMetadata].self, from: feedMetadataStorageURL) ?? [:]
        backfillFoldersFromSources()
    }

    func replaceFromSync(
        sources syncedSources: [RSSSource]?,
        folders syncedFolders: [RSSFolder]?,
        articleStatuses syncedStatuses: [RSSArticleStatus]?
    ) {
        if let syncedSources {
            sources = syncedSources
        }
        if let syncedFolders {
            folders = syncedFolders
        }
        if let syncedStatuses {
            articleStatuses = Dictionary(uniqueKeysWithValues: syncedStatuses.map { ($0.articleId, $0) })
        }
        save()
    }

    /// The files `save` writes. Each is one JSON document; the article file holds every
    /// cached article of every feed and is by far the largest.
    struct StoredFiles: OptionSet {
        let rawValue: Int
        static let sources = StoredFiles(rawValue: 1 << 0)
        static let folders = StoredFiles(rawValue: 1 << 1)
        static let articles = StoredFiles(rawValue: 1 << 2)
        static let statuses = StoredFiles(rawValue: 1 << 3)
        static let feedMetadata = StoredFiles(rawValue: 1 << 4)
        static let all: StoredFiles = [.sources, .folders, .articles, .statuses, .feedMetadata]
    }

    /// Runs one refresh of many feeds and writes what it changed once, at the end.
    ///
    /// Each feed's merge used to write all five files, the article file included: 189 feeds
    /// refreshed hourly in the background wrote 1084 MB a day (Crashlytics d88da8b2,
    /// MetricKit disk-write-exception, 2026-10-19). The end write also runs when the refresh
    /// is cancelled — a background task expiring — so nothing merged is lost.
    func performRefreshBatch<T>(_ body: () async -> T) async -> T {
        refreshBatchDepth += 1
        defer {
            refreshBatchDepth -= 1
            if refreshBatchDepth == 0, !pendingRefreshFiles.isEmpty {
                save(pendingRefreshFiles)
            }
        }
        return await body()
    }

    private var refreshBatchDepth = 0
    private var pendingRefreshFiles: StoredFiles = []
    /// Writes of each file since launch, for tests.
    private(set) var writeCounts: [String: Int] = [:]

    /// A refresh result's write: deferred to the end of a running `performRefreshBatch`.
    private func saveRefreshResult(_ files: StoredFiles) {
        if refreshBatchDepth > 0 {
            pendingRefreshFiles.formUnion(files)
        } else {
            save(files)
        }
    }

    /// Writes `files` now, together with any refresh result still waiting, so a user's
    /// change in the middle of a refresh is not written ahead of an older state of a file.
    private func save(_ files: StoredFiles = .all) {
        let files = files.union(pendingRefreshFiles)
        pendingRefreshFiles = []
        if files.contains(.sources) { save(sources, to: sourceStorageURL) }
        if files.contains(.folders) { save(folders, to: folderStorageURL) }
        if files.contains(.articles) { save(cachedArticlesBySource, to: articleStorageURL) }
        if files.contains(.statuses) { save(articleStatuses, to: statusStorageURL) }
        if files.contains(.feedMetadata) { save(feedMetadataBySource, to: feedMetadataStorageURL) }
        if !files.isDisjoint(with: [.articles, .statuses]) {
            RSSNotificationManager.shared.updateBadge(unreadCount: totalUnreadCount())
        }
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
        writeCounts[url.lastPathComponent, default: 0] += 1
    }
}
