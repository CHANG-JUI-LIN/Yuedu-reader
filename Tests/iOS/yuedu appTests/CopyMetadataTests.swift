import Foundation
import Testing
@testable import yuedu_app

/// Unified library 5f-4d: a detail page shows a shelf copy's own title and author first
/// (decision 32), through `MetadataResolver`.
struct CopyMetadataTests {
    private let context = SourceRecordContext(bookSourceURL: { _ in nil }, connectionKind: { _ in nil }, webDAVRoot: { _ in nil })

    private func resolve(_ book: ReadingBook, decisions: [WorkDecision] = []) -> CopyMetadata {
        CopyMetadata.resolve(copy: book, record: SourceRecord.derived(from: book, context: context), decisions: decisions)
    }

    @Test func theCopysOwnTitleAndAuthor() {
        let book = ReadingBook(title: "書架上的名字", author: "甲、乙", source: "local", contentFilename: "a.epub")
        let shown = resolve(book)
        #expect(shown.title == "書架上的名字")
        #expect(shown.author == "甲、乙")
    }

    @Test func anOverrideComesFirst() {
        let book = ReadingBook(title: "書架上的名字", author: "甲", source: "local", contentFilename: "a.epub")
        let override = WorkDecision.override(anchor: .copy(book.id), field: .title, value: .text("讀者改的"), decidedAt: Date())
        #expect(resolve(book, decisions: [override]).title == "讀者改的")
    }

    /// A copy with no title decides nothing: the page shows its source's.
    @Test func anEmptyValueIsNotShown() {
        let book = ReadingBook(title: "  ", author: "", source: "local", contentFilename: "a.epub")
        let shown = resolve(book)
        #expect(shown.title == nil)
        #expect(shown.author == nil)
    }

    // MARK: The description (5f-4d-2, decision 33)

    private func onlineBook() -> ReadingBook {
        var book = ReadingBook(title: "線上書", author: "作者", source: "https://source.example/book/1", contentFilename: "")
        book.isOnline = true
        book.bookSourceId = UUID()
        book.bookInfoURL = "https://source.example/book/1"
        return book
    }

    private let sourceContext = SourceRecordContext(bookSourceURL: { _ in "https://source.example" }, connectionKind: { _ in nil },
                                                    webDAVRoot: { _ in nil })

    private func intro(_ book: ReadingBook, sidecar: [MetadataValue] = [], live: String? = nil) -> CopyMetadata.Intro? {
        CopyMetadata.resolve(copy: book, record: SourceRecord.derived(from: book, context: sourceContext), decisions: [],
                             sidecar: sidecar, liveIntro: live).intro
    }

    @Test func theReadersOwnDescriptionComesFirst() throws {
        var book = onlineBook()
        book.customIntro = "  讀者寫的  "
        let shown = try #require(intro(book, live: "<usehtml><button onclick='x'>書源的</button></usehtml>"))
        #expect(shown.text == "讀者寫的")
        #expect(shown.isEdited)
        #expect(!shown.isSourcesOwn, "The reader's text never runs a source's actions")
    }

    @Test func theSourcesLiveDescriptionIsItsOwn() throws {
        let book = onlineBook()
        let record = SourceRecord.derived(from: book, context: sourceContext)
        let stored = MetadataValue(field: .intro, value: .text("舊的"), provider: record.key.instance, sourceItem: record.key,
                                   fetchedAt: Date(timeIntervalSinceReferenceDate: 0))
        let shown = try #require(intro(book, sidecar: [stored], live: "書源剛給的"))
        #expect(shown.text == "書源剛給的", "The page's live value is the place's newest")
        #expect(shown.isSourcesOwn)
        #expect(!shown.isEdited)
        #expect(intro(book, sidecar: [stored])?.isSourcesOwn == false, "A stored value is not the page's source")
    }

