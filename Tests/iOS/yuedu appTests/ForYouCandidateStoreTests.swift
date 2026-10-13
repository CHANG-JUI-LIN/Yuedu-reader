import Foundation
import Testing
@testable import yuedu_app

// Discovery Phase 7a-1: the candidate cache 為你推薦 reads, and the one place a category's
// first page is fetched (`DiscoverFirstPages`), which the home's rows and 為你推薦 share.

private func book(_ name: String, source: UUID = UUID()) -> OnlineBook {
    OnlineBook(name: name, author: "作者", intro: "簡介", coverUrl: "/c/\(name).jpg", bookUrl: "https://src.test/book/\(name)",
               tocUrl: "", wordCount: "", lastChapter: "", kind: "玄幻,連載", sourceId: source, sourceName: "S",
               runtimeVariables: ["k": "v"])
}

private func scratchDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("ForYouCandidates-\(UUID().uuidString)", isDirectory: true)
}

@Suite("For You candidate store")
struct ForYouCandidateStoreTests {
    @Test("what is written reads back, the source's own fields included")
    func roundTrip() async throws {
        let store = ForYouCandidateStore(directory: scratchDirectory())
        let sourceID = UUID()
        let fetched = Date(timeIntervalSince1970: 1_800_000_000)
        await store.write(ForYouCandidates(sourceURL: "https://a.test", categoryURL: "/hot", fetchedAt: fetched,
                                           books: [book("甲", source: sourceID), book("乙", source: sourceID)]))
        let read = try #require(await store.read(sourceURL: "https://a.test", categoryURL: "/hot", sourceID: sourceID))
        #expect(read.books.map(\.name) == ["甲", "乙"])
        #expect(read.books.first?.kind == "玄幻,連載")
        #expect(read.books.first?.runtimeVariables == ["k": "v"])
        #expect(read.fetchedAt == fetched)
        #expect(await store.read(sourceURL: "https://a.test", categoryURL: "/new", sourceID: sourceID) == nil)
    }

    @Test("a category is fresh for 12 hours")
    func freshness() {
        let fetched = Date(timeIntervalSince1970: 1_800_000_000)
        let candidates = ForYouCandidates(sourceURL: "s", categoryURL: "c", fetchedAt: fetched, books: [])
        #expect(candidates.isFresh(at: fetched.addingTimeInterval(11 * 3600 + 59 * 60)))
        #expect(!candidates.isFresh(at: fetched.addingTimeInterval(12 * 3600 + 60)))
    }

    @Test("at most the first 40 books are kept")
    func cap() async throws {
        let store = ForYouCandidateStore(directory: scratchDirectory())
        let id = UUID()
        await store.write(ForYouCandidates(sourceURL: "s", categoryURL: "c", fetchedAt: Date(),
                                           books: (0..<50).map { book("\($0)", source: id) }))
        let read = try #require(await store.read(sourceURL: "s", categoryURL: "c", sourceID: id))
        #expect(read.books.count == ForYouCandidates.limit)
        #expect(ForYouCandidates.limit == 40)
    }

    @Test("an undecodable file reads as absent, and says so in the log")
    func undecodable() async throws {
        let directory = scratchDirectory()
        let store = ForYouCandidateStore(directory: directory)
        let sourceURL = "https://undecodable-\(UUID().uuidString).test"
        let file = store.fileURL(sourceURL: sourceURL, categoryURL: "/hot")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file)
        let before = Set(DiagnosticLog.shared.snapshot().map(\.id))

        #expect(await store.read(sourceURL: sourceURL, categoryURL: "/hot", sourceID: UUID()) == nil)
        let lines = DiagnosticLog.shared.snapshot().filter { !before.contains($0.id) && $0.message.contains(sourceURL) }
        #expect(lines.count == 1)
    }

    @Test("a re-imported source's books carry its new id")
    func reimportedSource() async throws {
        let store = ForYouCandidateStore(directory: scratchDirectory())
        await store.write(ForYouCandidates(sourceURL: "s", categoryURL: "c", fetchedAt: Date(), books: [book("甲")]))
        let current = UUID()
        let read = try #require(await store.read(sourceURL: "s", categoryURL: "c", sourceID: current))
        #expect(read.books.map(\.sourceId) == [current])
    }
}

