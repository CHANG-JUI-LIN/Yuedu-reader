import Foundation
import Testing
@testable import yuedu_app

@Suite("搜索頁：最近搜索、最近閱讀與書籍列")
struct SearchRecentsTests {
    // MARK: 最近搜索

    @Test("a new search goes to the front")
    func recordingPutsNewestFirst() {
        let recents = RecentSearchQueries().recording("紅樓夢").recording("三體")
        #expect(recents.queries == ["三體", "紅樓夢"])
    }

    @Test("searching again lifts the search instead of listing it twice")
    func recordingAgainLiftsExisting() {
        let byCase = RecentSearchQueries(queries: ["三體", "Dune", "紅樓夢"]).recording("dune")
        #expect(byCase.queries == ["dune", "三體", "紅樓夢"])

        let byWidth = RecentSearchQueries(queries: ["ABC", "三體"]).recording("ＡＢＣ")
        #expect(byWidth.queries == ["ＡＢＣ", "三體"])
    }

    @Test("blank searches are not kept, and the words are trimmed")
    func recordingTrimsAndSkipsBlank() {
        let recents = RecentSearchQueries(queries: ["三體"])
        #expect(recents.recording("   ") == recents)
        #expect(recents.recording("  紅樓夢 \n").queries == ["紅樓夢", "三體"])
    }

    @Test("only the newest searches are kept")
    func keepsTheLimit() {
        var recents = RecentSearchQueries()
        for index in 1...8 {
            recents = recents.recording("書\(index)")
        }
        #expect(recents.queries.count == RecentSearchQueries.limit)
        #expect(recents.queries.first == "書8")
        #expect(!recents.queries.contains("書3"))
    }

    @Test("the stored form reads back as the same list")
    func rawValueRoundTrips() {
        let recents = RecentSearchQueries(queries: ["紅樓,夢", "\"引號\"", "三體"])
        #expect(RecentSearchQueries(rawValue: recents.rawValue) == recents)
    }

    @Test("a stored list that is not a list starts over")
    func unreadableRawValue() {
        #expect(RecentSearchQueries(rawValue: "not json") == nil)
    }

    // MARK: 最近閱讀

    @Test("lists shelf books opened most recently first, three at most")
    func recentReadingOrder() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let books = [
            makeBook("甲", opened: now.addingTimeInterval(-300)),
            makeBook("乙", opened: nil),
            makeBook("丙", opened: now.addingTimeInterval(-100)),
            makeBook("丁", opened: now.addingTimeInterval(-200)),
            makeBook("戊", opened: now.addingTimeInterval(-400)),
        ]

        let titles = titles(of: RecentReadingSelection.entries(shelf: books, records: [], clearedAt: nil))

