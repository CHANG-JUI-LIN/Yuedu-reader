import Foundation

/// An installed module as a source (Phase 6d): its entries are its locations, and each can be
/// a row on the Explore home. Its items are data only: 作品詳情 shows what the list gave and
/// offers 尋找可用來源, as for an Open Library result.
@MainActor
final class ModuleProvider: CollectionBrowsing, HomeSectionProviding {
    let module: RuleModule
    private let client: RuleModuleClient

    init(module: RuleModule, client: RuleModuleClient = RuleModuleClient()) {
        self.module = module
        self.client = client
    }

    nonisolated static func instanceKey(moduleID: String) -> SourceInstanceKey {
        SourceInstanceKey(type: .module, id: moduleID)
    }

    var instance: SourceInstanceKey { Self.instanceKey(moduleID: module.id) }
    var displayName: String { module.title }
    var availability: ProviderAvailability { .available }
    var hosts: [String] { module.hosts }
    var rateLimit: String? { module.rateLimit }

    /// Searched once 6g joins it to 搜索.
    func capabilities() async -> CollectionCapabilities {
        CollectionCapabilities(search: .none, paginates: module.modules.contains { $0.paging != nil })
    }

    /// The root lists the entries; an entry's location is its page.
    func browse(_ location: CollectionLocation?, after cursor: CollectionCursor?) async throws -> CollectionPage {
        guard let location else {
            return CollectionPage(entries: module.modules.compactMap { entry in
                entry.id.map { .location(CollectionLocation(id: $0, title: entry.title ?? "")) }
            }, next: nil)
        }
        guard let entry = entry(location.id) else {
            throw SourceFailure(kind: .unavailable, underlying: FetchError.invalidURL(location.id))
        }
        return try await page(of: entry, parameters: [:], after: cursor)
    }

    // MARK: - Home

    func loadPolicy(for section: HomeSection) -> SectionLoadPolicy? {
        guard case .module(let moduleID, let entryID) = section.binding, moduleID == module.id, entry(entryID) != nil else {
            return nil
        }
        // Its own lane: `SourceRateLimit` keys the module's requests by its id.
        return .parallel
    }

    func load(_ section: HomeSection) async throws -> [CollectionEntry] {
        guard case .module(let moduleID, let entryID) = section.binding, moduleID == module.id,
              let entry = entry(entryID) else { return [] }
        return try await page(of: entry, parameters: section.parameters, after: nil).items(limit: HomeRow.limit)
    }

    // MARK: - Pages

    private func entry(_ id: String) -> RuleModule.Entry? {
        module.modules.first { $0.id == id }
    }

    private func page(of entry: RuleModule.Entry, parameters: [String: String],
                      after cursor: CollectionCursor?) async throws -> CollectionPage {
        let position = cursor.flatMap { Int($0.value) } ?? entry.firstPosition
        do {
            let page = try await client.page(of: entry, in: module, values: entry.values(parameters, position: position))
            let instance = instance
            let hasURLRule = !(entry.list.url ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            let hosts = Set(module.hosts.map { $0.lowercased() })
            return CollectionPage(
                entries: page.items.compactMap { Self.entry($0, instance: instance, hasURLRule: hasURLRule, hosts: hosts) },
                next: entry.position(after: position, itemCount: page.items.count).map { CollectionCursor(value: String($0)) })
        } catch {
            let failure = try SourceFailure.classify(error)
            AppLogger.network("module page failed", error: SourceFailure.loggable(error), context: [
                "module": module.id, "entry": entry.id ?? "search", "failure": failure.kind.rawValue,
                "status": failure.status.map(String.init) ?? "",
            ])
            throw failure
        }
    }

    /// A list item as a data-only entry, bounded and plain as every source's summary is.
    nonisolated static func entry(_ item: RuleListItem, instance: SourceInstanceKey, hasURLRule: Bool,
                                  hosts: Set<String>) -> CollectionEntry? {
        let title = OPDSClient.plainMetadata(item.name, limit: 200)
        guard !title.isEmpty else { return nil }
        let author = OPDSClient.plainMetadata(item.author, limit: 100)
        let authors = author.isEmpty ? [] : [author]
        let language = item.language.isEmpty ? nil : LanguageTag(item.language)?.identifier
        // Without a url rule every item would read the page's own address.
        let itemID = hasURLRule && !item.bookUrl.isEmpty ? item.bookUrl : "\(title)\u{1F}\(author)"
        let record = SourceRecord(key: SourceItemKey(instance: instance, item: itemID), title: title, authors: authors,
                                  language: language, contentKind: .text, identifiers: [], copyID: nil,
                                  acquisitions: [.viewOnly])
        // A cover is a request too: only from the module's hosts.
        let cover: CoverReference = safeURL(string: item.coverUrl)
            .flatMap { url in url.host.map { hosts.contains($0.lowercased()) } == true ? url : nil }
            .map { .remote($0, headers: [:]) } ?? .generated(seed: title)
        let summary = WorkSummary(title: title, authors: authors, cover: cover,
                                  blurb: OPDSClient.plainMetadata(item.intro, limit: WorkSummary.blurbLimit),
                                  language: language, contentKind: .text,
                                  category: WorkSummary.category(fromSourceKind: OPDSClient.plainMetadata(item.kind, limit: 200)))
        return .item(record, summary, .bibliographic)
    }
}