    @Test func theCopysOwnFileComesBeforeItsSource() throws {
        let book = onlineBook()
        let own = MetadataValue(field: .intro, value: .text("檔案裡的"), provider: .localLibrary, sourceItem: nil,
                                fetchedAt: Date(timeIntervalSinceReferenceDate: 0))
        let shown = try #require(intro(book, sidecar: [own], live: "書源的"))
        #expect(shown.text == "檔案裡的")
        #expect(!shown.isSourcesOwn)
    }

    @Test func noDescriptionIsNil() {
        #expect(intro(onlineBook(), live: "  ") == nil)
    }

    // MARK: A filled description in 中繼資料語言偏好推薦's script (2026-10-28)

    private let bangumi = SourceInstanceKey(type: .module, id: "bangumi")
    /// Bangumi's summary of 紅樓夢 (subject 123224) as the filler stored it, in 简体.
    private let bangumiSummary = "《红楼梦》，中国古典四大名著之首，清代作家曹雪芹创作的章回体长篇小说。早期仅有前八十回抄本流传，原名《石头记》。"

    private func filled(_ text: String) -> MetadataValue {
        MetadataValue(field: .intro, value: .text(text), provider: bangumi,
                      sourceItem: SourceItemKey(instance: bangumi, item: "https://bgm.tv/subject/123224"),
                      fetchedAt: Date(timeIntervalSinceReferenceDate: 0))
    }

    /// An EPUB with no `<dc:description>`, as imported: its own file gave the description nothing.
    private func localEPUB(title: String = "紅樓夢") -> ReadingBook {
        ReadingBook(title: title, author: "曹雪芹", source: "local", contentFilename: "hongloumeng.epub")
    }

    private func intro(_ book: ReadingBook, sidecar: [MetadataValue], live: String? = nil, language: String?) -> CopyMetadata.Intro? {
        CopyMetadata.resolve(copy: book, record: SourceRecord.derived(from: book, context: sourceContext), decisions: [],
                             sidecar: sidecar, liveIntro: live, display: language.map(MetadataDisplay.init(language:))).intro
    }