        #expect(titles == ["丙", "丁", "甲"])
    }

    @Test("clearing hides what was opened before it; a book opened afterwards comes back")
    func recentReadingClearing() {
        let clearedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let books = [
            makeBook("甲", opened: clearedAt.addingTimeInterval(-10)),
            makeBook("乙", opened: clearedAt.addingTimeInterval(10)),
        ]

        let offShelf = [
            offShelfRecord("丙", read: clearedAt.addingTimeInterval(-5)),
            offShelfRecord("丁", read: clearedAt.addingTimeInterval(5)),
        ]

        let titles = titles(of: RecentReadingSelection.entries(
            shelf: books,
            records: offShelf,
            clearedAt: clearedAt
        ))

        #expect(titles == ["乙", "丁"])
    }

    @Test("books read that are not on the shelf join the shelf's, by when they were read")
    func offShelfRecordsInterleaveWithShelf() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let books = [
            makeBook("甲", opened: now.addingTimeInterval(-300)),
            makeBook("乙", opened: now.addingTimeInterval(-100)),
        ]
        let offShelf = [
            offShelfRecord("丙", read: now.addingTimeInterval(-50)),
            offShelfRecord("丁", read: now.addingTimeInterval(-200)),
        ]

        let entries = RecentReadingSelection.entries(shelf: books, records: offShelf, clearedAt: nil)

        #expect(titles(of: entries) == ["丙", "乙", "丁"])
        guard case .record = entries[0], case .shelf = entries[1] else {
            Issue.record("an off-shelf read is listed as a record, a shelf book as the book")
            return
        }
    }

    @Test("a book read off the shelf and then shelved is listed once, as the shelf book")
    func shelvedRecordIsListedOnce() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let books = [makeBook("斗羅大陸", opened: now.addingTimeInterval(-100))]
        // Same book: the record's title differs only in width and spacing.
        let offShelf = [offShelfRecord("斗羅 大陸", read: now)]

        let entries = RecentReadingSelection.entries(shelf: books, records: offShelf, clearedAt: nil)

        #expect(entries.count == 1)
        guard case .shelf = entries.first else {
            Issue.record("the shelf book stands for the book")
            return
        }
    }

    // MARK: 不在書架上的閱讀紀錄

    @Test("reading a book again lifts its record; the newest ten are kept")
    func offShelfRecordsOrderAndLimit() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var records = OffShelfReadRecords()
        for index in 1...12 {
            records = records.recording(offShelfRecord("書\(index)", read: now.addingTimeInterval(Double(index))))
        }
        records = records.recording(offShelfRecord("書5", read: now.addingTimeInterval(100)))

        #expect(records.records.count == OffShelfReadRecords.limit)
        #expect(records.records.first?.title == "書5")
        #expect(records.records.filter { $0.title == "書5" }.count == 1)
        #expect(!records.records.contains { $0.title == "書1" })
    }

    @Test("records are kept in user defaults and read back the same")
    func offShelfRecordsStore() throws {
        let defaults = try #require(UserDefaults(suiteName: "SearchRecentsTests.offShelfReads"))
        defaults.removePersistentDomain(forName: "SearchRecentsTests.offShelfReads")
        let read = Date(timeIntervalSinceReferenceDate: 800_000_000)

        OffShelfReadRecords.record(title: "  三體  ", author: "劉慈欣", coverUrl: "https://example.com/c.jpg", at: read, defaults: defaults)
        OffShelfReadRecords.record(title: "", author: "無名", coverUrl: "", at: read, defaults: defaults)

        let stored = try #require(
            defaults.string(forKey: OffShelfReadRecords.storageKey).flatMap(OffShelfReadRecords.init(rawValue:))
        )
        #expect(stored.records == [
            OffShelfReadRecords.Record(title: "三體", author: "劉慈欣", coverUrl: "https://example.com/c.jpg", lastRead: read)
        ])
        defaults.removePersistentDomain(forName: "SearchRecentsTests.offShelfReads")
    }

    @Test("a stored zero means the list was never cleared")
    func clearedAtStoredValue() {
        #expect(RecentReadingSelection.clearedAt(storedValue: 0) == nil)
        #expect(
            RecentReadingSelection.clearedAt(storedValue: 5)
                == Date(timeIntervalSinceReferenceDate: 5)
        )
    }

    @Test("a book read and then removed leaves its name; one never opened leaves none")
    @MainActor
    func removedReadBookLeavesRecord() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SearchRecentsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suiteName = "SearchRecentsTests.removed.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = BookStore(
            metadataFileURL: directory.appendingPathComponent("books_meta.json"),
            offShelfReadRecordsDefaults: defaults
        )
        let read = Date(timeIntervalSinceReferenceDate: 800_000_000)
        // Online, so deleting them touches only their own cache folders.
        var opened = ReadingBook(title: "讀過的書", author: "作者", contentFilename: "")
        opened.isOnline = true
        opened.lastOpenedDate = read
        opened.coverUrl = "https://example.com/cover.jpg"
        var unopened = ReadingBook(title: "沒打開過的書", author: "作者", contentFilename: "")
        unopened.isOnline = true
        store.saveReadingBook(opened)
        store.saveReadingBook(unopened)

        store.delete(bookId: opened.id)
        store.delete(bookId: unopened.id)

        let stored = defaults.string(forKey: OffShelfReadRecords.storageKey)
            .flatMap(OffShelfReadRecords.init(rawValue:))
        #expect(stored?.records == [
            OffShelfReadRecords.Record(
                title: "讀過的書",
                author: "作者",
                coverUrl: "https://example.com/cover.jpg",
                lastRead: read
            ),
        ])
    }

    // MARK: Row content

    @Test("a shelf book's detail is how far it has been read; an audiobook carries the tag")
    func shelfRowContent() {
        var book = makeBook("三體", opened: Date())
        book.currentPosition = 0.374

        let reading = SearchBookListRowContent(shelfBook: book)
        #expect(reading.detail == String(format: localized("已讀 %d%%"), 37))
        #expect(reading.titleTag == nil)

        book.currentPosition = 1
        book.contentPipelineKind = .audio
        let finished = SearchBookListRowContent(shelfBook: book)
        #expect(finished.detail == localized("已讀完"))
        #expect(finished.titleTag == localized("有聲書"))
    }

    @Test("a result's detail is its kind and how many sources carry it")
    @MainActor
    func resultRowContent() {
        let novel = SearchBook(
            name: "斗羅大陸",
            author: "唐家三少",
            preparedOrigins: [prepared(kind: .text), prepared(kind: .text)]
        )
        let novelRow = SearchBookListRowContent(result: novel)
        #expect(novelRow.titleTag == nil)
        #expect(
            novelRow.detail
                == localized("小說") + " · " + String(format: localized("%d 源"), 2)
        )
        #expect(novelRow.accessibilityLabel.hasPrefix("斗羅大陸，唐家三少，"))

        let audiobook = SearchBook(
            name: "三體廣播劇",
            author: "劉慈欣",
            preparedOrigins: [prepared(kind: .audio)]
        )
        let audiobookRow = SearchBookListRowContent(result: audiobook)
        #expect(audiobookRow.titleTag == localized("有聲書"))
        // The tag already names the kind; the detail does not repeat it.
        #expect(audiobookRow.detail == String(format: localized("%d 源"), 1))
        #expect(audiobookRow.accessibilityLabel.contains(localized("有聲書")))
    }

    @Test("English counts one source in the singular")
    func englishSourceCountPlural() throws {
        let path = try #require(Bundle.main.path(forResource: "en", ofType: "lproj"))
        let english = try #require(Bundle(path: path))
        // The stringsdict's plural category comes from the formatting locale, not from the
        // bundle the format was read from. An English user's process locale is English; the
        // simulator's is zh_TW, whose only category is `other` ("1 sources"). So the format
        // is applied as an English user's app applies it.
        let locale = Locale(identifier: "en")

        #expect(String(format: localized("%d 源", bundle: english), locale: locale, 1) == "1 source")
        #expect(String(format: localized("%d 源", bundle: english), locale: locale, 3) == "3 sources")
    }

    // MARK: Helpers

    private func titles(of entries: [RecentReadingSelection.Entry]) -> [String] {
        entries.map { entry in
            switch entry {
            case .shelf(let book): book.title
            case .record(let record): record.title
            }
        }
    }

    private func offShelfRecord(_ title: String, read: Date) -> OffShelfReadRecords.Record {
        OffShelfReadRecords.Record(title: title, author: "作者", coverUrl: "", lastRead: read)
    }

    private func makeBook(_ title: String, opened: Date?) -> ReadingBook {
        var book = ReadingBook(title: title, author: "作者", contentFilename: "\(title).txt")
        book.lastOpenedDate = opened
        return book
    }

    private func prepared(kind: OnlineBookContentKind) -> PreparedSearchOrigin {
        PreparedSearchOrigin(
            origin: BookOrigin(
                sourceId: UUID(),
                sourceName: "測試書源",
                bookUrl: "https://example.com/book/\(UUID().uuidString)",
                tocUrl: "",
                coverUrl: "",
                intro: "",
                lastChapter: "",
                wordCount: "",
                kind: "",
                runtimeVariables: nil
            ),
            presentation: SearchOriginPresentation(
                contentKind: kind,
                displayIntro: "",
                detailIntro: "",
                introCharacterCount: 0,
                lastChapterTitleCandidate: "",
                introTitleCandidate: ""
            )
        )
    }
}
