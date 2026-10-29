import CryptoKit
import Foundation
import Testing
@testable import yuedu_app

/// Bytes the app's `UserDefaults` plists take while sources are searched, a shelf is
/// refreshed and a book is read.
///
/// 3.0.0 (140) MetricKit disk-write exception, 4295 MB (Crashlytics
/// afe8e4bd855dd39d55423aab8a7a721b): every sampled write was CFPrefs's own flush timer
/// (`-[CFPDSource createDiskWrite]`), so no stack names the writer. A flush writes a changed
/// suite's whole plist again. CFPrefs leaves a suite alone when a value is set to what it
/// already holds (measured on the simulator: no rewrite within 30 s for an equal string or an
/// equal rebuilt dictionary, while a changed value or a remove-then-set rewrote it), so what
/// costs bytes is a value that really changes, times the size of the plist it lands in.
///
/// The writer: a search rule's `java.put` runs once per result row and stored the row's id in
/// the one suite every source shared — 40,091 B per search page with 86 sources' state in it.
/// A rule's `@put` never reaches that store, and an unchanged refresh or reading on writes no
/// preferences at all.
///
/// The simulator flushes on its own schedule, so the file's inode is no signal; each
/// measurement compares a suite's contents before and after, and a changed suite counts its
/// whole plist once — one flush, as on a device where the operations are seconds apart. Each
/// prints one `PREFSWRITE …` line.
@Suite("UserDefaults disk writes", .serialized)
@MainActor
struct UserDefaultsDiskWriteTests {
    /// The suite all sources shared before 2026-10-29; measured so a return to it fails here.
    private static let legacyRuntimeSuite = "com.yuedu.bookSourceRuntimeState"
    private static let loginSuite = "com.yuedu.loginStore"
    private static let groupSuite = "group.com.zhangruilin.yuedureader"
    private static let standardName = "standard"

    /// A suite's own keys: what CFPrefs keeps in its plist, without the global and
    /// registration domains every `UserDefaults` also answers from.
    private static func contents(_ name: String) -> NSDictionary {
        let defaults = name == standardName ? UserDefaults.standard : UserDefaults(suiteName: name)
        guard let all = defaults?.dictionaryRepresentation() else { return [:] }
        let shared = UserDefaults(suiteName: "com.yuedu.diskwrite.baseline")?.dictionaryRepresentation() ?? [:]
        var own = all
        for (key, value) in shared where (own[key] as AnyObject?)?.isEqual(value) == true {
            own.removeValue(forKey: key)
        }
        return own as NSDictionary
    }

