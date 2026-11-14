import Foundation
import Testing
@testable import yuedu_app

/// 作品詳情 · Editorial Minimalism (2026-10-12): 作者其他作品 lists only works the version's
/// own data ties to its author — 青空文庫's credits, the author's Gutenberg feed, the work
/// index's author keys — never the same work again or a series-mate by someone else.
@Suite("Author works")
struct AuthorWorksTests {
    private static let dav = SourceInstanceKey(type: .webDAV, id: "dav")

    private static func copy(_ title: String, _ author: String, series: String? = nil) -> WorkIndexEntry {
        let id = UUID()
        let record = SourceRecord(key: .copy(id), title: title, authors: [author], language: nil, contentKind: .text,
                                  identifiers: [], copyID: id, acquisitions: [])
        return WorkIndexEntry(record: record, series: series)
    }

    private static func file(_ path: String, _ title: String, _ author: String) -> WorkIndexEntry {
        let record = SourceRecord(key: SourceItemKey(instance: dav, item: path), title: title, authors: [author], language: nil,
                                  contentKind: .text, identifiers: [], copyID: nil, acquisitions: [.download(format: "epub")])
        return WorkIndexEntry(record: record, series: nil)
    }

    @Test("other works by the author, one card a work, a shelf copy before a file, by title")
    func shelfByAuthor() {
        let shown = Self.copy("三體", "劉慈欣", series: "地球往事")
        let sameWorkFile = Self.file("三體.epub", "三體", "劉慈欣")
        let seriesByOther = Self.copy("三體X", "寶樹", series: "地球往事")
        let ballFile = Self.file("球狀閃電.epub", "球狀閃電", "劉慈欣")
        let ballCopy = Self.copy("球狀閃電", "劉慈欣")
        let supernova = Self.copy("超新星紀元", "劉慈欣")
        let unrelated = Self.copy("紅樓夢", "曹雪芹")
        let entries = [shown, sameWorkFile, seriesByOther, ballFile, ballCopy, supernova, unrelated]
        let index = WorkIndex.build(entries: entries)

        let picked = RelatedWorks.byAuthors(in: index, authorKeys: [WorkMatchKey.author("劉慈欣")],
                                            excluding: [shown.nodeKey], shown: Set(entries.map(\.nodeKey)), limit: 20)
        #expect(picked.count == 2)
        #expect(Set(picked) == [ballCopy.nodeKey, supernova.nodeKey])
        #expect(!picked.contains(sameWorkFile.nodeKey))
        #expect(!picked.contains(seriesByOther.nodeKey))
        #expect(RelatedWorks.byAuthors(in: index, authorKeys: [WorkMatchKey.author("劉慈欣")], excluding: [shown.nodeKey],
                                       shown: Set(entries.map(\.nodeKey)), limit: 1).count == 1)
    }

    private static func copy(_ title: String, _ author: String, kind: ContentKind) -> WorkIndexEntry {
        let id = UUID()
        let record = SourceRecord(key: .copy(id), title: title, authors: [author], language: nil, contentKind: kind,
                                  identifiers: [], copyID: id, acquisitions: [])
        return WorkIndexEntry(record: record, series: nil)
    }

    @Test("an author's shelf by kind: a book and its audiobook are both there, one card a work in each")
    func shelfByKind() {
        let book = Self.copy("三體", "劉慈欣")
        let audiobook = Self.copy("三體", "劉慈欣", kind: .audio)
        let bookFile = Self.file("三體.epub", "三體", "劉慈欣")
        let ball = Self.file("球狀閃電.epub", "球狀閃電", "劉慈欣")
        let comic = Self.copy("流浪地球（漫畫）", "劉慈欣", kind: .comic)
        let film = Self.copy("流浪地球", "劉慈欣", kind: .video)
        let other = Self.copy("紅樓夢", "曹雪芹", kind: .audio)
        let entries = [book, audiobook, bookFile, ball, comic, film, other]
        let index = WorkIndex.build(entries: entries)
        let shown = Set(entries.map(\.nodeKey))

        let picked = RelatedWorks.byAuthorKinds(in: index, authorKeys: [WorkMatchKey.author("劉慈欣")], shown: shown, limit: 20)
        #expect(Set(picked.books) == [book.nodeKey, ball.nodeKey, comic.nodeKey],
                "the shelf copy stands for 三體 before its file; a comic is a book; a video is neither")
        #expect(picked.audiobooks == [audiobook.nodeKey], "joined into the book's work by the index, still its own card")

        let onlyBooks = RelatedWorks.byAuthorKinds(in: index, authorKeys: [WorkMatchKey.author("劉慈欣")],
                                                   shown: shown.subtracting([audiobook.nodeKey]), limit: 20)
        #expect(onlyBooks.audiobooks.isEmpty && onlyBooks.books.count == 3)
        #expect(RelatedWorks.byAuthorKinds(in: index, authorKeys: [], shown: shown, limit: 20).books.isEmpty)
        #expect(RelatedWorks.byAuthorKinds(in: index, authorKeys: [WorkMatchKey.author("劉慈欣")], shown: shown, limit: 1).books.count == 1)
    }

    @Test("no author, no works; a node not shown is left out")
    func shelfWithoutAuthor() {
        let shown = Self.copy("三體", "劉慈欣")
        let offShelf = Self.copy("流浪地球", "劉慈欣")
        let index = WorkIndex.build(entries: [shown, offShelf])
        #expect(RelatedWorks.byAuthors(in: index, authorKeys: [], excluding: [shown.nodeKey],
                                       shown: [shown.nodeKey, offShelf.nodeKey], limit: 20).isEmpty)
        #expect(RelatedWorks.byAuthors(in: index, authorKeys: [WorkMatchKey.author("劉慈欣")], excluding: [shown.nodeKey],
                                       shown: [shown.nodeKey], limit: 20).isEmpty)
    }

    @Test("「未知作者」 is no author: the TXTs that name none are not one author's works")
    func placeholderAuthor() {
        let shown = Self.copy("斗罗大陆", "未知作者")
        let other = Self.copy("AI 推薦測試", "未知作者")
        let english = Self.copy("Notes", "Unknown Author")
        #expect(shown.authorKeys.isEmpty)
        #expect(english.authorKeys.isEmpty)
        let index = WorkIndex.build(entries: [shown, other, english])
        #expect(RelatedWorks.byAuthors(in: index, authorKeys: [WorkMatchKey.author("未知作者")], excluding: [shown.nodeKey],
                                       shown: [shown.nodeKey, other.nodeKey, english.nodeKey], limit: 20).isEmpty)
    }

    private static func aozoraWork(_ id: String, _ title: String, credits: [AozoraWork.Credit]) -> AozoraWork {
        AozoraWork(id: id, title: title, yomi: "", sortYomi: title, subtitle: "", kanaStyle: "", ndc: "",
                   published: "", updated: "", card: "", text: "", textUpdated: "", credits: credits,
                   source: "", sourcePublisher: "")
    }

    @Test("青空文庫: the other works of the work's 著者, not of its translator, without the work itself")
    func aozoraAuthor() {
        let soseki = AozoraPerson(id: "1", name: "夏目 漱石", yomi: "", sortYomi: "", born: "", died: "")
        let translator = AozoraPerson(id: "2", name: "訳者", yomi: "", sortYomi: "", born: "", died: "")
        let cat = Self.aozoraWork("10", "吾輩は猫である", credits: [.init(person: "2", role: "翻訳者"), .init(person: "1", role: "著者")])
        let kokoro = Self.aozoraWork("11", "こころ", credits: [.init(person: "1", role: "著者")])
        let other = Self.aozoraWork("12", "訳書", credits: [.init(person: "2", role: "翻訳者")])
        let index = AozoraCatalogIndex(catalog: AozoraCatalog(schemaVersion: 1, persons: [soseki, translator],
                                                              works: [cat, kokoro, other]))
        #expect(AuthorWorks.aozoraPerson(of: cat, in: index)?.id == "1")
        let titles = AuthorWorks.aozora(cat, index: index, limit: 12).compactMap { entry -> String? in
            guard case .item(_, let summary, _) = entry else { return nil }
            return summary.title
        }
        #expect(titles == ["こころ"])
        #expect(AuthorWorksRequest.aozora(cat, index).authorPage == .aozora(soseki, index))
    }

    @Test("Gutenberg: the author's feed without the book on the page")
    func gutenbergExcludesTheBook() {
        let shown = GutenbergBook(id: 1342, title: "Pride and Prejudice", author: "Austen, Jane")
        let other = GutenbergBook(id: 158, title: "Emma", author: "Austen, Jane")
        let entries = [shown, other].map(CollectionEntry.bundledGutenberg)
        let kept = AuthorWorks.excluding(shown, from: entries, limit: 12)
        #expect(kept == [CollectionEntry.bundledGutenberg(other)])
    }
}

