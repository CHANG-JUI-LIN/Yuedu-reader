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

    /// A module with a `search` is asked by 搜索 on submit (Phase 6g, `ModuleSearch`).
    func capabilities() async -> CollectionCapabilities {
        CollectionCapabilities(search: module.search == nil ? .none : .onSubmit,
                               paginates: module.modules.contains { $0.paging != nil })
    }

    /// The root lists the entries; an entry's location is its page.
    func browse(_ location: CollectionLocation?, after cursor: CollectionCursor?) async throws -> CollectionPage {
        guard let location else {
            return CollectionPage(entries: module.modules.compactMap { entry in
                entry.id.map { .location(CollectionLocation(id: $0, title: entry.title ?? "")) }
            }, next: nil)
        }
        return try await page(ofList: location.id, parameters: [:], after: cursor)
    }

    /// One page of a list with a section's own values (查看全部, Phase 6f-2).
    func page(ofList entryID: String, parameters: [String: String], after cursor: CollectionCursor?) async throws -> CollectionPage {
        guard let entry = entry(entryID) else {
            throw SourceFailure(kind: .unavailable, underlying: FetchError.invalidURL(entryID))
        }
        return try await page(of: entry, parameters: parameters, after: cursor)
    }

    /// The first page of the module's search for `keyword` (搜索, Phase 6g); nil when the
    /// module has no search.
    func search(_ keyword: String) async throws -> CollectionPage? {
        guard let search = module.search else { return nil }
        return try await page(of: search, parameters: [:], after: nil, keyword: keyword)
    }

    // MARK: - Home

    func loadPolicy(for section: HomeSection) -> SectionLoadPolicy? {
        guard case .module(let moduleID, let entryID) = section.binding, moduleID == module.id, entry(entryID) != nil else {
            return nil
        }
        // Its own lane: `SourceRateLimit` keys the module's requests by its id.
        return .parallel
    }

    /// An update may change a list's rules under the same section: the version makes its row
    /// load again (`HomeModel.sync`).
    func inputsKey(for section: HomeSection) -> String? {
        module.version
    }

    func load(_ section: HomeSection) async throws -> [CollectionEntry] {
        guard case .module(let moduleID, let entryID) = section.binding, moduleID == module.id,
              let entry = entry(entryID) else { return [] }
        return try await page(of: entry, parameters: section.parameters, after: nil).items(limit: HomeRow.limit)
    }

    // MARK: - Pages

    func entry(_ id: String) -> RuleModule.Entry? {
        module.modules.first { $0.id == id }
    }

    /// The module's search for `keyword` as its list items, every value whole (a summary is not
    /// cut to a row's blurb): what `ModuleFillProvider` matches and fills from. Nil when the
    /// module has no search.
    func searchItems(_ keyword: String) async throws -> [RuleListItem]? {
        guard let search = module.search else { return nil }
        return try await items(of: search, parameters: [:], position: search.firstPosition, keyword: keyword)
    }

    /// The module's lookup for `isbn` (an ISBN-13) as its list items; nil when it has none.
    func lookupItems(isbn: String) async throws -> [RuleListItem]? {
        guard let lookup = module.lookup else { return nil }
        var values = lookup.values([:], position: lookup.firstPosition)
        values["isbn"] = isbn
        return try await items(of: lookup, values: values)
    }

    /// An item as the entry `searchItems` (or `lookupItems`, from `entry`) would list it.
    func searchEntry(_ item: RuleListItem, of entry: RuleModule.Entry? = nil) -> CollectionEntry? {
        guard let list = entry ?? module.search else { return nil }
        return Self.entry(item, of: list, instance: instance, hasURLRule: Self.hasURLRule(list),
                          hosts: Set(module.hosts.map { $0.lowercased() }), isReadable: isReadable(list))
    }

    /// A cover a lookup's record names, from the module's hosts only.
    func coverImage(_ address: String) async throws -> Data? {
        try await client.image(address, in: module)
    }

    private func page(of entry: RuleModule.Entry, parameters: [String: String],
                      after cursor: CollectionCursor?, keyword: String? = nil) async throws -> CollectionPage {
        let position = cursor.flatMap { Int($0.value) } ?? entry.firstPosition
        let items = try await items(of: entry, parameters: parameters, position: position, keyword: keyword)
        let instance = instance
        let hasURLRule = Self.hasURLRule(entry)
        let hosts = Set(module.hosts.map { $0.lowercased() })
        let isReadable = isReadable(entry)
        return CollectionPage(
            entries: items.compactMap {
                Self.entry($0, of: entry, instance: instance, hasURLRule: hasURLRule, hosts: hosts, isReadable: isReadable)
            },
            next: entry.position(after: position, itemCount: items.count).map { CollectionCursor(value: String($0)) })
    }

    /// Its items are books the module reads: never a lookup's record, which is a copy's data.
    private func isReadable(_ entry: RuleModule.Entry) -> Bool {
        module.reading != nil && entry != module.lookup
    }

    private nonisolated static func hasURLRule(_ entry: RuleModule.Entry) -> Bool {
        !(entry.list.url ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func items(of entry: RuleModule.Entry, parameters: [String: String], position: Int,
                       keyword: String?) async throws -> [RuleListItem] {
        try await items(of: entry, values: entry.values(parameters, position: position, keyword: keyword))
    }

    private func items(of entry: RuleModule.Entry, values: [String: String]) async throws -> [RuleListItem] {
        do {
            return try await client.page(of: entry, in: module, values: values).items
        } catch {
            let failure = try SourceFailure.classify(error)
            AppLogger.network("module page failed", error: SourceFailure.loggable(error), context: [
                "module": module.id, "entry": entry.id ?? (entry == module.lookup ? "lookup" : "search"), "failure": failure.kind.rawValue,
                "status": failure.status.map(String.init) ?? "",
            ])
            throw failure
        }
    }

    /// A list item as an entry, bounded and plain as every source's summary is: a book the
    /// module reads when `isReadable`, else data only.
    nonisolated static func entry(_ item: RuleListItem, of entry: RuleModule.Entry, instance: SourceInstanceKey,
                                  hasURLRule: Bool, hosts: Set<String>, isReadable: Bool = false) -> CollectionEntry? {
        let title = OPDSClient.plainMetadata(item.name, limit: 200)
        guard !title.isEmpty else { return nil }
        let author = OPDSClient.plainMetadata(item.author, limit: 100)
        let authors = author.isEmpty ? [] : [author]
        let language = item.language.isEmpty ? nil : LanguageTag(item.language)?.identifier
        // Without a url rule every item would read the page's own address.
        let itemID = hasURLRule && !item.bookUrl.isEmpty ? item.bookUrl : "\(title)\u{1F}\(author)"
        let kind = entry.contentKind(of: item)
        let identifiers = Set([item.isbn.flatMap { ExternalIdentifier.normalized(.isbn13, $0) }].compactMap { $0 })
        let record = SourceRecord(key: SourceItemKey(instance: instance, item: itemID), title: title, authors: authors,
                                  language: language, contentKind: kind, identifiers: identifiers, copyID: nil,
                                  acquisitions: [.viewOnly])
        // A cover is a request too: only from the module's hosts.
        let cover: CoverReference = safeURL(string: item.coverUrl)
            .flatMap { url in url.host.map { hosts.contains($0.lowercased()) } == true ? url : nil }
            .map { .remote($0, headers: [:]) } ?? .generated(seed: title)
        let summary = WorkSummary(title: title, authors: authors, cover: cover,
                                  blurb: OPDSClient.plainMetadata(item.intro, limit: WorkSummary.blurbLimit),
                                  language: language, contentKind: kind,
                                  category: WorkSummary.category(fromSourceKind: OPDSClient.plainMetadata(item.kind, limit: 200))
                                    ?? entry.tags(of: item).first)
        // A book the module reads has a page of its own: the item's url.
        guard isReadable, hasURLRule, !item.bookUrl.isEmpty else { return .item(record, summary, .bibliographic) }
        var readable = record
        readable.acquisitions = [.readOnline]
        let book = ModuleBook(reference: ModuleBookReference(moduleID: instance.id, bookURL: item.bookUrl), title: title,
                              author: author, coverURL: { if case .remote(let url, _) = cover { url.absoluteString } else { nil } }(),
                              contentKind: kind)
        return .item(readable, summary, .moduleBook(book))
    }
}

extension RuleModule.Entry {
    /// The item's kind: `comic` when its own rule says so, else the entry's (format 3.0).
    nonisolated func contentKind(of item: RuleListItem) -> ContentKind {
        if item.contentKind?.lowercased() == ContentKind.comic.rawValue { return .comic }
        return contentKind.flatMap(ContentKind.init(rawValue:)) ?? .text
    }

    /// The item's tags as metadata: the `tags` rule's values (else its `kind`'s, split as a
    /// 來源配置's categories are), without the entry's `excludeTags`, at most 5. A tag rule's
    /// value is one tag: AniList's "Slice of Life" is not split.
    ///
    /// A tag that is the item's own author, publisher or series names it, not its genre
    /// (Bangumi tags 山田鐘人 and 小学館).
    nonisolated func tags(of item: RuleListItem) -> [String] {
        let named = [item.author, item.publisher ?? "", item.series ?? ""]
            .flatMap { $0.components(separatedBy: CharacterSet(charactersIn: ",，、/／;；")) }
        let excluded = Set(((excludeTags ?? []) + named).map(WorkMatchKey.title).filter { !$0.isEmpty })
        let values: [String]
        if let list = item.tags {
            var seen = Set<String>()
            values = list.map { OPDSClient.plainMetadata($0, limit: 100) }
                .filter { !$0.isEmpty && $0.count <= Self.tagLengthLimit && !$0.contains(where: \.isNumber) }
                .filter { seen.insert(WorkMatchKey.title($0)).inserted }
        } else {
            values = BookSourceFillProvider.tags(from: OPDSClient.plainMetadata(item.kind, limit: 1_000))
        }
        return Array(values.filter { !excluded.contains(WorkMatchKey.title($0)) }.prefix(5))
    }

    /// Longer than a category: a phrase, not a genre.
    nonisolated static let tagLengthLimit = 24
}