    private static func plistSize(_ dictionary: NSDictionary) -> Int {
        (try? PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0).count) ?? 0
    }

    /// Runs `operation` and returns, per suite whose contents changed, the bytes of its plist.
    private static func measure(
        _ name: String, suites: [String], _ operation: () async throws -> Void
    ) async rethrows -> [String: Int] {
        let before = Dictionary(uniqueKeysWithValues: suites.map { ($0, contents($0)) })
        try await operation()
        var written: [String: Int] = [:]
        for suite in suites where contents(suite) != before[suite] {
            written[suite] = plistSize(contents(suite))
        }
        let total = written.values.reduce(0, +)
        let detail = written.sorted { $0.value > $1.value }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        print("PREFSWRITE op=\(name) bytes=\(total) suites=\(written.count) \(detail)")
        return written
    }

    // MARK: - Fixtures

    /// The field report's 86 sources, each with what sources keep through `source.put` /
    /// `java.put` (an id, a page, a token) and, for one in eight, a `source.setVariable`
    /// settings object.
    private static func seedSourceState() -> [String] {
        let store = BookSourceRuntimeStateStore.shared
        let urls = (0..<86).map { "https://diskwrite-seed-\($0).example.com" }
        for (index, url) in urls.enumerated() {
            store.setSourceValue("\(index * 7919)", for: url, key: "bid")
            store.setSourceValue("1", for: url, key: "page")
            store.setSourceValue(String(repeating: "t\(index)", count: 64), for: url, key: "token")
            if index % 8 == 0 {
                let settings = (0..<40).map { "\"選項\($0)\":\"值\($0)\"" }.joined(separator: ",")
                store.setSourceVariableJSON("{\(settings)}", for: url)
            }
        }
        return urls
    }

    private static func removeSourceState(_ urls: [String]) {
        for url in urls {
            UserDefaults.standard.removePersistentDomain(forName: BookSourceRuntimeStateStore.shared.suiteName(for: url))
        }
    }

    /// A search source the way 53 of 1301 sources in two public collections write their
    /// search rules: each row's book id kept with `@put`, read back by the detail page.
    private static func searchSource() -> BookSource {
        var source = BookSource()
        source.bookSourceName = "寫入測試搜尋"
        source.bookSourceUrl = "https://diskwrite-search-\(UUID().uuidString).example.com"
        source.ruleSearch.bookList = "$.data[*]"
        source.ruleSearch.name = "$.name"
        source.ruleSearch.author = "$.author"
        source.ruleSearch.bookUrl = "$.url@put:{bid:$.id}"
        return source
    }

    private static func searchPage(_ page: Int) -> String {
        let rows = (0..<20).map { row in
            #"{"id":"\#(page * 100 + row)","name":"書 \#(page)-\#(row)","author":"作者","url":"https://example.com/book/\#(page * 100 + row)"}"#
        }
        return #"{"data":[\#(rows.joined(separator: ","))]}"#
    }

    private static func chapters(_ count: Int, book: Int) -> [OnlineChapterRef] {
        (0..<count).map {
            OnlineChapterRef(index: $0, title: "第\($0 + 1)章", url: "https://example.com/book/\(book)/\($0 + 1).html")
        }
    }

    // MARK: - Tests

    /// The writer behind the 4.3 GB: each row's id stored through a script's `java.put`.
    /// Before 2026-10-29 every page rewrote all 86 sources' state (40,091 B); now only the
    /// searching source's own small plist changes.
    @Test("a search page whose rule calls java.put rewrites only its own source's state")
    func scriptedPutSearchRewritesOnlyItsOwnSource() async throws {
        let seeded = Self.seedSourceState()
        var source = Self.searchSource()
        source.ruleSearch.bookUrl = "$.url@js:java.put('bid', String(java.getString('$.id'))); result"
        let store = BookSourceRuntimeStateStore.shared
        let ownSuite = store.suiteName(for: source.bookSourceUrl)
        defer { Self.removeSourceState(seeded + [source.bookSourceUrl]) }
        let suites = [Self.legacyRuntimeSuite, ownSuite] + seeded.map(store.suiteName(for:))

        let bridge = ModernParserBridge(source: source)
        for page in 0..<5 {
            let written = try await Self.measure("search.jsPutPage", suites: suites) {
                _ = try bridge.parseSearchResults(
                    html: Self.searchPage(page), baseURL: "https://example.com/search?p=\(page)", source: source
                )
            }
            #expect(Set(written.keys) == [ownSuite])
            #expect(written.values.reduce(0, +) < 1024)
        }
    }

    @Test("a search page whose rule uses @put, searched again, writes nothing")
    func unchangedSearchWritesNothing() async throws {
        let seeded = Self.seedSourceState()
        let source = Self.searchSource()
        let store = BookSourceRuntimeStateStore.shared
        defer { Self.removeSourceState(seeded + [source.bookSourceUrl]) }
        let suites = [Self.standardName, Self.legacyRuntimeSuite, store.suiteName(for: source.bookSourceUrl)]
            + seeded.map(store.suiteName(for:))
        let bridge = ModernParserBridge(source: source)
        _ = try bridge.parseSearchResults(html: Self.searchPage(0), baseURL: "https://example.com/search?p=0", source: source)

        let written = try await Self.measure("search.samePageAgain", suites: suites) {
            _ = try bridge.parseSearchResults(html: Self.searchPage(0), baseURL: "https://example.com/search?p=0", source: source)
        }
        #expect(written.isEmpty)
    }

    @Test("a refresh of 40 unchanged online books, then reading on, writes no preferences")
    func unchangedRefreshAndReadingWriteNothing() async throws {
        let suites = [Self.standardName, Self.groupSuite, Self.legacyRuntimeSuite, Self.loginSuite]
        let source = BookSource(bookSourceUrl: "https://diskwrite-shelf.example.com", bookSourceName: "寫入測試")
        let restoreSources = BookSourceStore.shared.sources
        BookSourceStore.shared.replaceSources([source])
        defer { BookSourceStore.shared.replaceSources(restoreSources) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrefsDiskWrite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let added = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let books: [ReadingBook] = (0..<40).map { index in
            var book = ReadingBook(title: "線上書 \(index)", author: "作者", source: "https://example.com/book/\(index)", contentFilename: "")
            book.addedDate = added.addingTimeInterval(Double(index))
            book.isOnline = true
            book.contentPipelineKind = .html
            book.bookSourceId = source.id
            book.bookInfoURL = "https://example.com/book/\(index)"
            book.tocURL = "https://example.com/toc/\(index)"
            book.onlineChapters = Self.chapters(400, book: index)
            book.applyChapterSummary(from: book.onlineChapters ?? [])
            if index == 0 { book.lastOpenedDate = added.addingTimeInterval(10_000); book.currentPosition = 0.2 }
            return book
        }
        let store = BookStore(metadataFileURL: directory.appendingPathComponent("books_meta.json"))
        store.replaceBooksFromSync(books)
        store.flushPendingMetadataSave()
        store.waitForQueuedWrites()

        let refresh = try await Self.measure("refresh.40unchanged", suites: suites) {
            for (index, book) in books.enumerated() {
                _ = try await store.refreshOnlineBookMetadata(
                    bookId: book.id,
                    bookSourceFetcher: PrefsFixedTOCFetcher(package: TOCPackage(
                        sourceId: source.id, sourceName: source.bookSourceName,
                        tocURL: "https://example.com/toc/\(index)", runtimeVariables: nil,
                        chapters: Self.chapters(400, book: index), rawHTMLFilename: nil, savedAt: Date()
                    ))
                )
            }
            store.flushPendingMetadataSave()
            store.waitForQueuedWrites()
        }
        #expect(refresh.isEmpty)
        let reading = await Self.measure("reading.10steps", suites: suites) {
            for step in 1...10 {
                store.updatePosition(bookId: books[0].id, position: 0.2 + Double(step) * 0.003)
                store.flushPendingMetadataSave()
                store.waitForQueuedWrites()
            }
        }
        #expect(reading.isEmpty)
    }
}

