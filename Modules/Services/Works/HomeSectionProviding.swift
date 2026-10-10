import Foundation

// Unified library 5b: what each source puts on the Explore home (design §5, §13.3; Phase 5
// plan, 5b). Two departures from §5's draft, both recorded in the plan:
// - A row is the source's first page only. 查看全部 opens the source's own page, which
//   already pages, so `load` takes no page number.
// - The policy is asked per section, not once per provider: Gutenberg's bundled lists send no
//   request while its feeds wait for the reader, and a book source serves 「最新」 only once
//   the reader has picked the category that stands for it.

/// When a section may send its request.
enum SectionLoadPolicy: Hashable, Sendable {
    /// No request: bundled or on-device data.
    case local
    /// One request at a time per source. Book sources: their rules share one runtime, and
    /// `BookSourceSession` does not serialize discover fetches
    /// (`BookSourceFetcher+Discover.swift`, `bridgeForAsyncOperations`), so the home does.
    case serialPerSource
    case parallel
    /// Only when the reader asks: Gutenberg's terms (`Technotes/PublicLibraries.md`).
    case onDemandOnly
}

@MainActor
protocol HomeSectionProviding: SourceProvider {
    /// How `section` loads from this provider, or nil when this provider does not serve it.
    func loadPolicy(for section: HomeSection) -> SectionLoadPolicy?
    /// The first page of `section`'s row. Throws `SourceFailure`; an empty row is not a failure.
    func load(_ section: HomeSection) async throws -> [CollectionEntry]
}

enum HomeRow {
    /// The most a row shows; 查看全部 shows the rest.
    static let limit = 20
}

// MARK: - The shelf

extension ShelfProvider: HomeSectionProviding {
    func loadPolicy(for section: HomeSection) -> SectionLoadPolicy? {
        switch section.binding {
        case .continueReading, .related: .local
        default: nil
        }
    }

    func load(_ section: HomeSection) async throws -> [CollectionEntry] {
        switch section.binding {
        case .continueReading: continueReading(limit: HomeRow.limit)
        case .related: await related(limit: HomeRow.limit)
        default: []
        }
    }
}

// MARK: - OPDS and Calibre

extension OPDSProvider: HomeSectionProviding {
    func loadPolicy(for section: HomeSection) -> SectionLoadPolicy? {
        switch section.binding {
        case .latest(let excluded): excluded.contains(instance) ? nil : .parallel
        case .opdsFeed(let connectionID, _): connectionID == instance.id ? .parallel : nil
        default: nil
        }
    }

    /// 「最新」 (§13.3): the root's own books, or else the first navigation feed's. The parser
    /// keeps no `rel` on navigation entries, so a feed's `sort/new` link cannot be found yet.
    func load(_ section: HomeSection) async throws -> [CollectionEntry] {
        switch section.binding {
        case .opdsFeed(_, let url):
            return try await browse(CollectionLocation(id: url, title: ""), after: nil).items(limit: HomeRow.limit)
        case .latest:
            let root = try await browse(nil, after: nil)
            let items = root.items(limit: HomeRow.limit)
            if !items.isEmpty { return items }
            guard let first = root.entries.firstLocation else { return [] }
            return try await browse(first, after: nil).items(limit: HomeRow.limit)
        default:
            return []
        }
    }
}

// MARK: - Gutenberg

extension GutenbergProvider: HomeSectionProviding {
    func loadPolicy(for section: HomeSection) -> SectionLoadPolicy? {
        guard availability == .available else { return nil }
        switch section.binding {
        case .gutenbergCollection(let id): return PublicLibraryCollection.all.contains { $0.id == id } ? .local : nil
        case .gutenbergFeed: return .onDemandOnly
        case .latest(let excluded): return excluded.contains(instance) ? nil : .onDemandOnly
        default: return nil
        }
    }

    func load(_ section: HomeSection) async throws -> [CollectionEntry] {
        switch section.binding {
        case .gutenbergCollection(let id):
            guard let collection = PublicLibraryCollection.all.first(where: { $0.id == id }) else { return [] }
            return collection.books.map { book in
                .item(SourceRecord.derived(from: book),
                      WorkSummary(title: book.title, authors: book.author.isEmpty ? [] : [book.author],
                                  cover: .generated(seed: book.title), blurb: nil, language: nil, contentKind: .text),
                      .gutenberg(book))
            }
        case .gutenbergFeed(let url):
            return try await browse(CollectionLocation(id: url, title: ""), after: nil).items(limit: HomeRow.limit)
        case .latest:
            let url = GutenbergEndpoint.current.latestURL.absoluteString
            return try await browse(CollectionLocation(id: url, title: ""), after: nil).items(limit: HomeRow.limit)
        default:
            return []
        }
    }
}

// MARK: - Aozora

extension AozoraProvider: HomeSectionProviding {
    /// Read from the bundled catalog; nothing is served until it is read.
    func loadPolicy(for section: HomeSection) -> SectionLoadPolicy? {
        guard availability == .available else { return nil }
        switch section.binding {
        case .aozoraNew, .aozoraIndex: return .local
        case .latest(let excluded): return excluded.contains(instance) ? nil : .local
        default: return nil
        }
    }