/// Records each fetch and holds it until the test releases it, so what runs at once can be seen
/// without timing.
private actor FetchProbe {
    private(set) var log: [String] = []
    private var gates: [String: CheckedContinuation<Void, Never>] = [:]
    private var opened: Set<String> = []
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func record(_ entry: String) {
        log.append(entry)
        let ready = waiters.filter { log.count >= $0.count }
        waiters.removeAll { log.count >= $0.count }
        ready.forEach { $0.continuation.resume() }
    }

    /// A fetch waits here until `release(_:)`.
    func hold(_ name: String) async {
        if opened.contains(name) { return }
        await withCheckedContinuation { gates[name] = $0 }
    }

    func release(_ name: String) {
        opened.insert(name)
        gates.removeValue(forKey: name)?.resume()
    }

    /// Returns once `count` entries are logged.
    func waitForEntries(_ count: Int) async {
        if log.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
}

@MainActor
@Suite("Discover first pages")
struct DiscoverFirstPagesTests {
    private func source(_ url: String) -> BookSource {
        BookSource(bookSourceUrl: url, bookSourceName: url)
    }

    private func category(_ source: BookSource, _ url: String) -> ExploreCategoryReference {
        ExploreCategoryReference(sourceURL: source.bookSourceUrl, title: url, url: url)
    }

    private func pages(_ probe: FetchProbe, store: ForYouCandidateStore = ForYouCandidateStore(directory: scratchDirectory()))
        -> DiscoverFirstPages {
        DiscoverFirstPages(
            pageLoader: SectionPageLoader { item, _, source in
                let name = "\(source.bookSourceUrl)\(item.url ?? "")"
                await probe.record("fetch \(name)")
                await probe.hold(name)
                return [book("\(name)-1", source: source.id), book("\(name)-2", source: source.id)]
            },
            primeCookies: { await probe.record("prime \($0.bookSourceUrl)") },
            store: store)
    }

    @Test("two asks for one category send one request")
    func joins() async throws {
        let probe = FetchProbe()
        let pages = pages(probe)
        let a = source("a")
        let first = pages.firstPage(of: category(a, "/hot"), in: a)
        let second = pages.firstPage(of: category(a, "/hot"), in: a)
        await probe.release("a/hot")
        let books = try await first.value
        #expect(try await second.value.map(\.name) == books.map(\.name))
        #expect(await probe.log == ["prime a", "fetch a/hot"])
    }

    @Test("one source's categories wait their turn; another source's do not")
    func lanes() async throws {
        let probe = FetchProbe()
        let pages = pages(probe)
        let a = source("a"), b = source("b")
        let hot = pages.firstPage(of: category(a, "/hot"), in: a)
        let new = pages.firstPage(of: category(a, "/new"), in: a)
        let other = pages.firstPage(of: category(b, "/hot"), in: b)

        await probe.waitForEntries(4)
        let started = await probe.log
        #expect(Set(started) == ["prime a", "fetch a/hot", "prime b", "fetch b/hot"])

        await probe.release("a/hot")
        _ = try await hot.value
        await probe.waitForEntries(5)
        #expect(await probe.log.last == "fetch a/new")
        await probe.release("a/new")
        await probe.release("b/hot")
        _ = try await new.value
        _ = try await other.value
        #expect(await probe.log.filter { $0.hasPrefix("prime") }.count == 2)
    }

    @Test("priming runs again after a new sync")
    func primingPerSync() async throws {
        let probe = FetchProbe()
        let pages = pages(probe)
        let a = source("a")
        await probe.release("a/hot")
        await probe.release("a/new")
        _ = try await pages.firstPage(of: category(a, "/hot"), in: a).value
        _ = try await pages.firstPage(of: category(a, "/new"), in: a).value
        pages.beginSync()
        _ = try await pages.firstPage(of: category(a, "/hot"), in: a).value
        #expect(await probe.log == ["prime a", "fetch a/hot", "fetch a/new", "prime a", "fetch a/hot"])
    }

    @Test("a row's first page is written to the candidate store")
    func rowWritesTheStore() async throws {
        let probe = FetchProbe()
        let store = ForYouCandidateStore(directory: scratchDirectory())
        let pages = pages(probe, store: store)
        let a = source("a")
        let provider = BookSourceProvider(source: a, firstPages: pages)
        await probe.release("a/hot")
        let entries = try await provider.load(HomeSection(layout: .row, binding: .sourceCategories([category(a, "/hot")])))
        #expect(entries.count == 2)
        let cached = try #require(await store.read(sourceURL: "a", categoryURL: "/hot", sourceID: a.id))
        #expect(cached.books.map(\.name) == ["a/hot-1", "a/hot-2"])
    }

    @Test("a failure is rethrown, and the next ask fetches again")
    func failure() async throws {
        struct Down: Error {}
        let calls = FetchProbe()
        let pages = DiscoverFirstPages(
            pageLoader: SectionPageLoader { _, _, _ in
                await calls.record("fetch")
                throw Down()
            },
            primeCookies: { _ in },
            store: ForYouCandidateStore(directory: scratchDirectory()))
        let a = source("a")
        await #expect(throws: Down.self) { try await pages.firstPage(of: category(a, "/hot"), in: a).value }
        await #expect(throws: Down.self) { try await pages.firstPage(of: category(a, "/hot"), in: a).value }
        #expect(await calls.log == ["fetch", "fetch"])
    }
}
