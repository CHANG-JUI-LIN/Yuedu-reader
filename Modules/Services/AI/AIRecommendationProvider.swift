import Foundation

/// AI 推薦 on the Explore home (AI 推薦 plan 8c): the stored list, served with no request.
///
/// The home's row draws from `AIRecommendationStore` directly through `entries(from:)`, the
/// same builder `load` uses, so a new list or an Open Library match shows in place without the
/// row passing through its loading state (AI 推薦 plan review: a home sync per match would
/// flash the placeholder about twenty times while covers arrive).
@MainActor
final class AIRecommendationProvider: HomeSectionProviding {
    /// The section's source. `.library`, like 為你推薦: on-device data, not a library row that
    /// 為你推薦 would mix in (`HomeModel.isLibrary`).
    static let instanceKey = SourceInstanceKey(type: .library, id: "aiRecommendations")
    /// The record of a suggestion Open Library did not match: data only, named 「AI 推薦」 in
    /// 作品詳情 (`FilledMetadata.providerName`).
    static let recordInstance = SourceInstanceKey(type: .bibliographic, id: "aiRecommendations")

    private let store: AIRecommendationStore

    init(store: AIRecommendationStore? = nil) {
        self.store = store ?? .shared
    }

    var instance: SourceInstanceKey { Self.instanceKey }
    var displayName: String { localized("AI 推薦") }
    var availability: ProviderAvailability { .available }
    var hosts: [String] { [] }

    func loadPolicy(for section: HomeSection) -> SectionLoadPolicy? {
        section.binding == .aiRecommendations ? .local : nil
    }

    func load(_ section: HomeSection) async throws -> [CollectionEntry] {
        guard section.binding == .aiRecommendations, let list = store.list else { return [] }
        return Self.entries(from: list)
    }

    /// Each work as a data-only item that opens 作品詳情: Open Library's record when it matched,
    /// otherwise one of its own. The title and author are the ones the AI gave.
    static func entries(from list: AIRecommendationList) -> [CollectionEntry] {
        list.entries.map { entry in
            let record = record(for: entry)
            let summary = WorkSummary(title: entry.work.title, authors: [entry.work.author],
                                      cover: entry.cover ?? .generated(seed: entry.work.title), blurb: entry.blurb,
                                      language: record.language, contentKind: .text)
            return .item(record, summary, .bibliographic)
        }
    }

    /// Each work's reason by its record's key (AI 推薦 8e); a blank one is left out.
    static func reasons(from list: AIRecommendationList) -> [SourceItemKey: String] {
        list.entries.reduce(into: [:]) { reasons, entry in
            let reason = entry.work.reason.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reason.isEmpty else { return }
            let key = record(for: entry).key
            if reasons[key] == nil { reasons[key] = reason }
        }
    }

    private static func record(for entry: AIRecommendationList.Entry) -> SourceRecord {
        entry.openLibrary ?? SourceRecord(
            key: SourceItemKey(instance: recordInstance, item: entry.id), title: entry.work.title,
            authors: [entry.work.author], language: nil, contentKind: .text, identifiers: [], copyID: nil,
            acquisitions: [.viewOnly])
    }
}