    /// 新着 is a row of works; an index is its groups, as locations.
    func load(_ section: HomeSection) async throws -> [CollectionEntry] {
        switch section.binding {
        case .aozoraNew, .latest:
            return try await browse(CollectionLocation(id: "new", title: ""), after: nil).items(limit: HomeRow.limit)
        case .aozoraIndex(let kind):
            return Array(try await browse(CollectionLocation(id: kind, title: ""), after: nil).entries.prefix(HomeRow.limit))
        default:
            return []
        }
    }
}

// MARK: - WebDAV

extension WebDAVProvider: HomeSectionProviding {
    /// 「最新」 reads the 2d index, so a connection that has none serves no row.
    func loadPolicy(for section: HomeSection) -> SectionLoadPolicy? {
        guard case .latest(let excluded) = section.binding, !excluded.contains(instance), records != nil else { return nil }
        return .local
    }

    /// The indexed books, newest on the server first; a file with no date goes last.
    func load(_ section: HomeSection) async throws -> [CollectionEntry] {
        guard case .latest = section.binding, let records else { return [] }
        let connectionID = connection.id
        guard let newest = await Self.newestFiles(in: records, connectionID: connectionID, limit: HomeRow.limit) else { return [] }
        return newest.files.map { Self.item(for: $0, root: newest.root, connectionID: connectionID) }
    }

    /// An indexed file as a home item, for 「最新」 and 「相關」 alike.
    nonisolated static func item(for file: IndexedFile, root: URL, connectionID: String) -> CollectionEntry {
        let url = WebDAVMetadataFiller.url(of: file, under: root)
        let entry = WebDAVBrowseClient.Entry(url: url, name: url.lastPathComponent, isDirectory: false, size: file.size,
                                             etag: file.etag, lastModified: file.lastModified)
        let cover: CoverReference = file.cover.map { .copyFile(WebDAVIndexCoordinator.defaultCoverDirectory.appendingPathComponent($0).path) }
            ?? .generated(seed: file.record.title)
        return .item(file.record,
                     WorkSummary(title: file.record.title, authors: file.record.authors, cover: cover,
                                 blurb: nil, language: file.record.language, contentKind: file.record.contentKind),
                     .webDAVFile(entry, connectionID: connectionID))
    }

    /// Reads the index and picks the newest files off the main actor: at Phase 2's measured
    /// size (20,000 books) this took 2.99 s on the main actor in Debug, most of it one
    /// `DateFormatter` per file (Phase 5 plan, 5b fixes).
    nonisolated static func newestFiles(in records: RemoteRecordStore, connectionID: String,
                                        limit: Int) async -> (root: URL, files: [IndexedFile])? {
        let started = SourcePerfTrace.now
        guard let state = records.state(connectionID: connectionID) else { return nil }
        let dated = state.visibleFiles.map { ($0, $0.lastModified.flatMap(serverDate)) }
        let newest = dated.sorted { lhs, rhs in
            switch (lhs.1, rhs.1) {
            case let (l?, r?): l > r
            case (_?, nil): true
            default: false
            }
        }.prefix(limit).map(\.0)
        SourcePerfTrace.record("home.webdav.latest", "files=\(dated.count)", since: started, thresholdMs: 0)
        return (state.root, Array(newest))
    }

    /// `getlastmodified` is an HTTP date. The fixed RFC 1123 form every server sends
    /// (`Tue, 01 Oct 2024 08:00:00 GMT`) is read by position: `DateFormatter` cost 1.4 s for
    /// 20,000 files in Debug. Any other form (RFC 850, asctime) goes to the formatter.
    nonisolated static func serverDate(_ text: String) -> Date? {
        fixedHTTPDate(text) ?? httpDateFormatter.date(from: text)
    }

    private nonisolated static func fixedHTTPDate(_ text: String) -> Date? {
        let bytes = Array(text.utf8)
        guard bytes.count == 29, bytes[3] == UInt8(ascii: ","), bytes[4] == 0x20, bytes[7] == 0x20, bytes[11] == 0x20,
              bytes[16] == 0x20, bytes[19] == UInt8(ascii: ":"), bytes[22] == UInt8(ascii: ":"), bytes[25] == 0x20,
              bytes[26...28].elementsEqual("GMT".utf8) else { return nil }
        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for byte in bytes[range] {
                guard (0x30...0x39).contains(byte) else { return nil }
                value = value * 10 + Int(byte - 0x30)
            }
            return value
        }
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        guard let name = String(bytes: bytes[8..<11], encoding: .ascii), let monthIndex = months.firstIndex(of: name),
              let day = number(5..<7), let year = number(12..<16), let hour = number(17..<19),
              let minute = number(20..<22), let second = number(23..<25),
              (1...31).contains(day), hour < 24, minute < 60, second < 61 else { return nil }
        // Days from 1970-01-01 to the civil date (Howard Hinnant's days_from_civil).
        let month = monthIndex + 1
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146_097 + dayOfEra - 719_468
        return Date(timeIntervalSince1970: TimeInterval(days * 86_400 + hour * 3_600 + minute * 60 + second))
    }

    /// One formatter for the other forms: parsing is thread-safe.
    private nonisolated static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()
}

// MARK: - Helpers

extension CollectionPage {
    /// The page's items, without its locations.
    func items(limit: Int) -> [CollectionEntry] {
        Array(entries.filter { if case .item = $0 { return true } else { return false } }.prefix(limit))
    }
}

extension Array where Element == CollectionEntry {
    var firstLocation: CollectionLocation? {
        for entry in self { if case .location(let location) = entry { return location } }
        return nil
    }
}
