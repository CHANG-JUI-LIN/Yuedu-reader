import Foundation
import Testing
@testable import yuedu_app

/// `ChapterFetchManager.isSuspiciousChapterContent` decides whether a chapter is several chapters
/// merged into one. Feedback #89 (3.0.0 build 140): a ~3,000-character chapter that cites
/// 「第三章」 in its prose tripped it on every source, so the reader discarded the chapter on each
/// open and it never loaded.
@MainActor
@Suite("Online chapter merge heuristic", .serialized)
struct OnlineChapterMergeHeuristicTests {

    // MARK: - Fixtures

    private static let paragraphs = [
        "　　雨是從傍晚開始下的。林遠把窗戶推開一條縫，潮濕的風卷著樓下燒烤攤的油煙味鑽進來，桌上那疊列印出來的稿紙被吹得嘩啦作響。他伸手按住，指尖碰到紙邊那一圈圈咖啡漬，才想起這份稿子已經在抽屜裡躺了整整三年。三年前他辭掉報社的工作，信誓旦旦地說要寫一部真正屬於自己的長篇，結果寫到一半就停了，停得理直氣壯，好像只要不去看它，它就永遠不會失敗。",
        "　　他起身把窗戶關上，屋子裡一下子安靜下來，只剩下冰箱壓縮機偶爾發出的嗡嗡聲。他打開電腦，螢幕的光照在臉上，有些刺眼。文件夾裡還存著當年的電子檔，檔名後面跟著一長串日期，最新的一個停在三年前的十一月。他點開它，游標在開頭閃爍，像是在催促，又像是在等待。",
        "　　那時候他住在城東一間租來的小屋裡，房東是個愛養花的老太太，每天清晨都會在樓道裡給那幾盆茉莉澆水。他常常在她澆水的聲音裡醒來，然後坐到書桌前寫上兩三個小時，再去報社上班。那段日子很窮，卻是他這輩子寫得最順的時候，順到他以為寫作本來就該是這個樣子。",
        "　　後來老太太過世了，房子被她兒子賣掉，他搬了三次家，稿子也跟著搬了三次。每次打包的時候，他都會猶豫要不要把它扔掉，最後又總是小心地把它塞進最結實的那個紙箱，壓在一堆舊書底下，好像只要壓得夠深，它就不會再來找他。",
        "　　他把稿子翻到第三章，那裡的批註比正文還多。紅筆、藍筆、鉛筆，三種顏色的字跡擠在行距之間，有些是他自己的，有些是當年那位編輯留下的。最刺眼的一句寫在頁腳：「人物動機不成立，讀者不會相信她會回來。」他盯著那行字看了很久，久到窗外的雨聲都變成了一種均勻的白噪音。",
        "　　手機在桌角震了一下。是老周發來的訊息，問他下週的讀書會還去不去。林遠沒有回，把手機翻過去扣在桌上。讀書會是老周拉起來的，每個月一次，七八個人擠在一家快倒閉的咖啡館裡，輪流講自己最近在讀什麼。他已經連續缺席了四次，理由一次比一次敷衍，到後來連他自己都懶得編了。",
        "　　他記得自己頭一回把稿子拿給別人看，是在一個朋友的婚禮上。酒過三巡，他不知道哪來的勇氣，把列印好的前幾萬字塞給了坐在旁邊的一個陌生人，那人後來成了他的編輯，也就是沈姐。她當晚就讀完了，隔天一早打電話給他，開口就問：「你為什麼要寫這個？」",
        "　　他當時答不上來，支支吾吾地說了些想要記錄時代、想要寫普通人之類的話。沈姐在電話那頭沉默了一會兒，說這些都是好理由，但都不是你的理由。「等你想清楚了再來找我，」她說，「稿子我先留著。」他後來才知道，她替他留著稿子的那幾年，推掉了好幾個更好賣的選題。",
        "　　第三章的稿子他前後改了七遍，每一遍都覺得差一口氣，像是一扇門明明就在眼前，鑰匙卻總也插不進去。他記得最後一次修改是在一個冬天的凌晨，暖氣壞了，他裹著棉被坐在電腦前，敲完最後一個句號的時候天剛好亮，他以為自己終於寫對了，隔天醒來重讀，又覺得每個字都在撒謊。",
        "　　當年的編輯姓沈，是個說話很慢的中年女人。她在電話裡說，第十二章的節奏太慢，讀者會在那裡流失，但她也說，整部稿子裡最好的段落恰恰藏在那一章。「你得想辦法讓人撐到那裡，」她說，「好東西放在後面不是錯，錯的是你沒給人留下走到那裡的理由。」這句話他後來在很多場合轉述過，每次都假裝是自己想出來的。",
        "　　雨越下越大，樓下的燒烤攤收了，只剩下路燈在水窪裡碎成一片一片的光。林遠起身去廚房燒水，回來的時候順手把檯燈調亮了一格。他重新坐下，從抽屜裡翻出一支快沒水的紅筆，在稿紙開頭的空白處寫下今天的日期，又在日期後面畫了一個問號，像是在問自己，也像是在問這疊紙。",
        "　　他想起大學時的文學課。教授講到《紅樓夢》第五回，說那是整部書的總綱，所有人物的命運都在一場夢裡被提前寫好了，後面的篇幅不過是在慢慢兌現。那時候他覺得這種寫法太取巧，現在卻忽然明白，提前把結局說出來，需要的不是技巧，而是一種近乎殘忍的篤定——作者得先相信那個結局，讀者才會跟著相信。",
        "　　水開了，壺嘴發出尖銳的鳴叫。他泡了一杯很濃的茶，捧在手裡暖著，一邊看一邊在稿紙上劃線。有些句子他已經完全不記得寫過，讀起來像是陌生人的作品，帶著一種他現在寫不出來的莽撞；有些句子他記得清清楚楚，連當時為了一個形容詞猶豫了多久都記得，可如今再看，那個形容詞依然是錯的。",
        "　　茶已經涼了，他卻沒有起身去續。稿紙上的紅線越劃越多，到後來幾乎每一行都有記號。他忽然意識到，自己並不是在修改，而是在重新認識這個故事——認識那個寫下它的人，認識那個人當年想要什麼、害怕什麼，又在哪些地方偷偷地繞開了真正該面對的東西。",
        "　　直到第二卷完結，他都沒想好女主角到底該不該回來。這是整部小說最大的結，也是沈編輯那句批註真正指向的地方。他曾經給她寫過三個版本的結局：一個是她回來了，一個是她沒有回來，還有一個是她回來了，卻發現等她的人早就走了。三個版本他都寫完了，三個版本他都不滿意。",
        "　　他想起沈編輯最後一次見面時的樣子。那天她穿一件洗得發白的灰色毛衣，坐在出版社樓下的小餐館裡，點了一碗餛飩卻一口也沒吃。她說公司要改制了，她可能做不了多久，這部稿子如果他還想出，最好換個人跟。他當時只顧著失落，沒聽出她話裡的疲憊，後來聽說她提前退休，回了南方的老家，就再也沒有聯絡過。",
        "　　有時候他會想，如果當年他咬著牙把稿子改完，現在會是什麼樣子。也許書出了，賣得不好，他回到報社，像大多數人那樣把這件事當作年輕時的一次衝動；也許書出了，賣得還行，他就這樣一本一本地寫下去。可無論哪一種，都比現在好——現在的他什麼都不是，只是一個抽屜裡藏著半部小說的中年人。",
        "　　凌晨一點，老周又發來一條訊息，這次只有一句話：「別一個人悶著。」林遠看著那幾個字，忽然有點想笑。老周從來不知道他在寫什麼，也從來沒問過，可是每次他快要撐不下去的時候，這個人總會莫名其妙地冒出來，說一句不痛不癢的話，然後又消失好幾個星期。",
        "　　樓上傳來拖動椅子的聲音，接著是一陣斷斷續續的鋼琴聲。是住在樓上的小女孩在練琴，彈的總是同一首曲子，彈到同一個地方就會卡住，停一停，再從頭開始。林遠聽了好幾個月，從來沒聽她彈完過，可是今晚，那首曲子竟然順順當當地彈到了結尾，連他自己都愣了一下。",
        "　　他把這當成一個預兆，雖然他知道這很可笑。一個三十多歲的男人，在凌晨的出租屋裡，因為樓上小孩彈完了一首練習曲，就覺得自己的人生也許還能再往前走一步。可是人有時候就是需要這樣一點可笑的東西，來替自己找一個不得不開始的理由。",
        "　　他終於回了訊息，說下週會去。按下發送鍵的那一刻，他覺得心裡有什麼東西鬆動了一下，很輕，像是冰面上裂開的一道紋路。他把手機放回桌上，這次沒有扣過去。窗外的雨小了些，遠處傳來夜車經過高架橋的聲音。林遠把稿子按頁碼重新理好，用夾子夾住，放在桌子正中央。他沒有開始寫，只是看著它，像看著一個久別重逢、彼此都有些尷尬的老朋友。",
    ]

