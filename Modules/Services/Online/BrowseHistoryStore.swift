import Combine
import Foundation

// MARK: - Browse History Entry

struct BrowseHistoryEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var url: String
    var host: String
    var date: Date

    enum CodingKeys: String, CodingKey { case id, title, url, host, date }
}

// MARK: - Browse History Store

/// Lightweight persistent log of web pages visited in the in-app browser.
/// Backs the 最近瀏覽 (recently browsed) section of the Explore tab.
final class BrowseHistoryStore: ObservableObject {
    static let shared = BrowseHistoryStore()

    @Published private(set) var entries: [BrowseHistoryEntry] = []

    private let storageKey = "browseHistory.v1"
    private let maxEntries = 80
    private let defaults = UserDefaults.standard

    private init() { load() }

    func record(title: String, url: String) {
        guard let parsed = URL(string: url),
              let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return }

        let host = parsed.host ?? ""
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var list = entries
        list.removeAll { $0.url == url }
        list.insert(
            BrowseHistoryEntry(
                title: cleanTitle.isEmpty ? host : cleanTitle,
                url: url,
                host: host,
                date: Date()
            ),
            at: 0
        )
        if list.count > maxEntries { list = Array(list.prefix(maxEntries)) }
        entries = list
        save()
    }

    func remove(_ entry: BrowseHistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    /// Best-effort favicon for a host (no network guarantee; AsyncImage falls back).
    func faviconURL(for entry: BrowseHistoryEntry) -> URL? {
        guard !entry.host.isEmpty else { return nil }
        return URL(string: "https://\(entry.host)/favicon.ico")
    }

    // MARK: - Persistence

    private func load() {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([BrowseHistoryEntry].self, from: data)
        else { return }
        entries = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
