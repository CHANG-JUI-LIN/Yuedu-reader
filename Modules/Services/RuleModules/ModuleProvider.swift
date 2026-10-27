import Foundation

/// An installed module as a source (Phase 6d): its entries are its locations, and each can be
/// a row on the Explore home. Its items are data only: 作品詳情 shows what the list gave and
/// offers 尋找可用來源, as for an Open Library result.
@MainActor
final class ModuleProvider: CollectionBrowsing, HomeSectionProviding {
    let module: RuleModule
    private let client: RuleModuleClient
    /// The reader's 中繼資料語言偏好推薦, for a parameter that follows it.
    private let language: @MainActor () -> String

    init(module: RuleModule, client: RuleModuleClient = RuleModuleClient(),
         language: @escaping @MainActor () -> String = { AggregationSettingsStore.shared.readingLanguages.language }) {
        self.module = module
        self.client = client
        self.language = language
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
    /// module has no search, or none for a keyword this short (`minKeywordLength`).
    func search(_ keyword: String) async throws -> CollectionPage? {
        guard let search = module.search, search.takes(keyword: keyword) else { return nil }
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
    /// Its version, and what each parameter that follows 中繼資料語言偏好推薦 reads now: a new
    /// language loads the row again, in its own 地區.
    func inputsKey(for section: HomeSection) -> String? {
        guard case .module(_, let entryID) = section.binding, let entry = entry(entryID) else { return module.version }
        let followed = entry.params.filter { $0.followsLanguage == true }
            .map { "\($0.name)=\($0.currentValue(in: section.parameters, language: language()))" }
        return ([module.version] + followed).joined(separator: "\u{1F}")
    }

    /// The list's own title, in the app's language: a section the defaults made has none, and
    /// the home names no source (Phase 5 plan, decision 19). A card of a layout of lists adds the
    /// options its own values pick (今日熱門 · 日本): two cards of one list differ by them alone.
    func rowName(for section: HomeSection) -> String {
        guard case .module(_, let entryID) = section.binding, let entry = entry(entryID),
              let title = entry.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return displayName
        }
        return section.drawsLists ? entry.cardName(title, parameters: section.parameters) : title
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
    /// module has no search, or none for a keyword this short.
    func searchItems(_ keyword: String) async throws -> [RuleListItem]? {
        guard let search = module.search, search.takes(keyword: keyword) else { return nil }
        return try await items(of: search, parameters: [:], position: search.firstPosition, keyword: keyword)
    }

    /// The module's lookup for `isbn` (an ISBN-13) as its list items; nil when it has none.
    func lookupItems(isbn: String) async throws -> [RuleListItem]? {
        guard let lookup = module.lookup else { return nil }
        var values = lookup.values([:], position: lookup.firstPosition, language: language())
        values["isbn"] = isbn
        return try await items(of: lookup, values: values)
    }

    /// `item` with what its record's page gives (the entry's `detail`) for a field in `wanted`
    /// it lacks: one request, or none when the entry has no detail or the row already has them.
    func detailed(_ item: RuleListItem, of entry: RuleModule.Entry, wanting wanted: Set<MetadataField>) async throws -> RuleListItem {
        guard let detail = entry.detail else { return item }
        let lacksIntro = wanted.contains(.intro) && detail.intro != nil
            && item.intro.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let lacksTags = wanted.contains(.tags) && detail.tags != nil && entry.tags(of: item).isEmpty
        guard lacksIntro || lacksTags else { return item }
        do {
            return try await client.detailed(item, by: detail, in: module)
        } catch {
            let failure = try SourceFailure.classify(error)
            AppLogger.network("module detail failed", error: SourceFailure.loggable(error), context: [
                "module": module.id, "failure": failure.kind.rawValue, "status": failure.status.map(String.init) ?? "",
            ])
            throw failure
        }
    }

    /// An item as the entry `searchItems` (or `lookupItems`, from `entry`) would list it.
    func searchEntry(_ item: RuleListItem, of entry: RuleModule.Entry? = nil) -> CollectionEntry? {
        guard let list = entry ?? module.search else { return nil }
        return Self.entry(item, of: list, instance: instance, hasURLRule: Self.hasURLRule(list),
                          hosts: RuleModuleHosts(module.hosts), isReadable: isReadable(list))
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
        let hosts = RuleModuleHosts(module.hosts)
        let isReadable = isReadable(entry)
        return CollectionPage(
            entries: items.compactMap {
                Self.entry($0, of: entry, instance: instance, hasURLRule: hasURLRule, hosts: hosts, isReadable: isReadable)
            },
            next: entry.position(after: position, itemCount: items.count).map { CollectionCursor(value: String($0)) })
    }

    /// Authors kept per item, and ISBNs (a classic lists hundreds of editions').
    nonisolated static let authorLimit = 5
    nonisolated static let isbnLimit = 5

    /// A value a rule read as several, one per line (the engine's join), each once.
    nonisolated static func values(_ value: String) -> [String] {
        var seen = Set<String>()
        return value.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
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
        try await items(of: entry, values: entry.values(parameters, position: position, keyword: keyword, language: language()))
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
                                  hasURLRule: Bool, hosts: RuleModuleHosts, isReadable: Bool = false) -> CollectionEntry? {
        let title = OPDSClient.plainMetadata(item.name, limit: 200)
        guard !title.isEmpty else { return nil }
        // A rule that reads several values (Open Library's `author_name`) gives one per line.
        let authors = Array(Self.values(item.author).map { OPDSClient.plainMetadata($0, limit: 100) }
            .filter { !$0.isEmpty }.prefix(Self.authorLimit))
        let author = authors.joined(separator: ", ")
        let language = item.language.isEmpty ? nil : LanguageTag(item.language)?.identifier
        // Without a url rule every item would read the page's own address.
        let itemID = hasURLRule && !item.bookUrl.isEmpty ? item.bookUrl : "\(title)\u{1F}\(author)"
        let kind = entry.contentKind(of: item)
        // An edition's ISBN-10 and -13 normalize to one value; a work lists every edition's.
        let identifiers = Set(Self.values(item.isbn ?? "").lazy.compactMap { ExternalIdentifier.normalized(.isbn13, $0) }
            .reduce(into: [ExternalIdentifier]()) { kept, isbn in
                if kept.count < Self.isbnLimit, !kept.contains(isbn) { kept.append(isbn) }
            })
        let record = SourceRecord(key: SourceItemKey(instance: instance, item: itemID), title: title, authors: authors,
                                  language: language, contentKind: kind, identifiers: identifiers, copyID: nil,
                                  acquisitions: [.viewOnly])
        // A cover is a request too: only from the module's hosts.
        func allowedCover(_ address: String) -> CoverReference? {
            safeURL(string: address)
                .flatMap { url in url.host.map { hosts.allowsRequest(to: $0) } == true ? url : nil }
                .map { .remote($0, headers: [:]) }
        }
        let cover = allowedCover(item.coverUrl) ?? .generated(seed: title)
        let summary = WorkSummary(title: title, authors: authors, cover: cover,
                                  blurb: OPDSClient.plainMetadata(item.intro, limit: WorkSummary.blurbLimit),
                                  language: language, contentKind: kind,
                                  category: WorkSummary.category(fromSourceKind: OPDSClient.plainMetadata(item.kind, limit: 200))
                                    ?? entry.tags(of: item).first,
                                  series: OPDSClient.plainMetadata(item.series ?? "", limit: WorkSummary.seriesLimit),
                                  seriesCovers: Array((item.seriesCovers ?? []).lazy.compactMap(allowedCover).prefix(WorkSummary.seriesCoverLimit)))
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
            .flatMap { $0.components(separatedBy: CharacterSet(charactersIn: ",，、/／;；\n")) }
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

extension RuleModule.Entry {
    /// `title` with the options `parameters` pick by name (今日熱門 · 日本): what tells two cards of
    /// one list apart, in a layout of lists and in its form.
    func cardName(_ title: String, parameters: [String: String]) -> String {
        let picked = editableParams.compactMap { param -> String? in
            guard param.kind == .enumeration, let value = parameters[param.name] else { return nil }
            return param.enumOptions?.first { $0.value == value }?.title
        }
        return ([title] + picked).joined(separator: " · ")
    }
}