    /// One chapter, its own title on the first line, citing 第三章 ×2, 第十二章, 第五回 and 第二卷 in
    /// its prose — one of the citations opens a paragraph. The #89 shape.
    static let singleChapterCitingOthers =
        "第一百二十章 舊稿\n" + paragraphs.joined(separator: "\n")

    /// Three chapters fetched as one: each opens with its heading on a line of its own.
    static let threeChapterMerge = [
        "第一百二十章 舊稿\n" + paragraphs[0..<7].joined(separator: "\n"),
        "第一百二十一章 夜雨\n" + paragraphs[7..<14].joined(separator: "\n"),
        "第一百二十二章 回信\n" + paragraphs[14..<21].joined(separator: "\n"),
    ].joined(separator: "\n")

    private static func anyPositionHeadingMentions(in content: String) -> Int {
        let regex = try! NSRegularExpression(pattern: #"第\s*[\d零一二三四五六七八九十百千萬万]+\s*[章回卷節节篇部]"#)
        return regex.numberOfMatches(in: content, range: NSRange(content.startIndex..., in: content))
    }

    // MARK: - Heuristic

    @Test("a chapter that cites other chapters in its prose is one chapter")
    func proseCitationsAreNotHeadings() {
        let content = Self.singleChapterCitingOthers
        #expect((2_500...3_600).contains(content.count), "a realistic chapter length, like #89's 2969/3060/3333")
        #expect(Self.anyPositionHeadingMentions(in: content) == 6, "its title plus five citations — over the old threshold of 3")

        #expect(!ChapterFetchManager.isSuspiciousChapterContent(content))
    }

    @Test("three chapters fetched as one, each opening with its own heading line, are a merge")
    func lineStartHeadingsWithBodiesAreAMerge() {
        #expect(ChapterFetchManager.isSuspiciousChapterContent(Self.threeChapterMerge))
    }

    @Test("a merge delivered as HTML paragraphs is a merge")
    func htmlParagraphMergeIsAMerge() {
        let html = Self.threeChapterMerge
            .components(separatedBy: "\n")
            .map { "<p>\($0)</p>" }
            .joined()
        #expect(!html.contains("\n"))

        #expect(ChapterFetchManager.isSuspiciousChapterContent(html))
    }

    @Test("a multi-page chapter that restates its title on every page is one chapter")
    func repeatedTitleIsOneChapter() {
        let content = [
            "第一百二十章 舊稿（1/3）\n" + Self.paragraphs[0..<7].joined(separator: "\n"),
            "第一百二十章 舊稿（2/3）\n" + Self.paragraphs[7..<14].joined(separator: "\n"),
            "第一百二十章 舊稿（3/3）\n" + Self.paragraphs[14..<21].joined(separator: "\n"),
        ].joined(separator: "\n")

        #expect(!ChapterFetchManager.isSuspiciousChapterContent(content))
    }

    @Test("a chapter followed by the site's list of latest chapters is one chapter")
    func trailingChapterLinkListIsOneChapter() {
        let numerals = ["二十一", "二十二", "二十三", "二十四", "二十五", "二十六", "二十七", "二十八", "二十九", "三十", "三十一"]
        let links = numerals.map { "第一百\($0)章 待續" }
        let content = Self.singleChapterCitingOthers + "\n最新章節：\n" + links.joined(separator: "\n")
        #expect(Self.anyPositionHeadingMentions(in: content) == 17)

        #expect(!ChapterFetchManager.isSuspiciousChapterContent(content))
    }

    // MARK: - Cache route

    private static func cachedPackage(_ content: String) -> ChapterPackage {
        ChapterPackage(
            bookId: UUID(), chapterIndex: 0, sourceURL: "https://example.com/120", tocTitle: "第一百二十章 舊稿",
            canonicalTitle: nil, content: content, contentChecksum: "",
            rawHTMLFilename: nil, normalizedHTMLFilename: nil, savedAt: Date(), state: .cached, failureReason: nil
        )
    }

    @Test("a cached chapter that cites other chapters stays reusable")
    func citingChapterCacheIsReusable() {
        let package = Self.cachedPackage(Self.singleChapterCitingOthers)

        #expect(OnlineChapterCacheWritePolicy.isReusableCachedPackage(package, hasBookSource: true))
        #expect(OnlineChapterCacheWritePolicy.isReusableCachedPackage(package, hasBookSource: false))
    }

    /// A refetch from the same source returns the same bytes, so refusing a cached chapter for
    /// how it looks only ever made it unreadable. It is read as fetched.
    @Test("a cached chapter that does look merged, or is over-long, stays reusable")
    func mergedChapterCacheIsReusable() {
        let overLong = String(repeating: Self.singleChapterCitingOthers, count: 60)
        #expect(ChapterFetchManager.isSuspiciousChapterContent(Self.threeChapterMerge))
        #expect(ChapterFetchManager.isSuspiciousChapterContent(overLong))

        #expect(OnlineChapterCacheWritePolicy.isReusableCachedPackage(Self.cachedPackage(Self.threeChapterMerge), hasBookSource: true))
        #expect(OnlineChapterCacheWritePolicy.isReusableCachedPackage(Self.cachedPackage(overLong), hasBookSource: true))
    }

    @Test("the reader's cache-only read serves a cached chapter and keeps it", arguments: [false, true])
    func cacheOnlyServesChapter(looksMerged: Bool) async throws {
        let content = looksMerged ? Self.threeChapterMerge : Self.singleChapterCitingOthers
        let chapterURL = "https://example.com/book/120"
        var book = ReadingBook(title: "線上書", source: "https://example.com/book", contentFilename: "")
        book.isOnline = true
        book.bookSourceId = UUID()
        book.onlineChapters = [OnlineChapterRef(index: 0, title: "第一百二十章 舊稿", url: chapterURL)]
        defer { BookSourceFetcher.shared.clearAllChapterCache(bookId: book.id) }
        try BookSourceFetcher.shared.saveToCache(
            content: content, bookId: book.id, chapterIndex: 0,
            sourceURL: chapterURL, tocTitle: "第一百二十章 舊稿", storeNormalizedHTML: false
        )

        let payload = try await OnlineChapterContentService(book: book, store: nil).payload(at: 0, policy: .cacheOnly)

        #expect(payload.plainText == content)
        #expect(BookSourceFetcher.shared.loadChapterPackageSync(bookId: book.id, chapterIndex: 0) != nil,
                "the read must not delete the chapter it just served")
    }

