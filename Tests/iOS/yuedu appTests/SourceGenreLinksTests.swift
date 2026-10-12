import Foundation
import Testing
@testable import yuedu_app

/// 作品詳情 · Editorial Minimalism (2026-10-12): a book-source book's genres lead to the
/// source's category of the same name, else to a search of the source; 同題材 is that
/// category's first page without the book itself.

private func item(_ title: String, url: String? = nil) -> DiscoverCardItem {
    DiscoverViewModel.mapItem(ModernParserBridge.DiscoverItem(title: title, url: url ?? "/\(title)"))!
}

private func book(_ name: String, url: String? = nil) -> OnlineBook {
    OnlineBook(name: name, author: "作者", intro: "", coverUrl: "", bookUrl: url ?? "https://site.test/\(name)",
               tocUrl: "", wordCount: "", lastChapter: "", kind: "", sourceId: UUID(), sourceName: "來源")
}

private func display(_ online: OnlineBook) -> DiscoverBookDisplay {
    DiscoverBookDisplay(book: online, intro: "", isAudiobook: false)
}

@Suite("Genre matching")
struct SourceGenreMatchingTests {
    @Test("a genre names the category of the same title, case, width and spacing aside")
    func sameTitle() {
        let items = [item("都市"), item("玄幻 小說"), item("ABC")]
        #expect(SourceGenreMatching.category(for: "玄幻小說", among: items)?.title == "玄幻 小說")
        #expect(SourceGenreMatching.category(for: "ＡＢＣ", among: items)?.title == "ABC")
        #expect(SourceGenreMatching.category(for: "  都市 ", among: items)?.title == "都市")
    }

    @Test("a genre the source does not list as a category gets no guessed one")
    func noPartialMatch() {
        let items = [item("都市生活"), item("玄幻")]
        #expect(SourceGenreMatching.category(for: "都市", among: items) == nil)
        #expect(SourceGenreMatching.category(for: "東方玄幻", among: items) == nil)
        #expect(SourceGenreMatching.category(for: "", among: items) == nil)
    }

    @Test("a category that only opens a web page is not a destination")
    func actionIsNotACategory() {
        let action = item("玄幻", url: "java.startBrowser('https://site.test/x','玄幻')")
        #expect(!action.isFetchable)
        #expect(SourceGenreMatching.category(for: "玄幻", among: [action]) == nil)
    }

    @Test("同題材 reads the first genre, in the book's order, that names a category")
    func firstCategoryFollowsGenreOrder() {
        let items = [item("系統"), item("都市")]
        let match = SourceGenreMatching.firstCategory(for: ["神豪", "都市", "系統"], among: items)
        #expect(match?.tag == "都市")
        #expect(match?.item.title == "都市")
        #expect(SourceGenreMatching.firstCategory(for: ["神豪"], among: items) == nil)
    }

    @Test("同題材 leaves out the book on the page, by its address or its title, and stops at the limit")
    func relatedExcludesTheBook() {
        let shown = book("斗羅大陸", url: "https://site.test/1")
        let displays = [
            display(book("斗羅大陸", url: "https://site.test/1")),
            display(book("斗羅 大陸", url: "https://mirror.test/1")),
            display(book("鬥破蒼穹")),
            display(book("完美世界")),
            display(book("遮天")),
        ]
        let related = SourceGenreMatching.related(displays, excluding: shown, limit: 2)
        #expect(related.map(\.book.name) == ["鬥破蒼穹", "完美世界"])
    }
}

/// Answers the category list and the first page from a script, and records the pages asked for.
private actor PageScript {
    private(set) var pages: [(url: String?, page: Int)] = []
    private let answer: Result<[OnlineBook], Error>

    init(_ answer: Result<[OnlineBook], Error>) {
        self.answer = answer
    }

    func fetch(_ item: ModernParserBridge.DiscoverItem, page: Int) throws -> [OnlineBook] {
        pages.append((item.url, page))
        return try answer.get()
    }
}

private struct PageFailed: Error {}

private actor CategoryReads {
    private(set) var count = 0

    func read(_ items: [ModernParserBridge.DiscoverItem]) -> [ModernParserBridge.DiscoverItem] {
        count += 1
        return items
    }
}

@MainActor
@Suite("Genre links", .serialized, .timeLimit(.minutes(1)))
struct SourceGenreLinksTests {
    private let source = BookSource(bookSourceUrl: "https://source.test", bookSourceName: "來源")

    private func links(
        categories: [ModernParserBridge.DiscoverItem], script: PageScript
    ) -> SourceGenreLinks {
        SourceGenreLinks(
            loadCategories: { _ in categories },
            primeCookies: { _ in },
            pageLoader: SectionPageLoader { item, page, _ in try await script.fetch(item, page: page) }
        )
    }