/// Earlier builds' one shared suite, moved into per-source suites the first time the store
/// opens. It holds sources' logins, tokens and settings, so a slip here loses them silently.
@Suite("Source runtime state moves out of the shared suite", .serialized)
struct BookSourceRuntimeStateMoveTests {
    private static func legacyKey(_ sourceUrl: String, _ field: String) -> String {
        let digest = SHA256.hash(data: Data(sourceUrl.utf8)).map { String(format: "%02x", $0) }.joined()
        return "bookSourceRuntime.\(digest).\(field)"
    }

    @Test("each source's values land in its own suite and stale device ids are dropped")
    func sharedSuiteMovesIntoSourceSuites() throws {
        let sharedName = "com.yuedu.test.runtimeMove.\(UUID().uuidString)"
        let loggedIn = "https://move-login.example.com"
        let configured = "https://move-settings.example.com"
        let shared = try #require(UserDefaults(suiteName: sharedName))
        shared.set(["androidId": UUID().uuidString, "token": "abc"], forKey: Self.legacyKey(loggedIn, "sourceKeyValues"))
        shared.set(#"{"線路":"2"}"#, forKey: Self.legacyKey(configured, "sourceVariableJSON"))

        let store = BookSourceRuntimeStateStore(sharedSuiteName: sharedName)
        defer {
            for name in [sharedName, store.suiteName(for: loggedIn), store.suiteName(for: configured)] {
                UserDefaults.standard.removePersistentDomain(forName: name)
            }
        }

        #expect(store.sourceValue(for: loggedIn, key: "token") == "abc")
        #expect(store.sourceValue(for: loggedIn, key: "androidId") == nil)
        #expect(store.sourceVariableJSON(for: configured) == #"{"線路":"2"}"#)
        let own = try #require(UserDefaults(suiteName: store.suiteName(for: loggedIn)))
        #expect(own.dictionary(forKey: "sourceKeyValues") as? [String: String] == ["token": "abc"])
        let left = try #require(UserDefaults(suiteName: sharedName)).dictionaryRepresentation().keys
            .filter { $0.hasPrefix("bookSourceRuntime.") }
        #expect(left.isEmpty)

        let reopened = BookSourceRuntimeStateStore(sharedSuiteName: sharedName)
        #expect(reopened.sourceValue(for: loggedIn, key: "token") == "abc")
        #expect(reopened.sourceVariableJSON(for: configured) == #"{"線路":"2"}"#)
    }

    @Test("a suite already purged of stale device ids keeps them as they are")
    func purgedSuiteKeepsDeviceIds() throws {
        let sharedName = "com.yuedu.test.runtimeMove.\(UUID().uuidString)"
        let url = "https://move-purged.example.com"
        let deviceId = UUID().uuidString
        let shared = try #require(UserDefaults(suiteName: sharedName))
        shared.set(true, forKey: "bookSourceRuntime.didPurgeLegacyAndroidIds")
        shared.set(["androidId": deviceId], forKey: Self.legacyKey(url, "sourceKeyValues"))

        let store = BookSourceRuntimeStateStore(sharedSuiteName: sharedName)
        defer {
            for name in [sharedName, store.suiteName(for: url)] {
                UserDefaults.standard.removePersistentDomain(forName: name)
            }
        }

        #expect(store.sourceValue(for: url, key: "androidId") == deviceId)
    }
}

/// Answers a table-of-contents refresh with a fixed package.
private struct PrefsFixedTOCFetcher: BookSourceFetching {
    let package: TOCPackage

