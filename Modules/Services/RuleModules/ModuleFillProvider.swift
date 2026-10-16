import Foundation

/// An installed module as a metadata provider (Phase 6h): a shelf copy whose description or
/// categories are empty is searched for by title through the module's `search`, and a result
/// whose title and author both match (level B) gives them, as a 來源配置's search result does
/// (`BookSourceFillProvider`). Nothing else: a same-name book's cover or identifiers are never
/// taken.
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
    /// an author cannot be matched.
    func canLookUp(_ query: MetadataFillQuery) -> Bool {
        provider.module.search != nil
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
        let page: CollectionPage?
        do {
            page = try await LibrarySearch.within(timeout) { try await provider.search(title) }
        } catch {
            SourcePerfTrace.record("metadata.fill.module", "module=\(provider.module.id) outcome=failed",
                                   since: started, thresholdMs: 0)
            throw error
        }
        let result = Self.result(from: page?.entries ?? [], query: query)
        SourcePerfTrace.record("metadata.fill.module", "module=\(provider.module.id) items=\(page?.entries.count ?? 0) filled=\(result.values.count)",
                               since: started, thresholdMs: 0)
        return result
    }

    /// The first match with a description gives it, and its categories; without one, the
    /// first match with categories gives those.
    static func result(from entries: [CollectionEntry], query: MetadataFillQuery) -> MetadataFillResult {
        let titleKey = WorkMatchKey.title(query.title)
        let authorKeys = query.authors.map(WorkMatchKey.author)
        let matches = entries.compactMap { entry -> (record: SourceRecord, intro: String, tags: [String])? in
            guard case .item(let record, let summary, _) = entry,
                  !titleKey.isEmpty, WorkMatchKey.title(summary.title) == titleKey,
                  WorkMatchKey.authorKeysCompatible(authorKeys, summary.authors.map(WorkMatchKey.author)) else { return nil }
            let intro = (summary.blurb ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // An item keeps one category (`WorkSummary.category(fromSourceKind:)`), the one
            // 作品詳情 shows for it.
            return (record, intro, BookSourceFillProvider.tags(from: summary.category ?? ""))
        }
        guard let chosen = matches.first(where: { query.missing.contains(.intro) && !$0.intro.isEmpty })
            ?? matches.first(where: { query.missing.contains(.tags) && !$0.tags.isEmpty }) else {
            return MetadataFillResult(values: [:])
        }
        var values: [MetadataField: MetadataPayload] = [:]
        if query.missing.contains(.intro), !chosen.intro.isEmpty { values[.intro] = .text(chosen.intro) }
        if query.missing.contains(.tags), !chosen.tags.isEmpty { values[.tags] = .texts(chosen.tags) }
        return MetadataFillResult(values: values, sourceItem: chosen.record.key)
    }
}