@MainActor
@Suite("Author works loading", .serialized, .timeLimit(.minutes(1)))
struct AuthorWorksModelTests {
    private struct FeedFailed: Error {}
    private let author = GutenbergAuthor(name: "Austen, Jane", url: URL(string: "https://www.gutenberg.org/ebooks/author/68")!)
    private let shown = GutenbergBook(id: 1342, title: "Pride and Prejudice", author: "Austen, Jane")

    @Test("a failed feed says so, and 重試 reads it again")
    func failureRetries() async {
        var calls = 0
        var fails = true
        let other = CollectionEntry.bundledGutenberg(GutenbergBook(id: 158, title: "Emma", author: "Austen, Jane"))
        let model = AuthorWorksModel(loadGutenberg: { _ in
            calls += 1
            if fails { throw FeedFailed() }
            return [other]
        }, loadShelf: { _, _ in [] })
        let request = AuthorWorksRequest.gutenberg(author, excluding: shown)
        let store = BookStore()
        await model.load(request, store: store)
        if case .failed = model.state {} else { Issue.record("expected a failure, got \(model.state)") }
        fails = false
        await model.retry(request, store: store)
        #expect(model.state == .loaded([other]))
        #expect(calls == 2)
    }

    @Test("the same request is not read again; a feed with only this book shows nothing")
    func sameRequestOnce() async {
        var calls = 0
        let shown = shown
        let model = AuthorWorksModel(loadGutenberg: { _ in
            calls += 1
            return [CollectionEntry.bundledGutenberg(shown)]
        }, loadShelf: { _, _ in [] })
        let request = AuthorWorksRequest.gutenberg(author, excluding: shown)
        let store = BookStore()
        await model.load(request, store: store)
        await model.load(request, store: store)
        #expect(model.state == .hidden)
        #expect(calls == 1)
        await model.load(nil, store: store)
        #expect(model.state == .hidden)
    }