    func fetchBookInfoPackage(
        url: String, source: BookSource, runtimeVariables: [String: String]?, knownBook: OnlineBook?
    ) async throws -> BookInfoPackage {
        throw NSError(domain: "PrefsFixedTOCFetcher", code: 1)
    }

    func fetchTOCPackage(
        tocUrl: String, source: BookSource, runtimeVariables: [String: String]?,
        onFirstPageReady: (([OnlineChapterRef]) -> Void)?, forceRefresh: Bool
    ) async throws -> TOCPackage {
        onFirstPageReady?(package.chapters)
        return package
    }

    func isChapterCached(
        bookId: UUID, chapterIndex: Int, expectedSourceURL: String?, expectedTOCTitle: String?
    ) -> Bool { false }
    func clearChapterCache(bookId: UUID, chapterIndex: Int) {}
    func clearAllChapterCache(bookId: UUID) {}
    func search(query: String, in source: BookSource) async throws -> [OnlineBook] { [] }
    func search(
        query: String, in source: BookSource, earlyFilter: ((String, String) -> Bool)?
    ) async throws -> [OnlineBook] { [] }
    func loadChapterPackageSync(
        bookId: UUID, chapterIndex: Int, expectedSourceURL: String?, expectedTOCTitle: String?
    ) -> ChapterPackage? { nil }
    func loadNormalizedChapterHTMLSync(
        bookId: UUID, chapterIndex: Int, expectedSourceURL: String?, expectedTOCTitle: String?
    ) -> String? { nil }
}
