import Foundation

/// Aozora Bunko's bundled catalog as a collection (unified library 2a). It projects the
/// same `AozoraCatalogStore` index the Aozora screens read; it loads nothing of its own.
///
/// Locations: 新着作品, 作家別, 作品名別 and 分類別 at the root; kana or classification
/// groups below them; a person below an author group. Lists of works page by offset.
@MainActor
final class AozoraProvider: CollectionBrowsing {
    static let pageSize = 100

    private let catalog: @MainActor () -> AozoraCatalogIndex?
    private let availabilitySource: PublicLibraryAvailability

    convenience init(store: AozoraCatalogStore, availability: PublicLibraryAvailability) {
        self.init(catalog: { store.catalog }, availability: availability)
    }

    init(catalog: @escaping @MainActor () -> AozoraCatalogIndex?, availability: PublicLibraryAvailability) {
        self.catalog = catalog
        availabilitySource = availability
    }

    var instance: SourceInstanceKey { SourceInstanceKey(type: .aozora, id: PublicLibraryID.aozora.rawValue) }
    var displayName: String { localized("青空文庫") }
    var availability: ProviderAvailability {
        guard availabilitySource.isAvailable else { return .hiddenInRegion }
        return catalog() == nil ? .catalogNotReady : .available
    }

    func capabilities() async -> CollectionCapabilities {
        CollectionCapabilities(search: .asYouType, paginates: true)
    }

    func browse(_ location: CollectionLocation?, after cursor: CollectionCursor?) async throws -> CollectionPage {
        guard let index = catalog() else {
            throw SourceFailure(kind: .unavailable, underlying: SourceFailure.Message(text: localized("此目錄沒有內容")))
        }
        guard let location else {
            return CollectionPage(entries: [
                ("new", "新着作品"), ("authors", "作家別"), ("titles", "作品名別"), ("categories", "分類別"),
            ].map { .location(CollectionLocation(id: $0.0, title: localized($0.1))) }, next: nil)
        }
        let parts = location.id.split(separator: "/", maxSplits: 1).map(String.init)
        switch (parts.first, parts.count) {
        case ("new", 1):
            return page(of: index.newWorks, index: index, cursor: cursor)
        case ("authors", 1), ("titles", 1), ("categories", 1):
            return CollectionPage(entries: groups(parts[0], in: index).map {
                .location(CollectionLocation(id: "\(parts[0])/\($0.id)", title: localized($0.titleKey)))
            }, next: nil)
        case ("authors", 2):
            let ids = groups("authors", in: index).first { $0.id == parts[1] }?.ids ?? []
            return CollectionPage(entries: ids.compactMap { index.personsByID[$0] }.map {
                .location(CollectionLocation(id: "person/\($0.id)", title: $0.name))
            }, next: nil)
        case ("titles", 2), ("categories", 2):
            let ids = groups(parts[0], in: index).first { $0.id == parts[1] }?.ids ?? []
            return page(of: ids.compactMap { index.worksByID[$0] }, index: index, cursor: cursor)
        case ("person", 2):
            return page(of: index.works(forPerson: parts[1]), index: index, cursor: cursor)
        default:
            return CollectionPage(entries: [], next: nil)
        }
    }

    private func groups(_ mode: String, in index: AozoraCatalogIndex) -> [AozoraIndexGroup] {
        switch mode {
        case "authors": index.authorGroups
        case "titles": index.titleGroups
        default: index.classificationGroups
        }
    }

    private func page(of works: [AozoraWork], index: AozoraCatalogIndex, cursor: CollectionCursor?) -> CollectionPage {
        let start = cursor.flatMap { Int($0.value) } ?? 0
        let slice = works.dropFirst(start).prefix(Self.pageSize)
        let entries: [CollectionEntry] = slice.map { work in
            let authors = work.credits.compactMap { index.personsByID[$0.person]?.name }
            let record = SourceRecord.derived(from: work)
            return .item(record, WorkSummary(title: work.title, authors: authors, cover: .generated(seed: work.title),
                                             blurb: nil, language: "ja", contentKind: .text))
        }
        let end = start + slice.count
        return CollectionPage(entries: entries, next: end < works.count ? CollectionCursor(value: String(end)) : nil)
    }
}
