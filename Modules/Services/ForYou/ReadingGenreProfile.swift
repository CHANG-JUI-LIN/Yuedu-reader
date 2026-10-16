import Foundation

/// The genres the reader opens, weighted by how often and how lately (Discovery Phase 7a-2,
/// maintainer's decision 3: recorded on the device). Local only: the shelf's data and the sync
/// format do not change.
struct ReadingGenreProfile: Codable, Equatable, Sendable {
    /// A tag's weight halves over this long.
    static let halfLife: TimeInterval = 30 * 24 * 60 * 60
    static let tagLimit = 200
    /// The same book opened again within this long counts once.
    static let reopenInterval: TimeInterval = 24 * 60 * 60

    private struct Weight: Codable, Equatable, Sendable {
        var value: Double
        /// When `value` was last set; it decays from here.
        var at: Date

        func value(at date: Date) -> Double {
            value * pow(0.5, max(0, date.timeIntervalSince(at)) / ReadingGenreProfile.halfLife)
        }
    }

    private var tags: [String: Weight] = [:]
    /// When each book last counted, for the once-a-day rule; older entries are dropped.
    private var opened: [UUID: Date] = [:]

    /// Adds 1 to each of `tags` (normalized), unless `book` already counted within a day.
    /// - Returns: whether anything was recorded.
    @discardableResult
    mutating func record(tags raw: [String], book: UUID, at date: Date) -> Bool {
        let keys = Self.normalizedTags(raw)
        guard !keys.isEmpty else { return false }
        if let last = opened[book], date.timeIntervalSince(last) < Self.reopenInterval { return false }
        opened = opened.filter { date.timeIntervalSince($0.value) < Self.reopenInterval }
        opened[book] = date
        for key in keys {
            tags[key] = Weight(value: (tags[key]?.value(at: date) ?? 0) + 1, at: date)
        }
        if tags.count > Self.tagLimit {
            let kept = tags.sorted { $0.value.value(at: date) > $1.value.value(at: date) }.prefix(Self.tagLimit)
            tags = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        }
        return true
    }

    /// Each tag's weight at `date`, the strongest scaled to 1. Empty for a new reader.
    func weights(at date: Date) -> [String: Double] {
        let values = tags.mapValues { $0.value(at: date) }
        guard let strongest = values.values.max(), strongest > 0 else { return [:] }
        return values.mapValues { $0 / strongest }
    }

    // MARK: Tags

    /// The one form tags are compared in: `WorkMatchKey`'s fold (NFKC, lowercase, Traditional →
    /// Simplified, no spaces or punctuation), without the ones that say nothing about a genre:
    /// one character, or only digits (a date, a count). In order, once each.
    static func normalizedTags(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        return raw.map(WorkMatchKey.title).filter { key in
            key.count >= 2 && !key.allSatisfy { $0.isASCII && $0.isNumber } && seen.insert(key).inserted
        }
    }

    /// A book source's `kind`, split where `WorkSummary.category(fromSourceKind:)` splits it.
    static func tags(fromSourceKind kind: String) -> [String] {
        normalizedTags(kind.prefix(1_000).components(separatedBy: WorkSummary.sourceKindSeparators))
    }

    /// A copy's tags: its own (`MetadataField.tags`: EPUB subjects, Calibre tags, Aozora's
    /// NDC), else the kind its book source gave it.
    static func tags(sidecar: ImportedMetadata?, sourceKind: String?) -> [String] {
        let own = sidecar?.values.filter { $0.field == .tags }.flatMap { value -> [String] in
            switch value.value {
            case .texts(let texts): return texts
            case .text(let text): return [text]
            case .number, .date: return []
            }
        } ?? []
        if !own.isEmpty { return normalizedTags(own) }
        return sourceKind.map(tags(fromSourceKind:)) ?? []
    }
}

/// Keeps the reader's `ReadingGenreProfile` in `Application Support/ForYou/genres.json`.
/// `BookStore.updateLastOpened`, which every reader's open path calls, tells it a book opened.
actor ReadingGenreRecorder {
    static let shared = ReadingGenreRecorder(
        fileURL: StorageLocations.support.appendingPathComponent("ForYou", isDirectory: true)
            .appendingPathComponent("genres.json"))

    private let fileURL: URL
    private let now: @Sendable () -> Date
    private var loaded: ReadingGenreProfile?

    init(fileURL: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.fileURL = fileURL
        self.now = now
    }

    func profile() -> ReadingGenreProfile {
        if let loaded { return loaded }
        let profile = load()
        loaded = profile
        return profile
    }

    func record(tags: [String], book: UUID) {
        var profile = profile()
        guard profile.record(tags: tags, book: book, at: now()) else { return }
        loaded = profile
        ForYouFile.write(profile, to: fileURL, label: "reading genres")
    }

    /// A book opened: its tags are read off the main thread (the copy's sidecar, else its book
    /// source's cached detail page) and recorded.
    nonisolated func bookOpened(_ book: ReadingBook, metadata: ImportedMetadataStore, sources: BookSourceStore) {
        let infoURL = book.isOnline ? book.bookInfoURL : nil
        let source = book.bookSourceId.flatMap(sources.source(id:))
        let id = book.id
        Task.detached(priority: .utility) {
            let sidecar = metadata.read(copyID: id)
            var kind: String?
            if let infoURL, !infoURL.isEmpty, let source {
                kind = BookSourceFetcher.shared.loadBookInfoPackageSync(url: infoURL, source: source, maximumAge: nil)?.kind
            }
            await self.record(tags: ReadingGenreProfile.tags(sidecar: sidecar, sourceKind: kind), book: id)
        }
    }

    private func load() -> ReadingGenreProfile {
        ForYouFile.read(ReadingGenreProfile.self, from: fileURL, label: "reading genres") ?? ReadingGenreProfile()
    }
}
