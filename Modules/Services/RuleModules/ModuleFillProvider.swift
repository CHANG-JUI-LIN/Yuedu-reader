import Foundation

/// An installed module as a metadata provider (Phase 6h): a shelf copy whose description or
/// categories are empty is searched for by title through the module's `search`, and the one
/// result that is the same work (level B) gives them. Nothing else: a same-name book's cover
/// or identifiers are never taken.
///
/// The same work (module ecosystem M3, guardrail 5, **for veto**: it was "the first match"):
/// - its title or one of its `aliases` is the copy's title (`WorkMatchKey`), its author is
///   compatible with the copy's, and it is the copy's kind (a comic from a comic);
/// - exactly one result is; two are a question this cannot answer, and nothing is filled.
///
/// A summary in another script is left out (an English one for a Chinese copy), and so is a
/// Japanese one for a copy whose title has no kana; tags keep the copy title's script.
///
/// Asked in the order 資料來源 lists it, checked by default (maintainer, 2026-10-15).
@MainActor
final class ModuleFillProvider: MetadataFillProvider {
    /// The fields a search result can give.
    static let fields: Set<MetadataField> = [.intro, .tags]
    /// The filler asks copy after copy: a site that hangs must not hold up the rest.
    nonisolated static let timeout: Duration = .seconds(20)

    let key: SourceInstanceKey
    let grade: MetadataMatchGrade = .b
    private let provider: ModuleProvider
    private let timeout: Duration

    init(provider: ModuleProvider, timeout: Duration = ModuleFillProvider.timeout) {
        self.provider = provider
        self.timeout = timeout
        key = provider.instance
    }

    /// A copy that came from this module has its values already; a copy without a title and
    /// an author cannot be matched; a comic is asked only of a module whose search lists comics.
    func canLookUp(_ query: MetadataFillQuery) -> Bool {
        guard let search = provider.module.search else { return false }
        return search.listedKinds.contains(query.contentKind)
            && query.copySource != key
            && !query.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && query.authors.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && !query.missing.isDisjoint(with: Self.fields)
    }

    /// Throws when the search failed or timed out (the ledger asks again after a week);
    /// empty when the module has no such book.
    func lookUp(_ query: MetadataFillQuery) async throws -> MetadataFillResult {
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
        let result = provider.module.search.map {
            Self.result(from: items, of: $0, query: query, record: { item in
                guard case .item(let record, _, _) = provider.searchEntry(item) else { return nil }
                return record.key
            })
        } ?? MetadataFillResult(values: [:])
        SourcePerfTrace.record("metadata.fill.module", "module=\(provider.module.id) items=\(items.count) filled=\(result.values.count)",
                               since: started, thresholdMs: 0)
        return result
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
