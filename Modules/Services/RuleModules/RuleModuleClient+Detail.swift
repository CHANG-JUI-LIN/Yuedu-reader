import Foundation

// Format 3.0.2: a book's own page as 作品詳情 opens it (`detail`), and the works the site
// relates to a record (`related`). Both go through `send`: `safeURL` and the module's hosts on
// the address and every redirect, under its `rateLimit`.

/// A book's page as the module's `detail` read it, as its cache keeps it.
struct RuleModuleBookDetail: Codable, Equatable, Sendable {
    var intro: String
    var tags: [String]
    var fetchedAt: Date
    var version: String?
}

extension RuleModuleClient {
    /// Cache names: `~` is in no entry id (`RuleModuleValidator.isFileSafe`).
    static let detailCacheName = "~detail"
    static let relatedCacheName = "~related"
    /// Works kept per record.
    nonisolated static let relatedLimit = 30

    /// The book at `url` as the module's own `detail` reads it: its description and tags. From
    /// the cache when the block's `cacheDuration` has not passed, the module's version unchanged.
    func bookDetail(url: String, by detail: RuleModule.Detail, in module: RuleModule) async throws -> RuleModuleBookDetail {
        let file = cacheFile(module: module.id, entry: Self.detailCacheName,
                             values: module.withGlobalValues(["url": url], language: nil))
        let duration = TimeInterval(max(detail.cacheDuration ?? 0, 0))
        if duration > 0, let cached = cached(RuleModuleBookDetail.self, at: file), cached.version == module.version,
           now().timeIntervalSince(cached.fetchedAt) < duration {
            return cached
        }
        let empty = RuleListItem(name: "", author: "", bookUrl: url, coverUrl: "", intro: "", wordCount: "",
                                 lastChapter: "", kind: "")
        let read = try await detailed(empty, by: detail, in: module)
        let found = RuleModuleBookDetail(intro: read.intro, tags: read.tags ?? [], fetchedAt: now(), version: module.version)
        if duration > 0 { save(found, to: file) }
        return found
    }

    /// The works the site relates to `item`, read with `related.list`. `{{id}}` and `{{url}}` are
    /// the record's, as `reviews` has them.
    func related(of item: RuleListItem, by related: RuleModule.Related, in module: RuleModule) async throws -> [RuleListItem] {
        let values = module.withGlobalValues(["id": item.id ?? "", "url": item.bookUrl], language: nil)
        let file = cacheFile(module: module.id, entry: Self.relatedCacheName, values: values)
        let duration = TimeInterval(max(related.cacheDuration ?? 0, 0))
        if duration > 0, let cached = cached(RuleModulePage.self, at: file), cached.version == module.version,
           now().timeIntervalSince(cached.fetchedAt) < duration {
            return cached.items
        }
        let started = SourcePerfTrace.now
        let page = try await perform(related.request, values: values, ofRecord: true, in: module)
        let items = Array(RuleListMapping.items(engine: module.ruleEngine(), content: page.text, baseURL: page.baseURL,
                                                listRule: related.list.items, fields: related.list.fields)
            .prefix(Self.relatedLimit))
        SourcePerfTrace.record("module.related", "module=\(module.id) items=\(items.count)", since: started, thresholdMs: 0)
        if duration > 0 { save(RuleModulePage(items: items, fetchedAt: now(), version: module.version), to: file) }
        return items
    }

    /// Whether `item` has every key `related`'s request names.
    nonisolated static func canAskRelated(of item: RuleListItem, by related: RuleModule.Related) -> Bool {
        let request = related.request
        let names = Set(RuleModuleValidator.templateNames(
            in: request.url + (request.body ?? "") + (request.headers ?? [:]).values.joined()))
        func has(_ value: String?) -> Bool { !(value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return (!names.contains("id") || has(item.id)) && (!names.contains("url") || has(item.bookUrl))
    }
}
