import Foundation

/// One explore category of one source, addressed the way Legado addresses it: by the
/// source's URL plus the category's title and URL. Stable across launches and across
/// a source being re-imported (which mints a new id but keeps its URL).
struct ExploreCategoryReference: Codable, Hashable, Identifiable, Sendable {
    let sourceURL: String
    let title: String
    let url: String

    var id: String { "\(sourceURL)\u{1F}\(title)\u{1F}\(url)" }

    init(sourceURL: String, title: String, url: String) {
        self.sourceURL = sourceURL
        self.title = title
        self.url = url
    }

    init?(source: BookSource, item: DiscoverCardItem) {
        guard item.isFetchable, let url = item.raw.url else { return nil }
        self.init(sourceURL: source.bookSourceUrl, title: item.title, url: url)
    }

    var source: BookSource? {
        BookSourceStore.shared.sources.first { $0.bookSourceUrl == sourceURL }
    }

    /// The category as the discover pipeline consumes it.
    var cardItem: DiscoverCardItem? {
        DiscoverViewModel.mapItem(ModernParserBridge.DiscoverItem(title: title, url: url))
    }
}
