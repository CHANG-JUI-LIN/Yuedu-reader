import Foundation

/// An installed module as a metadata provider (Phase 6h).
///
/// **Lookup** (module ecosystem M4, level A): a copy with an ISBN-13 that the module's
/// `lookup.isbnPrefixes` take is asked by that ISBN; the record whose own `isbn` is the same is
/// the copy's, so it may give a cover (from the module's hosts only), a description, tags, a
/// publisher and a series.
///
/// **Search** (level B): a copy whose description or categories are still empty is searched for
/// by title, and the one result that is the same work gives them. Nothing else: a same-name
/// book's cover or identifiers are never taken. The same work (M3, guardrail 5, **for veto**:
/// it was "the first match"):
/// - its title or one of its `aliases` is the copy's title (`WorkMatchKey`), its author is
///   compatible with the copy's, and it is the copy's kind (a comic from a comic);
/// - exactly one result is; two are a question this cannot answer, and nothing is filled.
///
/// A summary in another script is left out (an English one for a Chinese copy), and, from a
/// search, so is a Japanese one for a copy whose title has no kana; tags keep the copy title's
/// script.
///
/// Asked in the order 資料來源 lists it, checked by default (maintainer, 2026-10-15).
@MainActor
final class ModuleFillProvider: MetadataFillProvider {
    /// The fields a search result can give.
    static let fields: Set<MetadataField> = [.intro, .tags]
    /// The fields the copy's own record can give.
    static let lookupFields: Set<MetadataField> = [.cover, .intro, .tags, .publisher, .series]
    /// The filler asks copy after copy: a site that hangs must not hold up the rest.
    nonisolated static let timeout: Duration = .seconds(20)

    let key: SourceInstanceKey
    /// A: the runner keeps a cover wanted and the record's identifiers. The search part still
    /// gives neither.
    let grade: MetadataMatchGrade
    private let provider: ModuleProvider
    private let timeout: Duration
    private let coverDirectory: URL

    init(provider: ModuleProvider, timeout: Duration = ModuleFillProvider.timeout,
         coverDirectory: URL = FilledMetadata.coverDirectory) {
        self.provider = provider
        self.timeout = timeout
        self.coverDirectory = coverDirectory
        key = provider.instance
        grade = provider.module.lookup == nil ? .b : .a
    }

    /// A copy that came from this module has its values already. Otherwise: by ISBN when the
    /// lookup takes one of the copy's; by title when it has a title and an author; a comic only
    /// where the entry lists comics.
    func canLookUp(_ query: MetadataFillQuery) -> Bool {
        guard query.copySource != key else { return false }
        return lookupISBN(for: query) != nil || canSearch(query, missing: query.missing)
    }

    /// The copy's first ISBN-13 the lookup takes, in order.
    func lookupISBN(for query: MetadataFillQuery) -> String? {
        guard let lookup = provider.module.lookup, lookup.listedKinds.contains(query.contentKind),
              !query.missing.isDisjoint(with: Self.lookupFields) else { return nil }
        let prefixes = lookup.isbnPrefixes ?? []
        return query.identifiers.filter { $0.scheme == .isbn13 }.map(\.value).sorted()
            .first { isbn in prefixes.isEmpty || prefixes.contains { isbn.hasPrefix($0) } }
    }

    private func canSearch(_ query: MetadataFillQuery, missing: Set<MetadataField>) -> Bool {
        guard let search = provider.module.search else { return false }
        return search.listedKinds.contains(query.contentKind)
            && !query.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && query.authors.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && !missing.isDisjoint(with: Self.fields)
    }

    /// Throws when a request failed or timed out (the ledger asks again after a week); empty
    /// when the module has no such book.
    func lookUp(_ query: MetadataFillQuery) async throws -> MetadataFillResult {
        let provider = provider
        var result = MetadataFillResult(values: [:])
        if let isbn = lookupISBN(for: query), let lookup = provider.module.lookup {
            let started = SourcePerfTrace.now
            do {
                result = try await lookUp(isbn: isbn, of: lookup, query: query)
            } catch {
                SourcePerfTrace.record("metadata.fill.module.lookup", "module=\(provider.module.id) outcome=failed",
                                       since: started, thresholdMs: 0)
                throw error
            }
            SourcePerfTrace.record("metadata.fill.module.lookup", "module=\(provider.module.id) filled=\(result.values.count)",
                                   since: started, thresholdMs: 0)
        }
        // What the record did not give, a title search may: a different question, not a retry.
        let remaining = query.missing.subtracting(result.values.keys)
        guard canSearch(query, missing: remaining), let search = provider.module.search else { return result }
        var rest = query
        rest.missing = remaining
        let found = try await self.search(rest, entry: search)
        result.values.merge(found.values) { mine, _ in mine }
        if result.sourceItem == nil { result.sourceItem = found.sourceItem }
        return result
    }

    private func search(_ query: MetadataFillQuery, entry: RuleModule.Entry) async throws -> MetadataFillResult {
        let started = SourcePerfTrace.now
        let provider = provider
        let title = query.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let items: [RuleListItem]
        do {
            items = try await LibrarySearch.within(timeout) { try await provider.searchItems(title) } ?? []
        } catch {
            SourcePerfTrace.record("metadata.fill.module", "module=\(provider.module.id) outcome=failed",
                                   since: started, thresholdMs: 0)
            throw error
        }
        let result = Self.result(from: items, of: entry, query: query, record: { item in
            guard case .item(let record, _, _) = provider.searchEntry(item) else { return nil }
            return record.key
        })
        SourcePerfTrace.record("metadata.fill.module", "module=\(provider.module.id) items=\(items.count) filled=\(result.values.count)",
                               since: started, thresholdMs: 0)
        return result
    }