    // MARK: - Fetch route

    private static let bookURL = "https://ncode.syosetu.com/n0000aa/"
    private static let chapterURL = "https://ncode.syosetu.com/n0000aa/120/"

    private static func episodePage(_ content: String) -> String {
        let body = content.components(separatedBy: "\n").map { "<p>\($0)</p>" }.joined()
        return "<html><body><div class=\"js-novel-text\">\(body)</div></body></html>"
    }

    /// Fetches the chapter through the fetch manager, the way the reader and the downloader do,
    /// then asks for it again. Returns the two packages.
    private func fetchTwice(serving content: String) async throws -> (ChapterPackage, ChapterPackage, ReadingBook) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MergeHeuristic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModuleStub.self]
        let client = RuleModuleClient(fetcher: WebFetcher(session: URLSession(configuration: configuration)),
                                      store: RuleModuleStore(directory: folder.appendingPathComponent("modules")))
        var module = RuleModule(id: "test.merge", title: "Merge", description: nil, author: nil, site: nil, version: "1.0",
                                requiredVersion: "3.0", hosts: ["ncode.syosetu.com"], rateLimit: nil, modules: [], search: nil)
        module.reading = ModuleReadingTests.narouReading
        let readable = module
        let reader = ModuleBookReader(client: client, module: { id in id == readable.id ? readable : nil })
        let store = BookStore(metadataFileURL: folder.appendingPathComponent("books_meta.json"))
        let moduleBook = ModuleBook(reference: ModuleBookReference(moduleID: "test.merge", bookURL: Self.bookURL),
                                    title: "舊稿", author: "林遠", coverURL: nil, contentKind: .text)
        let copy = store.addModuleBook(moduleBook, chapters: [OnlineChapterRef(index: 0, title: "第一百二十章 舊稿", url: Self.chapterURL)],
                                       isInBookshelf: true)
        let book = try #require(store.readingBook(id: copy.id))
        ModuleStub.install(["ncode.syosetu.com/n0000aa/120": .html(Self.episodePage(content))])
        let manager = ChapterFetchManager(webViewFetcher: WebViewFetcher.shared, moduleReader: reader)

        let first = try await manager.fetchChapter(book: book, chapterIndex: 0, priority: .immediate, store: store)
        let again = try await manager.fetchChapter(book: book, chapterIndex: 0, priority: .immediate, store: store)
        #expect(await manager.isChapterCached(book: book, chapterIndex: 0), "the reader's readiness probe agrees")
        return (first, again, book)
    }

    @Test("a fetched chapter that cites other chapters is cached and read back, not refetched")
    func fetchedCitingChapterIsReadBack() async throws {
        let (first, again, book) = try await fetchTwice(serving: Self.singleChapterCitingOthers)
        defer { BookSourceFetcher.shared.clearAllChapterCache(bookId: book.id) }

        #expect(first.content.contains("他把稿子翻到第三章"))
        #expect(!ChapterFetchManager.isSuspiciousChapterContent(first.content))
        #expect(again.contentChecksum == first.contentChecksum)
        #expect(ModuleStub.urls == [Self.chapterURL], "the second request is the cache, not the network")
    }

    @Test("a fetched chapter that does look merged is shown as fetched, cached and read back")
    func fetchedMergedChapterIsReadBack() async throws {
        let (first, again, book) = try await fetchTwice(serving: Self.threeChapterMerge)
        defer { BookSourceFetcher.shared.clearAllChapterCache(bookId: book.id) }

        #expect(ChapterFetchManager.isSuspiciousChapterContent(first.content),
                "the pipeline's own representation still reads as a merge")
        #expect(again.contentChecksum == first.contentChecksum)
        #expect(ModuleStub.urls == [Self.chapterURL], "the second request is the cache, not the network")
        let payload = try await OnlineChapterContentService(book: book, store: nil).payload(at: 0, policy: .cacheOnly)
        #expect(payload.plainText == first.content)
    }
}
