import Foundation

// Unified library 5b: what each source puts on the Explore home (design §5, §13.3; Phase 5
// plan, 5b). Two departures from §5's draft, both recorded in the plan:
// - A row is the source's first page only. 查看全部 opens the source's own page, which
//   already pages, so `load` takes no page number.
// - The policy is asked per section, not once per provider: Gutenberg's bundled lists send no
//   request while its feeds load with the home, and a book source serves 「最新」 only once
//   the reader has picked the category that stands for it.

/// When a section may send its request.
enum SectionLoadPolicy: Hashable, Sendable {
    /// No request: bundled or on-device data.
    case local
    /// One request at a time per source. Book sources: their rules share one runtime, and
    /// `BookSourceSession` does not serialize discover fetches — they take no turn, only
    /// their script halves run on the source's host (`BookSourceFetcher+Discover.swift`) —
    /// so the home does.
    case serialPerSource
    case parallel
    /// As soon as the home is on screen, wherever the row sits on the page, in parallel:
    /// Gutenberg's feeds (Phase 5 plan, decision 15). Nothing before 探索 opens, and no next
    /// page until the reader asks for one (`Technotes/PublicLibraries.md`).
    case withHome
}

@MainActor
protocol HomeSectionProviding: SourceProvider {
    /// How `section` loads from this provider, or nil when this provider does not serve it.
    func loadPolicy(for section: HomeSection) -> SectionLoadPolicy?
    /// The first page of `section`'s row. Throws `SourceFailure`; an empty row is not a failure.
    func load(_ section: HomeSection) async throws -> [CollectionEntry]
    /// What `section` reads besides itself, as a key: a row whose key changed loads again.
    /// 為你推薦 reads the home's categories; every other section reads only itself (nil).
    func inputsKey(for section: HomeSection) -> String?
    /// Whether its rows read the home's library rows (為你推薦): such a row loads again when a
    /// library row comes or goes, e.g. 顯示在最新 turned off.
    var readsHomeLibraryRows: Bool { get }
}

extension HomeSectionProviding {
    func inputsKey(for section: HomeSection) -> String? { nil }
    var readsHomeLibraryRows: Bool { false }
}

enum HomeRow {
    /// The most a row shows; 查看全部 shows the rest.
    static let limit = 20
}

// MARK: - The shelf

extension ShelfProvider: HomeSectionProviding {
    func loadPolicy(for section: HomeSection) -> SectionLoadPolicy? {
        switch section.binding {
        case .continueReading, .related, .nextInSeries: .local
        default: nil
        }
    }

    func load(_ section: HomeSection) async throws -> [CollectionEntry] {
        switch section.binding {
        case .continueReading: continueReading(limit: HomeRow.limit)
        case .related: await related(limit: HomeRow.limit)
        case .nextInSeries: await nextInSeries(limit: HomeRow.limit)
        default: []
        }
    }
}

// MARK: - OPDS and Calibre

extension OPDSProvider: HomeSectionProviding {
    func loadPolicy(for section: HomeSection) -> SectionLoadPolicy? {
        switch section.binding {
        case .latest: .parallel
        case .opdsFeed(let connectionID, _): connectionID == instance.id ? .parallel : nil
        default: nil
        }
    }

    /// 「最新」 (§13.3): the catalog's newest additions where its root links them
    /// (`OPDSFeed.newestURL`, Phase 5 follow-up 5), else the root's own books, else the first
    /// navigation feed's.
    func load(_ section: HomeSection) async throws -> [CollectionEntry] {
        switch section.binding {
        case .opdsFeed(_, let url):
            return try await browse(CollectionLocation(id: url, title: ""), after: nil).items(limit: HomeRow.limit)
        case .latest:
            guard let rootURL else { throw SourceFailure(kind: .invalidAddress, underlying: OPDSError.invalidURL) }
            let feed = try await feed(rootURL, isSearch: false)
            if let newest = feed.newestURL {
                return try await browse(CollectionLocation(id: newest.absoluteString, title: ""), after: nil)
                    .items(limit: HomeRow.limit)
            }
            let root = await CollectionPage.opds(from: feed, connectionID: instance.id, record: makeRecord, opening: makeOpening)
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
        case .gutenbergLists: return .local
        case .gutenbergFeed: return .withHome
        case .gutenbergShelf(let id): return GutenbergShelf.shelf(id: id) == nil ? nil : .withHome
        case .latest: return .withHome
        default: return nil
        }
    }

    func load(_ section: HomeSection) async throws -> [CollectionEntry] {
        switch section.binding {
        case .gutenbergCollection(let id):
            guard let collection = PublicLibraryCollection.all.first(where: { $0.id == id }) else { return [] }
            return collection.books.map(CollectionEntry.bundledGutenberg)
        case .gutenbergLists:
            return PublicLibraryCollection.all.map { .collection(.bundledGutenberg($0)) }
        case .gutenbergFeed(let url):
            return try await browse(CollectionLocation(id: url, title: ""), after: nil).items(limit: HomeRow.limit)
        case .gutenbergShelf(let id):
            guard let shelf = GutenbergShelf.shelf(id: id) else { return [] }
            return try await browse(CollectionLocation(id: shelf.url.absoluteString, title: ""), after: nil).items(limit: HomeRow.limit)
        case .latest:
            let url = GutenbergEndpoint.current.latestURL.absoluteString
            return try await browse(CollectionLocation(id: url, title: ""), after: nil).items(limit: HomeRow.limit)
        default:
            return []
        }
    }
}

extension CollectionEntry {
    /// A book of Gutenberg's bundled lists, with Gutenberg's own cover (decision 15): the list
    /// sends no request, its covers load as their cards show.
    static func bundledGutenberg(_ book: GutenbergBook) -> CollectionEntry {
        .item(SourceRecord.derived(from: book),
              WorkSummary(title: book.title, authors: book.author.isEmpty ? [] : [book.author],
                          cover: book.coverURL.map { .remote($0, headers: [:]) } ?? .generated(seed: book.title),
                          blurb: nil, language: book.language, contentKind: .text),
              .gutenberg(book))
    }
}

extension CollectionSummary {
    /// A Gutenberg bundled list, its first books with Gutenberg's own covers, as its row has them.
    static func bundledGutenberg(_ collection: PublicLibraryCollection) -> CollectionSummary {
        let books = collection.books.compactMap { book -> WorkSummary? in
            guard case .item(_, let summary, _) = CollectionEntry.bundledGutenberg(book) else { return nil }
            return summary
        }
        return CollectionSummary(id: collection.id, title: localized(collection.titleKey), books: books,
                                 languages: collection.books.compactMap(\.language),
                                 opening: .gutenbergCollection(id: collection.id))
    }
}

// MARK: - Aozora

extension AozoraProvider: HomeSectionProviding {
    /// Read from the bundled catalog; nothing is served until it is read.
    func loadPolicy(for section: HomeSection) -> SectionLoadPolicy? {
        guard availability == .available else { return nil }
        switch section.binding {
        case .aozoraNew, .aozoraIndex: return .local
        case .latest: return .local
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
        guard case .latest = section.binding, records != nil else { return nil }
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