    private func lookUp(isbn: String, of lookup: RuleModule.Entry, query: MetadataFillQuery) async throws -> MetadataFillResult {
        let provider = provider
        let items = try await LibrarySearch.within(timeout) { try await provider.lookupItems(isbn: isbn) } ?? []
        guard let item = Self.record(in: items, isbn: isbn) else { return MetadataFillResult(values: [:]) }
        var values = Self.lookupValues(item, of: lookup, query: query)
        if query.missing.contains(.cover), !item.coverUrl.trimmingCharacters(in: .whitespaces).isEmpty,
           let data = try await LibrarySearch.within(timeout, { try await provider.coverImage(item.coverUrl) }) {
            // One file per module and book: a cover of another module's is never replaced.
            let name = "module-\(provider.module.id)-\(isbn).jpg"
            try FileManager.default.createDirectory(at: coverDirectory, withIntermediateDirectories: true)
            try data.write(to: coverDirectory.appendingPathComponent(name), options: .atomic)
            values[.cover] = .text(name)
        }
        guard !values.isEmpty, case .item(let record, _, _) = provider.searchEntry(item, of: lookup) else {
            return MetadataFillResult(values: values)
        }
        return MetadataFillResult(values: values, sourceItem: record.key)
    }

    /// The record that is the copy's: its own ISBN is the one asked.
    static func record(in items: [RuleListItem], isbn: String) -> RuleListItem? {
        items.first { item in item.isbn.flatMap { ExternalIdentifier.normalized(.isbn13, $0)?.value } == isbn }
    }

    /// The record's values, without a cover (which is fetched).
    static func lookupValues(_ item: RuleListItem, of entry: RuleModule.Entry, query: MetadataFillQuery) -> [MetadataField: MetadataPayload] {
        let script = WritingScript(of: query.title)
        var values: [MetadataField: MetadataPayload] = [:]
        if query.missing.contains(.intro) {
            let intro = OnlineBookDetailPresentationPolicy.sanitizeIntro(item.intro, indentParagraphs: false)
            if !intro.isEmpty, WritingScript(of: intro) == script { values[.intro] = .text(intro) }
        }
        if query.missing.contains(.tags) {
            let tags = entry.tags(of: item).filter { WritingScript(of: $0) == script }
            if !tags.isEmpty { values[.tags] = .texts(tags) }
        }
        for (field, value) in [(MetadataField.publisher, item.publisher), (.series, item.series)] where query.missing.contains(field) {
            let text = OPDSClient.plainMetadata(value ?? "", limit: 200)
            if !text.isEmpty { values[field] = .text(text) }
        }
        return values
    }

    /// The values of the one item that is the copy's work; `record` names it in the sidecar.
    static func result(from items: [RuleListItem], of entry: RuleModule.Entry, query: MetadataFillQuery,
                       record: (RuleListItem) -> SourceItemKey?) -> MetadataFillResult {
        let titleKey = WorkMatchKey.title(query.title)
        guard !titleKey.isEmpty else { return MetadataFillResult(values: [:]) }
        var seen = Set<String>()
        let matches = items.filter { item in
            entry.contentKind(of: item) == query.contentKind
                && ([item.name] + (item.aliases ?? [])).contains { WorkMatchKey.title($0) == titleKey }
                && WorkMatchKey.authorsCompatible(query.authors, Self.names(item.author))
                // One work listed twice is still one.
                && seen.insert(item.bookUrl.isEmpty ? "\(item.name)\u{1F}\(item.author)" : item.bookUrl).inserted
        }
        guard matches.count == 1, let item = matches.first else { return MetadataFillResult(values: [:]) }

        let script = WritingScript(of: query.title)
        var values: [MetadataField: MetadataPayload] = [:]
        if query.missing.contains(.intro) {
            let intro = OnlineBookDetailPresentationPolicy.sanitizeIntro(item.intro, indentParagraphs: false)
            if !intro.isEmpty, WritingScript(of: intro) == script,
               !JapaneseText.isJapanese(intro) || JapaneseText.isJapanese(query.title) {
                values[.intro] = .text(intro)
            }
        }
        if query.missing.contains(.tags) {
            let tags = entry.tags(of: item).filter { WritingScript(of: $0) == script }
            if !tags.isEmpty { values[.tags] = .texts(tags) }
        }
        return MetadataFillResult(values: values, sourceItem: values.isEmpty ? nil : record(item))
    }

    /// An author value naming several people (`山田鐘人、アベツカサ`).
    private static func names(_ author: String) -> [String] {
        author.components(separatedBy: CharacterSet(charactersIn: "、,，/／;；\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

extension RuleModule.Entry {
    /// The kinds its items can be: the entry's, and comics when an item rule can say so.
    nonisolated var listedKinds: Set<ContentKind> {
        var kinds: Set<ContentKind> = [contentKind.flatMap(ContentKind.init(rawValue:)) ?? .text]
        if !(list.contentKind ?? "").trimmingCharacters(in: .whitespaces).isEmpty { kinds.insert(.comic) }
        return kinds
    }
}

/// Whether a text is Japanese rather than Chinese: kana make up a twentieth of its letters.
/// `WritingScript` counts both as CJK; this tells a Japanese summary from a Chinese one.
enum JapaneseText {
    nonisolated static func isJapanese(_ text: String) -> Bool {
        var kana = 0, letters = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            letters += 1
            if (0x3040...0x30FF).contains(scalar.value) { kana += 1 }
        }
        return letters > 0 && kana * 20 >= letters
    }
}
