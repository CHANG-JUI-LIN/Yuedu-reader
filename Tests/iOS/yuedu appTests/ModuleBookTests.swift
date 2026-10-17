import Foundation
import Testing
@testable import yuedu_app

/// Module ecosystem plan, M5b: a module's book on the shelf — one copy under its list item's
/// key, its chapters read and cached through the module, its list checked for new chapters,
/// and its module kept through a sync with a build that does not know the field.
@MainActor
@Suite("Module books", .serialized)
struct ModuleBookTests {
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Narou")
    private static let bookURL = "https://ncode.syosetu.com/n9669bk/"

    private func page(_ name: String) throws -> String {
        try String(contentsOf: Self.fixtures.appendingPathComponent(name), encoding: .utf8)
    }

    private struct Setup {
        let folder: URL
        let store: BookStore
        let reader: ModuleBookReader
    }

    private func setup(_ module: RuleModule? = Self.narou) -> Setup {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ModuleBooks-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModuleStub.self]
        let client = RuleModuleClient(fetcher: WebFetcher(session: URLSession(configuration: configuration)),
                                      store: RuleModuleStore(directory: folder.appendingPathComponent("modules")))
        return Setup(folder: folder, store: BookStore(metadataFileURL: folder.appendingPathComponent("books_meta.json")),
                     reader: ModuleBookReader(client: client, module: { id in id == module?.id ? module : nil }))
    }

    static let narou: RuleModule = {
        var module = RuleModule(id: "test.narou", title: "なろう", description: nil, author: nil, site: nil, version: "1.0",
                                requiredVersion: "3.0", hosts: ["ncode.syosetu.com"], rateLimit: nil, modules: [], search: nil)
        module.reading = ModuleReadingTests.narouReading
        return module
    }()

    private static let book = ModuleBook(reference: ModuleBookReference(moduleID: "test.narou", bookURL: bookURL),
                                         title: "無職転生", author: "理不尽な孫の手", coverURL: nil, contentKind: .text)

    @Test("reading a module's book makes one copy off the shelf, under its item's key; 加入書架 shelves that copy")
    func readingCopy() async throws {
        let setup = setup()
        defer { try? FileManager.default.removeItem(at: setup.folder) }
        ModuleStub.install(["ncode.syosetu.com/n9669bk": .html(try page("narou-toc-p3.html"))])
        let shelf = ModuleBookShelf(reader: setup.reader)

        let copy = try await shelf.readingCopy(Self.book, store: setup.store)
        #expect(!copy.isInBookshelf, "read without 加入書架 stays off the shelf")
        #expect(copy.module == Self.book.reference)
        #expect(copy.isOnline && copy.bookSourceId == nil && copy.chaptersBuiltByRules)
        #expect(copy.title == "無職転生" && copy.author == "理不尽な孫の手")
        let chapters = try #require(setup.store.chapters(for: copy.id))
        #expect(chapters.count == copy.onlineChapters?.count)
        #expect(chapters.contains { $0.isVolume && $0.url.isEmpty }, "a 章 heading is a volume")
        #expect(chapters.first { !$0.isVolume }?.url.hasPrefix("https://ncode.syosetu.com/n9669bk/") == true)
        #expect(copy.totalChapterNum == chapters.count)

        let key = SourceRecord.derived(from: copy, context: .live()).key
        #expect(key == SourceRecord.derived(from: Self.book).key, "the copy is the list item's, so the item shows it is on the shelf")
        #expect(key == SourceItemKey(instance: ModuleProvider.instanceKey(moduleID: "test.narou"), item: Self.bookURL))

        let requests = ModuleStub.urls.count
        #expect(try await shelf.readingCopy(Self.book, store: setup.store).id == copy.id)
        #expect(ModuleStub.urls.count == requests, "the copy there is is read again, its list not fetched again")

        let shelved = try await shelf.addToShelf(Self.book, store: setup.store)
        #expect(shelved.id == copy.id && shelved.isInBookshelf)
        #expect(setup.store.books.count == 1)

        #expect(SourceLabel.text(for: shelved, record: .derived(from: shelved, context: .live()), moduleTitle: { _ in "なろう" }) == "なろう")
        #expect(SourceLabel.text(for: shelved, record: .derived(from: shelved, context: .live())) == localized("模組"),
                "a removed module's book names no module")
    }

    @Test("a list with no chapter adds no copy; a removed module, or one that does not read, says so")
    func refusals() async throws {
        let setup = setup()
        defer { try? FileManager.default.removeItem(at: setup.folder) }
        ModuleStub.install(["ncode.syosetu.com/n9669bk": .html("<html><body><p>メンテナンス中</p></body></html>")])
        let shelf = ModuleBookShelf(reader: setup.reader)
        await #expect(throws: ModuleBookError.noChapters) { try await shelf.readingCopy(Self.book, store: setup.store) }
        #expect(setup.store.books.isEmpty)
        #expect(setup.store.copyLookup().copies(for: SourceRecord.derived(from: Self.book).key).isEmpty)

        var gone = Self.book
        gone.reference.moduleID = "test.removed"
        await #expect(throws: ModuleBookError.moduleMissing("test.removed")) { try await shelf.readingCopy(gone, store: setup.store) }

        var dataOnly = Self.narou
        dataOnly.reading = nil
        let data = self.setup(dataOnly)
        defer { try? FileManager.default.removeItem(at: data.folder) }
        await #expect(throws: ModuleBookError.notReadable("test.narou")) {
            try await ModuleBookShelf(reader: data.reader).readingCopy(Self.book, store: data.store)
        }
    }

    @Test("a chapter is read by the module and cached with its HTML, never through the browser import's path")
    func chapterFetch() async throws {
        let setup = setup()
        defer { try? FileManager.default.removeItem(at: setup.folder) }
        let chapterURL = "https://ncode.syosetu.com/n9669bk/1/"
        let copy = setup.store.addModuleBook(Self.book, chapters: [OnlineChapterRef(index: 0, title: "プロローグ", url: chapterURL)],
                                             isInBookshelf: true)
        defer { BookSourceFetcher.shared.clearAllChapterCache(bookId: copy.id) }
        ModuleStub.install(["ncode.syosetu.com/n9669bk/1": .html(try page("narou-episode.html"))])
        let manager = ChapterFetchManager(webViewFetcher: WebViewFetcher.shared, moduleReader: setup.reader)

        let book = try #require(setup.store.readingBook(id: copy.id))
        let package = try await manager.fetchChapter(book: book, chapterIndex: 0, priority: .immediate, store: setup.store)
        #expect(package.content.contains("俺は34歳住所不定無職。"))
        #expect(package.normalizedHTMLFilename != nil && package.rawHTMLFilename != nil, "the reader draws the module's HTML")
        #expect(ModuleStub.urls == [chapterURL])
        #expect(ModuleStub.userAgents.allSatisfy { $0.hasPrefix("yuedureader/") })

        let again = try await manager.fetchChapter(book: book, chapterIndex: 0, priority: .immediate, store: setup.store)
        #expect(again.contentChecksum == package.contentChecksum)
        #expect(ModuleStub.urls == [chapterURL], "a cached chapter is good enough to read: not fetched twice")
    }

    @Test("the update check reads the module's list again and marks the chapters it gained")
    func updateCheck() async throws {
        let toc = RuleModule.TableOfContents(items: "@css:li", title: "@css:a@text", url: "@css:a@href")
        var module = Self.narou
        module.hosts = ["example.com"]
        module.reading = RuleModule.Reading(headers: nil, charset: nil, toc: toc, content: RuleModule.Content(text: "@css:p@html"))
        let setup = setup(module)
        defer { try? FileManager.default.removeItem(at: setup.folder) }
        var book = Self.book
        book.reference.bookURL = "https://example.com/b"
        let copy = setup.store.addModuleBook(book, chapters: [
            OnlineChapterRef(index: 0, title: "一", url: "https://example.com/c/1"),
            OnlineChapterRef(index: 1, title: "二", url: "https://example.com/c/2"),
        ], isInBookshelf: true)
        ModuleStub.install(["example.com/b": .html(#"<ul><li><a href="/c/1">一</a></li><li><a href="/c/2">二</a></li><li><a href="/c/3">三</a></li></ul>"#)])

        let refreshed = try await setup.store.refreshOnlineBookMetadata(bookId: copy.id, moduleReader: setup.reader)
        #expect(ModuleStub.urls == ["https://example.com/b"])
        #expect(setup.store.chapters(for: copy.id)?.map(\.title) == ["一", "二", "三"])
        #expect(refreshed.hasNewChapterUpdate)
        #expect(refreshed.module == book.reference && refreshed.bookSourceId == nil, "the copy is still the module's")

        ModuleStub.install(["example.com/b": .html("<p>メンテナンス中</p>")])
        _ = try await setup.store.refreshOnlineBookMetadata(bookId: copy.id, moduleReader: setup.reader)
        #expect(setup.store.chapters(for: copy.id)?.count == 3, "an empty list never replaces the one there is")
    }

    @Test("a record from a build without `module` keeps this device's; a book without one encodes as before")
    func syncKeepsModule() async throws {
        let setup = setup()
        defer { try? FileManager.default.removeItem(at: setup.folder) }
        let copy = setup.store.addModuleBook(Self.book, chapters: [OnlineChapterRef(index: 0, title: "一", url: Self.bookURL + "1/")],
                                             isInBookshelf: true)
        var older = copy.withoutTableOfContents()
        older.module = nil
        older.currentPosition = 0.5
        older.lastOpenedDate = Date()
        let snapshot = try #require(setup.store.snapshotForSync([older], expectedMutationRevision: setup.store.mutationRevision))
        #expect(setup.store.applySyncSnapshot(try await BookStore.encodeSyncSnapshot(snapshot)))
        let applied = try #require(setup.store.readingBook(id: copy.id))
        #expect(applied.module == Self.book.reference)
        #expect(applied.currentPosition == 0.5, "the rest of the newer record lands")

        var sourced = older
        sourced.bookSourceId = UUID()
        let other = try #require(setup.store.snapshotForSync([sourced]))
        #expect(setup.store.applySyncSnapshot(try await BookStore.encodeSyncSnapshot(other)))
        #expect(setup.store.readingBook(id: copy.id)?.module == nil, "a source's book never takes a module")

        let plain = String(decoding: try JSONEncoder().encode(ReadingBook(title: "a", contentFilename: "x")), as: UTF8.self)
        #expect(!plain.contains("\"module\""), "an unchanged book's sync hash stays the same")
        let decoded = try JSONDecoder().decode(ReadingBook.self, from: JSONEncoder().encode(copy))
        #expect(decoded.module == Self.book.reference)
    }

    @Test("a reading module's list items open as its books; a lookup's records and a data module's items stay data")
    func openings() {
        let entry = RuleModule.Entry(id: "n", title: "n", request: RuleModule.Request(url: "https://ncode.syosetu.com/"),
                                     list: RuleModule.ListRules(items: "a", title: "b", url: "c"))
        let item = RuleListItem(name: "無職転生", author: "理不尽な孫の手", bookUrl: Self.bookURL, coverUrl: "", intro: "",
                                wordCount: "", lastChapter: "", kind: "", isbn: "")
        let instance = ModuleProvider.instanceKey(moduleID: "test.narou")
        let readable = ModuleProvider.entry(item, of: entry, instance: instance, hasURLRule: true, hosts: [], isReadable: true)
        guard case .item(let record, _, .moduleBook(let book)) = readable else { Issue.record("not a module's book"); return }
        #expect(book == Self.book)
        #expect(record.key == SourceRecord.derived(from: Self.book).key)
        #expect(record.acquisitions == [.readOnline])

        let data = ModuleProvider.entry(item, of: entry, instance: instance, hasURLRule: true, hosts: [])
        guard case .item(_, _, .bibliographic) = data else { Issue.record("not data"); return }
        let noURL = ModuleProvider.entry(item, of: entry, instance: instance, hasURLRule: false, hosts: [], isReadable: true)
        guard case .item(_, _, .bibliographic) = noURL else { Issue.record("an item without a page read as a book"); return }

        var withLookup = Self.narou
        withLookup.search = entry
        withLookup.lookup = entry
        withLookup.lookup?.id = nil
        let provider = ModuleProvider(module: withLookup)
        guard case .item(_, _, .moduleBook) = provider.searchEntry(item) else { Issue.record("search item not a book"); return }
        guard case .item(_, _, .bibliographic) = provider.searchEntry(item, of: withLookup.lookup) else {
            Issue.record("a lookup's record read as a book"); return
        }
    }
}