    @Test("同題材 is the first page of the matched category, without the book on the page")
    func relatedLoadsFirstPage() async {
        let shown = book("斗羅大陸")
        let script = PageScript(.success([shown, book("鬥破蒼穹"), book("完美世界")]))
        let model = links(categories: [.init(title: "都市", url: "/city"), .init(title: "玄幻", url: "/xh")],
                          script: script)
        await model.load(key: "k", source: source, tags: ["熱血", "玄幻"], book: shown)

        guard case .loaded(let reference, let section) = model.related else {
            Issue.record("expected 同題材 to load, got \(model.related)")
            return
        }
        #expect(reference.title == "玄幻")
        #expect(reference.url == "/xh")
        #expect(section.books.map(\.book.name) == ["鬥破蒼穹", "完美世界"])
        let pages = await script.pages
        #expect(pages.map(\.page) == [1])
        #expect(pages.map(\.url) == ["/xh"])
    }

    @Test("no genre naming a category means no 同題材 and no request for books")
    func noMatchNoSection() async {
        let script = PageScript(.success([book("鬥破蒼穹")]))
        let model = links(categories: [.init(title: "都市", url: "/city")], script: script)
        await model.load(key: "k", source: source, tags: ["玄幻"], book: book("斗羅大陸"))
        #expect(model.related == .hidden)
        #expect(await script.pages.isEmpty)
    }

    @Test("a category with no book but this one shows no 同題材")
    func onlyThisBookHides() async {
        let shown = book("斗羅大陸")
        let model = links(categories: [.init(title: "玄幻", url: "/xh")], script: PageScript(.success([shown])))
        await model.load(key: "k", source: source, tags: ["玄幻"], book: shown)
        #expect(model.related == .hidden)
    }

    @Test("a failed page says so under the category, and 重試 loads it again")
    func failureCanRetry() async {
        let model = links(categories: [.init(title: "玄幻", url: "/xh")], script: PageScript(.failure(PageFailed())))
        await model.load(key: "k", source: source, tags: ["玄幻"], book: book("斗羅大陸"))
        guard case .failed(let reference, _) = model.related else {
            Issue.record("expected a failure, got \(model.related)")
            return
        }
        #expect(reference.title == "玄幻")
        await model.retryRelated(key: "k", source: source, tags: ["玄幻"], book: book("斗羅大陸"))
        if case .failed = model.related {} else { Issue.record("expected the retry to run, got \(model.related)") }
    }

    @Test("a genre the source lists opens its category; any other searches the source")
    func destinations() async {
        let model = links(categories: [.init(title: "玄幻", url: "/xh")], script: PageScript(.success([])))
        await model.load(key: "k", source: source, tags: ["玄幻", "熱血"], book: book("斗羅大陸"))
        #expect(await model.destination(for: "玄幻", in: source)
                == .category(ExploreCategoryReference(sourceURL: "https://source.test", title: "玄幻", url: "/xh")))
        #expect(await model.destination(for: "熱血", in: source) == .search("熱血"))
    }

    @Test("the page returning from its reader keeps 同題材: neither the categories nor the page are read again")
    func sameKeyLoadsOnce() async {
        let shown = book("斗羅大陸")
        let script = PageScript(.success([shown, book("鬥破蒼穹")]))
        let reads = CategoryReads()
        let model = SourceGenreLinks(
            loadCategories: { _ in await reads.read([.init(title: "玄幻", url: "/xh")]) },
            primeCookies: { _ in },
            pageLoader: SectionPageLoader { item, page, _ in try await script.fetch(item, page: page) }
        )
        await model.load(key: "k", source: source, tags: ["玄幻"], book: shown)
        await model.load(key: "k", source: source, tags: ["玄幻"], book: shown)
        #expect(await model.destination(for: "玄幻", in: source) != .search("玄幻"))
        #expect(await reads.count == 1)
        #expect(await script.pages.count == 1)
        if case .loaded = model.related {} else { Issue.record("expected 同題材 kept, got \(model.related)") }
    }

    @Test("a genre tapped before the page has read the categories reads them itself")
    func tapBeforeLoad() async {
        let model = links(categories: [.init(title: "玄幻", url: "/xh")], script: PageScript(.success([])))
        #expect(await model.destination(for: "玄幻", in: source)
                == .category(ExploreCategoryReference(sourceURL: "https://source.test", title: "玄幻", url: "/xh")))
    }

    @Test("without a source every genre searches")
    func noSourceSearches() async {
        let model = links(categories: [.init(title: "玄幻", url: "/xh")], script: PageScript(.success([])))
        await model.load(key: "k", source: nil, tags: ["玄幻"], book: book("斗羅大陸"))
        #expect(model.related == .hidden)
        #expect(await model.destination(for: "玄幻", in: nil) == .search("玄幻"))
    }
}