    /// The whole description, 書名號 and all, as the work's page shows a source's.
    @Test func aFilledDescriptionIsInTheReadersScript() throws {
        let traditional = try #require(intro(localEPUB(), sidecar: [filled(bangumiSummary)], language: "zh-Hant"))
        #expect(traditional.text == "《紅樓夢》，中國古典四大名著之首，清代作家曹雪芹創作的章回體長篇小說。早期僅有前八十回抄本流傳，原名《石頭記》。")
        #expect(!traditional.isEdited)
        #expect(!traditional.isSourcesOwn)
        #expect(!traditional.isUnavailable)

        let simplified = try #require(intro(localEPUB(), sidecar: [filled("《紅樓夢》，中國古典四大名著之首，清代作家曹雪芹創作的章回體長篇小說。")],
                                            language: "zh-Hans"))
        #expect(simplified.text == "《红楼梦》，中国古典四大名著之首，清代作家曹雪芹创作的章回体长篇小说。")
    }

    @Test func aFilledDescriptionInAnotherLanguageIsAsSent() {
        #expect(intro(localEPUB(), sidecar: [filled(bangumiSummary)], language: "en")?.text == bangumiSummary)
        #expect(intro(localEPUB(), sidecar: [filled(bangumiSummary)], language: nil)?.text == bangumiSummary)
    }

    @Test func theReadersOwnDescriptionIsNotConverted() throws {
        var book = localEPUB()
        book.customIntro = "读者自己写的简介"
        let shown = try #require(intro(book, sidecar: [filled(bangumiSummary)], language: "zh-Hant"))
        #expect(shown.text == "读者自己写的简介")
        #expect(shown.isEdited)
    }

    @Test func theCopysOwnFileIsNotConverted() throws {
        let own = MetadataValue(field: .intro, value: .text("档案里的简介"), provider: .localLibrary, sourceItem: nil,
                                fetchedAt: Date(timeIntervalSinceReferenceDate: 0))
        #expect(intro(localEPUB(), sidecar: [own, filled(bangumiSummary)], language: "zh-Hant")?.text == "档案里的简介")
    }

    /// The source a copy came from is the copy's own, live or stored; its markup is read as sent.
    @Test func theCopysSourceIsNotConverted() throws {
        let book = onlineBook()
        let record = SourceRecord.derived(from: book, context: sourceContext)
        let stored = MetadataValue(field: .intro, value: .text("书源存的简介"), provider: record.key.instance, sourceItem: record.key,
                                   fetchedAt: Date(timeIntervalSinceReferenceDate: 0))
        #expect(intro(book, sidecar: [stored, filled(bangumiSummary)], language: "zh-Hant")?.text == "书源存的简介")
        let live = try #require(intro(book, sidecar: [filled(bangumiSummary)], live: "<md>书源刚给的</md>", language: "zh-Hant"))
        #expect(live.text == "<md>书源刚给的</md>")
        #expect(live.isSourcesOwn)
    }

    /// A Japanese description filled for a Japanese title says there is none in Chinese, as a
    /// source's card and page do.
    @Test func aFilledJapaneseDescriptionIsUnavailableInChinese() throws {
        let shown = try #require(intro(localEPUB(title: "こころ"), sidecar: [filled("「先生」と私の物語です。鎌倉の海で出会った二人の交流を描く。")],
                                       language: "zh-Hant"))
        #expect(shown.isUnavailable)
        #expect(shown.text == localized("沒有繁體中文簡介"))
    }

    @Test func aBookNeverEditedEncodesWithoutTheField() throws {
        var book = ReadingBook(title: "書", author: "", contentFilename: "a.txt")
        #expect(!String(decoding: try JSONEncoder().encode(book), as: UTF8.self).contains("customIntro"))
        book.customIntro = "讀者寫的"
        #expect(try JSONDecoder().decode(ReadingBook.self, from: JSONEncoder().encode(book)).customIntro == "讀者寫的")
    }

    // MARK: Gutenberg records stored before d7aa65ab

    private func gutenbergIntro(_ text: String) -> MetadataValue {
        let instance = SourceInstanceKey(type: .gutenberg, id: PublicLibraryID.gutenberg.rawValue)
        return MetadataValue(field: .intro, value: .text(text), provider: instance,
                             sourceItem: SourceItemKey(instance: instance, item: "1342"), fetchedAt: Date(timeIntervalSinceReferenceDate: 0))
    }

    @Test func aStoredGutenbergRecordIsCutToItsSummary() {
        let flattened = "This edition had all images removed. Title: Pride and Prejudice Credits: Chuck Greif "
            + "Summary: \"Pride and Prejudice\" by Jane Austen is a novel. (This is an automatically generated summary.) "
            + "Reading Level: Reading ease score: 69.2. Author: Austen, Jane EBook No.: 1342 Downloads: 189689 Rights: Public domain in the USA."
        let other = MetadataValue(field: .language, value: .texts(["en"]), provider: .localLibrary, sourceItem: nil, fetchedAt: .distantPast)
        let repaired = BookStore.repairingGutenbergRecords([gutenbergIntro(flattened), other])
        #expect(repaired.count == 2)
        #expect(repaired.first?.value == .text("\"Pride and Prejudice\" by Jane Austen is a novel. (This is an automatically generated summary.)"))
        #expect(repaired.last == other)
    }

    @Test func aStoredGutenbergRecordWithoutASummaryIsDropped() {
        let record = "This edition has images. LoC No.: 20007446 Author: Tappan, Eva March EBook No.: 79765 Downloads: 0"
        #expect(BookStore.repairingGutenbergRecords([gutenbergIntro(record)]).isEmpty)
    }

    @Test func aGutenbergSummaryIsLeftAlone() {
        let summary = gutenbergIntro("A novel published in 1813.")
        #expect(BookStore.repairingGutenbergRecords([summary]) == [summary])
    }
}