    // MARK: The author's page (2026-11-14)

    private static func found(_ title: String, _ author: String, kind: ContentKind) -> CollectionEntry {
        let record = SourceRecord(key: SourceItemKey(instance: ModuleProvider.instanceKey(moduleID: "m"), item: "\(kind.rawValue)/\(title)"),
                                  title: title, authors: [author], language: nil, contentKind: kind, identifiers: [],
                                  copyID: nil, acquisitions: [.viewOnly])
        return .item(record, WorkSummary(title: title, authors: [author], cover: .generated(seed: title), blurb: "",
                                         language: nil, contentKind: kind), .bibliographic)
    }

    @Test("the author's page lists this device's works, then the source's, each by its kind and each title once a kind")
    func authorPage() async {
        let shelfBook = Self.found("三體", "劉慈欣", kind: .text)
        let shelfAudio = Self.found("三體", "劉慈欣", kind: .audio)
        let sourceBook = Self.found("球狀閃電", "劉慈欣", kind: .text)
        var asked: [AuthorPageRequest] = []
        let model = AuthorPageModel(readDevice: { _, _ in AuthorShelf(books: [shelfBook], audiobooks: [shelfAudio]) },
                                    readSource: { request in
            asked.append(request)
            return [Self.found("三体", "刘慈欣", kind: .text), sourceBook, Self.found("流浪地球", "劉慈欣", kind: .video)]
        }, enabledSources: { [] })
        let store = BookStore()
        let request = AuthorPageRequest(name: "劉慈欣", context: .device)
        #expect(model.state == .loading)
        await model.load(request, store: store)
        #expect(model.state == .loaded(AuthorShelf(books: [shelfBook, sourceBook], audiobooks: [shelfAudio])),
                "the source's 三体 is the shelf's 三體; a video is neither kind; the audiobook of the same title stays")
        await model.load(request, store: store)
        #expect(asked == [request], "the same page is not read again")
    }

    @Test("a source that fails leaves the page with this device's works; an author with nothing has an empty page")
    func authorPageSourceFails() async {
        let shelfBook = Self.found("三體", "劉慈欣", kind: .text)
        let failing = AuthorPageModel(readDevice: { _, _ in AuthorShelf(books: [shelfBook], audiobooks: []) },
                                      readSource: { _ in throw FeedFailed() }, enabledSources: { [] })
        await failing.load(AuthorPageRequest(name: "劉慈欣", context: .source(UUID())), store: BookStore())
        #expect(failing.state == .loaded(AuthorShelf(books: [shelfBook], audiobooks: [])))

        let nothing = AuthorPageModel(readDevice: { _, _ in AuthorShelf(books: [], audiobooks: []) }, readSource: { _ in [] },
                                      enabledSources: { [] })
        await nothing.load(AuthorPageRequest(name: "無名氏", context: .device), store: BookStore())
        guard case .loaded(let shelf) = nothing.state else {
            Issue.record("expected a loaded page, got \(nothing.state)")
            return
        }
        #expect(shelf.isEmpty && !shelf.hasBothKinds)
        #expect(AuthorShelf(books: [shelfBook], audiobooks: [Self.found("三體", "劉慈欣", kind: .audio)]).hasBothKinds)
    }

    @Test("the background search adds the author's books as sources answer: once a title a kind, others' books never")
    func authorPageSearch() {
        let text = UUID(), audio = UUID()
        var textSource = BookSource()
        textSource.id = text
        textSource.bookSourceUrl = "https://text.example"
        var audioSource = BookSource()
        audioSource.id = audio
        audioSource.bookSourceUrl = "https://audio.example"
        audioSource.bookSourceType = 1
        let sources = [text: textSource, audio: audioSource]
        var seen = Set<String>()
        let first = AuthorPageModel.byAuthor([
            Self.online("三體", "劉慈欣", "https://text.example/1", source: text),
            Self.online("劉慈欣傳", "別人", "https://text.example/2", source: text),
            Self.online("三体", "刘慈欣 著", "https://text.example/3", source: text),
            Self.online("沒有這個來源", "劉慈欣", "https://gone.example/1", source: UUID()),
        ], author: "劉慈欣", sources: sources, seen: &seen)
        #expect(first.count == 1)
        // A later answer repeats what was found and adds an audiobook of the same title.
        let second = AuthorPageModel.byAuthor([
            Self.online("三體", "劉慈欣", "https://text.example/1", source: text),
            Self.online("三體", "劉慈欣", "https://audio.example/1", source: audio),
        ], author: "劉慈欣", sources: sources, seen: &seen)
        guard case .item(let record, _, _)? = second.first else {
            Issue.record("expected the audiobook, got \(second)")
            return
        }
        #expect(second.count == 1 && record.contentKind == .audio, "the same title as an audiobook is another card")
    }

    // MARK: 封面預先下載 (2026-11-14)

    @Test("a row's covers fetched ahead: each remote address once, in order, a cap; nothing for a cover with no address")
    @MainActor
    func coverPrefetch() {
        func card(_ title: String, _ cover: CoverReference?) -> HomeCardContent {
            HomeCardContent(sample: title, author: "林遠山", kind: .text, cover: cover)
        }
        let a = URL(string: "https://covers.example/a.jpg")!, b = URL(string: "https://covers.example/b.jpg")!
        let cards = [
            card("甲", .remote(a, headers: ["Referer": "https://example.com"])),
            card("乙", .generated(seed: "乙")),
            card("丙", .remote(a, headers: [:])),
            card("丁", .copyFile("/tmp/cover.jpg")),
            card("戊", nil),
            card("己", .remote(b, headers: [:])),
        ]
        let covers = BookDetailCoverPrefetch.covers(of: cards)
        #expect(covers.map(\.url) == [a.absoluteString, b.absoluteString])
        #expect(covers.first?.headers == ["Referer": "https://example.com"], "the first card's headers go with its address")
        #expect(BookDetailCoverPrefetch.covers(of: cards, limit: 1).map(\.url) == [a.absoluteString])
        #expect(BookDetailCoverPrefetch.covers(of: []).isEmpty)
    }

    @Test("a 來源配置's 同題材 row: each book's cover address once, with the section's base address and headers")
    func coverPrefetchSourceRow() {
        let id = UUID()
        func display(_ name: String, cover: String) -> DiscoverBookDisplay {
            var book = Self.online(name, "忘語", "https://example.com/b/\(name)", source: id)
            book.coverUrl = cover
            return DiscoverBookDisplay(book: book, intro: "", contentKind: .text)
        }
        let item = DiscoverCardItem(title: "仙俠", stableKey: "仙俠", raw: .init(title: "仙俠", url: "https://example.com/c/1"),
                                    isAction: false, actionURL: nil, isFetchable: true)
        var section = DiscoverShowcaseSection(item: item, coverBaseURL: "https://example.com", coverHeaders: ["X-Token": "t"])
        section.books = [display("甲", cover: "/covers/a.jpg"), display("乙", cover: ""), display("丙", cover: "/covers/a.jpg"),
                         display("丁", cover: "https://cdn.example/d.jpg")]
        let covers = BookDetailCoverPrefetch.covers(of: section)
        #expect(covers.map(\.url) == ["/covers/a.jpg", "https://cdn.example/d.jpg"], "as the source gave them, as the card asks")
        #expect(covers.allSatisfy { $0.sourceBaseURL == "https://example.com" && $0.headers == ["X-Token": "t"] && $0.session == nil })
        #expect(BookDetailCoverPrefetch.covers(of: section, limit: 1).count == 1)
    }

    // MARK: 本機書的分類 (2026-11-14)

    private static func tagged(_ title: String, _ author: String, tags: [String], file: String? = nil) -> WorkIndexEntry {
        if let file {
            let record = SourceRecord(key: SourceItemKey(instance: SourceInstanceKey(type: .webDAV, id: "dav"), item: file),
                                      title: title, authors: [author], language: nil, contentKind: .text, identifiers: [],
                                      copyID: nil, acquisitions: [.download(format: "epub")])
            return WorkIndexEntry(record: record, tags: tags)
        }
        let id = UUID()
        let record = SourceRecord(key: .copy(id), title: title, authors: [author], language: nil, contentKind: .text,
                                  identifiers: [], copyID: id, acquisitions: [])
        return WorkIndexEntry(record: record, tags: tags)
    }

    @Test("a record's genres are kept as written, each once, five at most; works share a genre by its folded name")
    func shelfGenres() {
        let entry = Self.tagged("三體", "劉慈欣", tags: [" 科幻 ", "科幻", "硬科幻", "", "太空", "長篇", "得獎", "第六個"])
        #expect(entry.tags == ["科幻", "硬科幻", "太空", "長篇", "得獎"])
        #expect(entry.tagKeys.count == 5)

        let shown = Self.tagged("三體", "劉慈欣", tags: ["科幻"])
        let sameWorkFile = Self.tagged("三體", "劉慈欣", tags: ["科幻"], file: "三體.epub")
        let ballFile = Self.tagged("球狀閃電", "劉慈欣", tags: ["科幻小说"], file: "球狀閃電.epub")
        let dune = Self.tagged("沙丘", "赫伯特", tags: ["科幻", "經典"])
        let duneFile = Self.tagged("沙丘", "赫伯特", tags: ["科幻"], file: "沙丘.epub")
        let dream = Self.tagged("紅樓夢", "曹雪芹", tags: ["古典"])
        let entries = [shown, sameWorkFile, ballFile, dune, duneFile, dream]
        let index = WorkIndex.build(entries: entries)
        let picked = RelatedWorks.byGenre(in: index, genreKey: WorkMatchKey.title("科幻"), excluding: [shown.nodeKey],
                                          shown: Set(entries.map(\.nodeKey)), limit: 20)
        #expect(picked == [dune.nodeKey], "not the page's own work, not another genre; the shelf copy stands for 沙丘")
        #expect(RelatedWorks.byGenre(in: index, genreKey: "", excluding: [], shown: Set(entries.map(\.nodeKey)), limit: 20).isEmpty)
    }

    @Test("同題材 is the first of the copy's genres that has another work; none, no section")
    func shelfGenresModel() async {
        let version = WorkDetailRoute(Self.found("三體", "劉慈欣"))!
        var asked: [String] = []
        let model = ShelfGenresModel(readGenres: { _, _ in ["硬科幻", "科幻"] }, readWorks: { genre, _, _ in
            asked.append(genre)
            return genre == "科幻" ? [Self.found("沙丘", "赫伯特")] : []
        })
        let store = BookStore()
        await model.load([version], store: store)
        #expect(model.genres == ["硬科幻", "科幻"])
        #expect(model.related == ShelfGenresModel.Related(genre: "科幻", works: [Self.found("沙丘", "赫伯特")]))
        await model.load([version], store: store)
        #expect(asked == ["硬科幻", "科幻"], "the same versions are not read again")
        await model.load(nil, store: store)
        #expect(model.genres.isEmpty && model.related == nil)
    }

    // MARK: 來源配置 and modules (2026-11-14)

    private static func online(_ name: String, _ author: String, _ url: String, source: UUID) -> OnlineBook {
        OnlineBook(name: name, author: author, intro: "", coverUrl: "", bookUrl: url, tocUrl: "", wordCount: "",
                   lastChapter: "", kind: "", sourceId: source, sourceName: "測試來源")
    }

    @Test("an author is the author by name, in either script: never a name that only holds it")
    func strictAuthor() {
        // The maintainer's page of 飞天鱼, 2026-11-14: it listed these three's works too.
        for other in ["飛天魚兒", "驕傲的飛天魚", "Yuky飛天魚", "飞天鱼儿"] {
            #expect(!WorkMatchKey.authorsSame(["飞天鱼"], [other]), "\(other)")
            #expect(WorkMatchKey.authorsCompatible(["飞天鱼"], [other]), "a work's versions still take a longer name: \(other)")
        }
        for same in ["飛天魚", "飞天鱼", "作者：飛天魚", "飛天魚 著", "飛天魚、別人", " 飞天鱼 "] {
            #expect(WorkMatchKey.authorsSame(["飞天鱼"], [same]), "\(same)")
        }
        #expect(WorkMatchKey.authorsSame(["Terry Pratchett", "Neil Gaiman"], ["neil gaiman"]))
        #expect(!WorkMatchKey.authorsSame(["飞天鱼"], [""]) && !WorkMatchKey.authorsSame([], ["飞天鱼"]))

        let id = UUID()
        let books = [
            Self.online("萬古神帝", "飛天魚", "https://example.com/b/1", source: id),
            Self.online("飛天魚兒的新書", "飛天魚兒", "https://example.com/b/2", source: id),
            Self.online("雜文", "Yuky飛天魚", "https://example.com/b/3", source: id),
            Self.online("万古神帝", "飞天鱼", "https://example.com/b/4", source: id),
        ]
        #expect(AuthorWorks.sameAuthor(books, author: "飞天鱼", excludingTitle: "", bookURL: "", limit: 12).map(\.name) == ["萬古神帝"],
                "the author's own, once: the two scripts' titles are one work")
        var source = BookSource()
        source.id = id
        var seen = Set<String>()
        #expect(AuthorPageModel.byAuthor(books, author: "飞天鱼", sources: [id: source], seen: &seen).count == 1)

        // A source that writes the author into the title: the same work, once, written plainly.
        #expect(WorkMatchKey.title("飛天魚萬古神帝", by: ["飞天鱼"]) == WorkMatchKey.title("万古神帝"))
        #expect(WorkMatchKey.title("飛天魚", by: ["飛天魚"]) == WorkMatchKey.title("飛天魚"), "a title that is the name alone")
        #expect(WorkMatchKey.title("天帝傳", by: ["飛天魚"]) == WorkMatchKey.title("天帝傳"))
        let named = [
            Self.online("飛天魚萬古神帝", "飛天魚", "https://example.com/b/9", source: id),
            Self.online("萬古神帝", "飛天魚", "https://example.com/b/1", source: id),
            Self.online("飛天魚天帝傳", "飛天魚", "https://example.com/b/8", source: id),
        ]
        #expect(AuthorWorks.sameAuthor(named, author: "飛天魚", excludingTitle: "", bookURL: "", limit: 12).count == 2)
        func entries(_ books: [OnlineBook]) -> [CollectionEntry] { books.map { CollectionEntry.onlineBook($0, source: source) } }
        func titles(_ shelf: AuthorShelf) -> [String] {
            shelf.books.compactMap { if case .item(let record, _, _) = $0 { record.title } else { nil } }
        }
        let shelf = AuthorShelf(books: [], audiobooks: []).adding(entries(named))
        #expect(titles(shelf) == ["萬古神帝", "飛天魚天帝傳"], "the plain title takes the first one's place; one with no plain twin stays")
        #expect(titles(shelf.adding(entries([Self.online("天帝傳", "飛天魚", "https://example.com/b/7", source: id)])))
                == ["萬古神帝", "天帝傳"])
    }

    @Test("a source's search for an author keeps that author's other books, each title once")
    func sameAuthor() {
        let id = UUID()
        let books = [
            Self.online("凡人修仙傳", "忘語", "https://example.com/b/1", source: id),
            Self.online("玄界之門", "忘语 著", "https://example.com/b/2", source: id),
            Self.online("忘語傳", "別人", "https://example.com/b/3", source: id),
            Self.online("玄界之门", "忘語", "https://example.com/b/4", source: id),
            Self.online("凡人修仙传（精校）", "忘語", "https://example.com/b/1", source: id),
            Self.online("魔天記", "忘語", "https://example.com/b/5", source: id),
        ]
        let kept = AuthorWorks.sameAuthor(books, author: "忘語", excludingTitle: "凡人修仙傳", bookURL: "https://example.com/b/1", limit: 12)
        #expect(kept.map(\.name) == ["玄界之門", "魔天記"],
                "the page's own book (by title, and by address under another title), a title match by someone else and a repeat are out")
        #expect(AuthorWorks.sameAuthor(books, author: "忘語", excludingTitle: "凡人修仙傳", bookURL: "", limit: 1).count == 1)
    }

    @Test("a 來源配置's page lists its author's other books; a search that fails or a source that is gone shows no row")
    func sourceRequest() async {
        let id = UUID()
        var source = BookSource()
        source.bookSourceUrl = "https://example.com"
        source.bookSourceName = "測試來源"
        var asked: [String] = []
        var outcome: Result<[OnlineBook]?, FeedFailed> = .success([
            Self.online("凡人修仙傳", "忘語", "https://example.com/b/1", source: id),
            Self.online("魔天記", "忘語", "https://example.com/b/5", source: id),
        ])
        let model = AuthorWorksModel(loadGutenberg: { _ in [] }, loadShelf: { _, _ in [] }, searchSource: { _, keyword in
            asked.append(keyword)
            return try outcome.get().map { (source, $0) }
        }, loadModules: { _ in [] })
        let store = BookStore()
        let request = AuthorWorksRequest.source(sourceID: id, author: "忘語", title: "凡人修仙傳", bookURL: "https://example.com/b/1")
        await model.load(request, store: store)
        guard case .loaded(let entries) = model.state, case .item(let record, _, .onlineBook(let frozen))? = entries.first else {
            Issue.record("expected the author's other book, got \(model.state)")
            return
        }
        #expect(entries.count == 1 && record.title == "魔天記" && frozen.book.bookUrl == "https://example.com/b/5")
        #expect(asked == ["忘語"])

        outcome = .failure(FeedFailed())
        await model.load(.source(sourceID: id, author: "別人", title: "書", bookURL: ""), store: store)
        #expect(model.state == .hidden, "a failed search is no row, not a retry block the page never had")
        outcome = .success(nil)
        await model.load(.source(sourceID: id, author: "第三人", title: "書", bookURL: ""), store: store)
        #expect(model.state == .hidden)
    }

    private static func found(_ title: String, _ author: String) -> CollectionEntry {
        let record = SourceRecord(key: SourceItemKey(instance: ModuleProvider.instanceKey(moduleID: "m"), item: title),
                                  title: title, authors: [author], language: nil, contentKind: .text, identifiers: [],
                                  copyID: nil, acquisitions: [.viewOnly])
        return .item(record, WorkSummary(title: title, authors: [author], cover: .generated(seed: title), blurb: "",
                                         language: nil, contentKind: .text), .bibliographic)
    }

    @Test("a record with no library of its own asks the modules; the page's own work and a repeat are left out")
    func modulesRequest() async {
        var asked: [[String]] = []
        let model = AuthorWorksModel(loadGutenberg: { _ in [] }, loadShelf: { _, _ in [] }, searchSource: { _, _ in nil },
                                     loadModules: { authors in
            asked.append(authors)
            return [Self.found("論語別裁", "南懷瑾"), Self.found("孟子旁通", "南懷瑾"), Self.found("孟子旁通", "南懷瑾")]
        })
        await model.load(.modules(authors: ["南懷瑾"], title: "论语别裁"), store: BookStore())
        guard case .loaded(let entries) = model.state else {
            Issue.record("expected works, got \(model.state)")
            return
        }
        #expect(entries == [Self.found("孟子旁通", "南懷瑾")])
        #expect(asked == [["南懷瑾"]])
    }

    @Test("the modules that search by author are asked in 資料來源's order, for the first author; others' books are dropped")
    func moduleAuthorWorks() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AuthorWorks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = RuleModuleLibrary(store: RuleModuleStore(directory: folder), appVersion: "3.0.1", officialFiles: { [] })
        func module(_ id: String, searchesAuthors: Bool) -> Data {
            var search: [String: Any] = ["request": ["url": "https://example.com/s?q={{keyword}}"],
                                         "list": ["items": "$.books[*]", "title": "$.title", "author": "$.author"]]
            if searchesAuthors { search["searchesAuthors"] = true }
            return try! JSONSerialization.data(withJSONObject: [
                "id": id, "title": id, "version": "1.0", "requiredVersion": "3.0.1", "hosts": ["example.com"],
                "modules": [[String: Any]](), "search": search,
            ] as [String: Any])
        }
        try await library.install(module("titles", searchesAuthors: false), from: nil)
        try await library.install(module("authors", searchesAuthors: true), from: nil)
        let suite = "AuthorWorks-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let order = MetadataFillOrderStore(defaults: defaults)
        #expect(ModuleAuthorWorks.modules(in: library, order: order).map(\.id) == ["authors"])

        var asked: [String] = []
        let works = await ModuleAuthorWorks.load(authors: ["未知作者", "南懷瑾", "譯者"], limit: 12, library: library, order: order) { module, author in
            asked.append("\(module.id):\(author)")
            return [Self.found("南懷瑾傳", "別人"), Self.found("孟子旁通", "南怀瑾")]
        }
        #expect(works == [Self.found("孟子旁通", "南怀瑾")])
        #expect(asked == ["authors:南懷瑾"])

        var entries = order.order(modules: library.fillingModules.map(\.id)).entries
        for index in entries.indices where entries[index].place == .module("authors") { entries[index].isEnabled = false }
        order.save(MetadataFillOrder(entries: entries))
        #expect(ModuleAuthorWorks.modules(in: library, order: order).isEmpty, "unchecked in 資料來源: its site is not asked")
    }
}
