import CryptoKit
import Foundation

/// The books an OPDS, Calibre or Gutenberg row of the Explore home last drew, as the feed gave
/// them: what the home shows at the next launch while the row loads again
/// (`HomeSectionProviding.savedPage`; maintainer, 2026-11-07: 先顯示舊的、背景更新). Book sources
/// keep their pages in `ForYouCandidateStore` and modules in their own page cache
/// (`RuleModuleClient`); these feeds had nowhere, so every launch opened their rows on skeletons.
///
/// One file per row under `Caches/HomeFeeds`, keyed by the source and what the row loads, never by
/// a feed's address: a library's 「最新」 finds its feed when it loads (`OPDSFeed.newestURL`). The
/// raw entries, not the cards: the provider maps them as its load does, so a card from disk and a
/// card from the network are the same card. Regenerable, so in Caches and not backed up; 快取管理
/// clears it with `ForYouCandidateStore` (探索首頁快取).
actor HomeFeedPageStore {
    static let shared = HomeFeedPageStore(
        directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HomeFeeds", isDirectory: true))

    /// Rows kept at most; past it the oldest saved go first, down to four fifths. A home has a few
    /// dozen rows; rows of sections since removed are what this drops.
    static let capacity = 200

    struct Page: Codable, Sendable {
        let savedAt: Date
        let entries: [OPDSEntry]
    }

    /// What names a row's file: the source, and what the row loads (`HomeSection.loadsSameContent`
    /// apart from `drawsLists`, which a card's section already folds into its binding).
    private struct Key: Encodable {
        let source: String
        let binding: HomeSectionBinding
        let parameters: [String: String]
    }

    nonisolated let directory: URL
    private let capacity: Int
    private let now: @Sendable () -> Date

    init(directory: URL, capacity: Int = HomeFeedPageStore.capacity, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.capacity = capacity
        self.now = now
    }

    nonisolated func fileURL(source: SourceInstanceKey, section: HomeSection) -> URL? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let key: Data
        do {
            key = try encoder.encode(Key(source: "\(source.type.rawValue):\(source.id)", binding: section.binding,
                                         parameters: section.parameters))
        } catch {
            AppLogger.cache("⟐ home feed row has no key", error: error, context: ["source": source.id])
            return nil
        }
        let name = SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".json")
    }

    /// Saves the row's books, replacing what it drew before; an empty row is saved too, so a feed
    /// that emptied is not drawn from an older page.
    func write(_ entries: [OPDSEntry], source: SourceInstanceKey, section: HomeSection) {
        guard let file = fileURL(source: source, section: section) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(Page(savedAt: now(), entries: entries)).write(to: file, options: .atomic)
        } catch {
            AppLogger.cache("⟐ home feed row could not be saved", error: error, context: ["source": source.id])
            return
        }
        trim()
    }

    /// The row's books as last saved, nil when none were. A file an older build wrote in another
    /// shape reads as none: the row loads as it would have without it.
    func read(source: SourceInstanceKey, section: HomeSection) -> [OPDSEntry]? {
        guard let file = fileURL(source: source, section: section) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            AppLogger.cache("⟐ home feed row unreadable", error: error, context: ["source": source.id])
            return nil
        }
        do {
            return try JSONDecoder().decode(Page.self, from: data).entries
        } catch {
            AppLogger.cache("⟐ home feed row in another shape", error: error, context: ["source": source.id], level: .trace)
            return nil
        }
    }

    private func trim() {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
        } catch {
            AppLogger.cache("⟐ home feed rows could not be listed", error: error)
            return
        }
        guard files.count > capacity else { return }
        let dated = files.map { file -> (URL, Date) in
            do {
                return (file, try file.resourceValues(forKeys: keys).contentModificationDate ?? .distantPast)
            } catch {
                AppLogger.cache("⟐ home feed row could not be inspected", error: error)
                return (file, .distantPast)
            }
        }
        for (file, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - capacity * 4 / 5) {
            do {
                try FileManager.default.removeItem(at: file)
            } catch {
                AppLogger.cache("⟐ home feed row could not be removed", error: error)
            }
        }
    }
}

extension OPDSFeedProviding {
    /// A row's feed address as `browse` reads a location's: one that is not an address reads the
    /// root.
    func feedURL(_ id: String) throws -> URL {
        guard let url = URL(string: id) ?? rootURL else { throw SourceFailure(kind: .invalidAddress, underlying: OPDSError.invalidURL) }
        return url
    }

    /// A home row from one feed: its books, at most `HomeRow.limit`, as `browse` maps them. Saves
    /// those books, so the next launch draws them while the row loads again.
    func homeRow(from feed: OPDSFeed, for section: HomeSection, pages: HomeFeedPageStore) async -> [CollectionEntry] {
        let items = await CollectionPage.opds(from: feed, connectionID: instance.id, record: makeRecord, opening: makeOpening)
            .items(limit: HomeRow.limit)
        let record = makeRecord
        let books = Array(feed.entries.lazy.filter { record($0) != nil }.prefix(HomeRow.limit))
        await pages.write(books, source: instance, section: section)
        return items
    }

    func homeRow(_ url: URL, for section: HomeSection, pages: HomeFeedPageStore) async throws -> [CollectionEntry] {
        try await homeRow(from: feed(url, isSearch: false), for: section, pages: pages)
    }

    /// The row as an earlier launch saved it, mapped as its load maps it; nil when nothing, or
    /// nothing a card can show, was saved.
    func savedHomeRow(_ section: HomeSection, pages: HomeFeedPageStore) async -> [CollectionEntry]? {
        guard let books = await pages.read(source: instance, section: section), !books.isEmpty else { return nil }
        let items = await CollectionPage.opds(from: OPDSFeed(entries: books), connectionID: instance.id,
                                              record: makeRecord, opening: makeOpening).items(limit: HomeRow.limit)
        return items.isEmpty ? nil : items
    }
}
