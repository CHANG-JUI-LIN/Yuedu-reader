import CryptoKit
import Foundation

/// One book-source category's first page as 為你推薦 last saw it (Discovery Phase 7a-1,
/// maintainer's decision 2: a local cache, refetched after 12 hours).
struct ForYouCandidates: Codable, Sendable {
    /// How long a category's books stand before 為你推薦 asks for them again.
    static let freshness: TimeInterval = 12 * 60 * 60
    /// The most kept per category: a first page, never more.
    static let limit = 40

    let sourceURL: String
    let categoryURL: String
    let fetchedAt: Date
    var books: [OnlineBook]

    init(sourceURL: String, categoryURL: String, fetchedAt: Date, books: [OnlineBook]) {
        self.sourceURL = sourceURL
        self.categoryURL = categoryURL
        self.fetchedAt = fetchedAt
        self.books = Array(books.prefix(Self.limit))
    }

    func isFresh(at now: Date) -> Bool {
        now.timeIntervalSince(fetchedAt) < Self.freshness
    }
}

/// The candidate cache: one file per category under `Caches/ForYou`, regenerable, so it is
/// not backed up. Written by `DiscoverFirstPages` on every first page it fetches, read by
/// 為你推薦. An actor, so writes are atomic and in order.
actor ForYouCandidateStore {
    static let shared = ForYouCandidateStore(
        directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ForYou", isDirectory: true))

    nonisolated let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    nonisolated func fileURL(sourceURL: String, categoryURL: String) -> URL {
        let digest = Insecure.MD5.hash(data: Data((sourceURL + "|" + categoryURL).utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".json")
    }

    func write(_ candidates: ForYouCandidates) {
        let file = fileURL(sourceURL: candidates.sourceURL, categoryURL: candidates.categoryURL)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(candidates).write(to: file, options: .atomic)
        } catch {
            AppLogger.cache("⟐ for-you candidates could not be saved", error: error, context: [
                "source": candidates.sourceURL, "category": candidates.categoryURL,
            ])
        }
    }

    /// The category's saved books, nil when none were saved or the file cannot be read.
    /// - Parameter sourceID: the source's id now. A re-imported source keeps its URL but has a
    ///   new id, and a book opens through the source its id names.
    func read(sourceURL: String, categoryURL: String, sourceID: UUID) -> ForYouCandidates? {
        let file = fileURL(sourceURL: sourceURL, categoryURL: categoryURL)
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            AppLogger.cache("⟐ for-you candidates unreadable", error: error, context: [
                "source": sourceURL, "category": categoryURL,
            ])
            return nil
        }
        do {
            var candidates = try JSONDecoder().decode(ForYouCandidates.self, from: data)
            for index in candidates.books.indices { candidates.books[index].sourceId = sourceID }
            return candidates
        } catch {
            AppLogger.cache("⟐ for-you candidates unreadable", error: error, context: [
                "source": sourceURL, "category": categoryURL,
            ])
            return nil
        }
    }

    /// Every saved category's books whose source is in `sources` (its URL → its id now), for
    /// 作品詳情's versions (7b-1): what the reader's sources listed, read with no request.
    /// Ordered by source, then category, so a source's first book is always the same one.
    func savedBooks(sources: [String: UUID]) -> [OnlineBook] {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
        } catch CocoaError.fileReadNoSuchFile {
            return []
        } catch {
            AppLogger.cache("⟐ for-you candidates folder unreadable", error: error, context: [:])
            return []
        }
        var saved: [ForYouCandidates] = []
        for file in files {
            do {
                saved.append(try JSONDecoder().decode(ForYouCandidates.self, from: Data(contentsOf: file)))
            } catch {
                AppLogger.cache("⟐ for-you candidates unreadable", error: error, context: ["file": file.lastPathComponent])
            }
        }
        return saved.sorted { ($0.sourceURL, $0.categoryURL) < ($1.sourceURL, $1.categoryURL) }.flatMap { candidates in
            guard let id = sources[candidates.sourceURL] else { return [OnlineBook]() }
            return candidates.books.map { book in
                var book = book
                book.sourceId = id
                return book
            }
        }
    }
}
