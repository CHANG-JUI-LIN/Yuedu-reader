import Foundation
import Testing
@testable import yuedu_app

/// Unified library 5d-6b: Explore's 系列下一本 (Phase 5 plan, decisions 24 and 25) — the next
/// numbered book of each series being read or read to the end.
@Suite("Next in series")
struct NextInSeriesTests {
    private static let dav = SourceInstanceKey(type: .webDAV, id: "dav")

    private static func copy(_ title: String, _ number: Double?, author: String = "劉慈欣",
                             series: String? = "地球往事") -> WorkIndexEntry {
        let id = UUID()
        let record = SourceRecord(key: .copy(id), title: title, authors: [author], language: nil, contentKind: .text,
                                  identifiers: [], copyID: id, acquisitions: [])
        return WorkIndexEntry(record: record, series: series, seriesIndex: number)
    }

    private static func file(_ title: String, _ number: Double?, author: String = "劉慈欣",
                             series: String? = "地球往事") -> WorkIndexEntry {
        let record = SourceRecord(key: SourceItemKey(instance: dav, item: "\(title).epub"), title: title, authors: [author],
                                  language: nil, contentKind: .text, identifiers: [], copyID: nil,
                                  acquisitions: [.download(format: "epub")])
        return WorkIndexEntry(record: record, series: series, seriesIndex: number)
    }

    private func pick(_ entries: [WorkIndexEntry], seeds: [WorkIndexEntry], continueReading: [WorkIndexEntry]? = nil,
                      finished: [WorkIndexEntry] = [], limit: Int = 20) -> [SourceItemKey] {
        NextInSeries.pick(in: WorkIndex.build(entries: entries), seeds: seeds.map(\.nodeKey),
                          continueReading: Set((continueReading ?? seeds).map(\.nodeKey)), finished: Set(finished.map(\.nodeKey)),
                          shown: Set(entries.map(\.nodeKey)), limit: limit)
    }

    @Test("the smallest number after the book's own; one before it, or the book itself, is not offered")
    func smallestNextNumber() {
        let first = Self.copy("三體", 1)
        let second = Self.copy("黑暗森林", 2)
        let third = Self.copy("死神永生", 3)
        let prequel = Self.copy("前傳", 0.5)
        #expect(pick([first, second, third, prequel], seeds: [second]) == [third.nodeKey])
        #expect(pick([first, third, second, prequel], seeds: [first]) == [second.nodeKey])
        #expect(pick([third, first], seeds: [third]).isEmpty, "nothing comes after the last")
    }

    @Test("a fractional number sits between its neighbours")
    func fractionalNumber() {
        let first = Self.copy("三體", 1)
        let between = Self.copy("外傳", 1.5)
        let second = Self.copy("黑暗森林", 2)
        #expect(pick([first, second, between], seeds: [first]) == [between.nodeKey])
    }

    @Test("a book read to the end seeds the row though it left 繼續閱讀, and the next after a read one is offered")
    func finishedBooks() {
        let first = Self.copy("三體", 1)
        let second = Self.copy("黑暗森林", 2)
        let third = Self.copy("死神永生", 3)
        // 標記為已讀完 took 三體 out of 繼續閱讀.
        #expect(pick([first, second, third], seeds: [first], continueReading: [], finished: [first]) == [second.nodeKey])
        // 黑暗森林 was read too: 死神永生 is next.
        #expect(pick([first, second, third], seeds: [first], continueReading: [], finished: [first, second])
                == [third.nodeKey])
    }

    @Test("two books of one series being read give one card, the next after the latest opened")
    func oneCardASeries() {
        let first = Self.copy("三體", 1)
        let second = Self.copy("黑暗森林", 2)
        let third = Self.copy("死神永生", 3)
        let fourth = Self.copy("三體X", 4)
        // 黑暗森林 was opened last; 三體 is still in 繼續閱讀.
        #expect(pick([first, second, third, fourth], seeds: [second, first]) == [third.nodeKey])
    }

    @Test("same series name by another author, or a series with no number, offers nothing")
    func needsAuthorAndNumber() {
        let seed = Self.copy("基地", 1, author: "艾西莫夫", series: "基地")
        let otherAuthor = Self.copy("基地前奏", 2, author: "別人", series: "基地")
        #expect(pick([seed, otherAuthor], seeds: [seed]).isEmpty)

        let unnumbered = Self.copy("三體", nil)
        let sequel = Self.copy("黑暗森林", 2)
        #expect(pick([unnumbered, sequel], seeds: [unnumbered]).isEmpty, "a name alone does not say what comes next")
        let numbered = Self.copy("三體", 1)
        let sequelWithoutNumber = Self.copy("黑暗森林", nil)
        #expect(pick([numbered, sequelWithoutNumber], seeds: [numbered]).isEmpty)
    }

    @Test("a shelf copy stands for its work before an indexed file of it; a copy takes its number from its work")
    func shelfCopyFirst() {
        let seed = Self.copy("三體", 1)
        let file = Self.file("黑暗森林", 2)
        let shelfCopy = Self.copy("黑暗森林", 2)
        #expect(pick([seed, file, shelfCopy], seeds: [seed]) == [shelfCopy.nodeKey])
        #expect(pick([seed, file], seeds: [seed]) == [file.nodeKey])

        // The copy's sidecar has no number; the WebDAV file of the same book has.
        let unnumberedCopy = Self.copy("三體", nil)
        let numberedFile = Self.file("三體", 1)
        let sequel = Self.file("黑暗森林", 2)
        #expect(pick([unnumberedCopy, numberedFile, sequel], seeds: [unnumberedCopy]) == [sequel.nodeKey])
    }

    @Test("one card per series, newest seed first, up to the limit")
    func limit() {
        let santi = Self.copy("三體", 1)
        let heian = Self.copy("黑暗森林", 2)
        let foundation = Self.copy("基地", 1, author: "艾西莫夫", series: "基地")
        let empire = Self.copy("基地與帝國", 2, author: "艾西莫夫", series: "基地")
        let entries = [santi, heian, foundation, empire]
        #expect(pick(entries, seeds: [foundation, santi]) == [empire.nodeKey, heian.nodeKey])
        #expect(pick(entries, seeds: [foundation, santi], limit: 1) == [empire.nodeKey])
        #expect(pick(entries, seeds: [foundation, santi], limit: 0).isEmpty)
    }
}

/// The number in the work index (5d-6b): from the place the series name came from.
@Suite("Series number in the work index")
struct SeriesNumberIndexTests {
    private let calibre = SourceInstanceKey(type: .calibre, id: "c")

    private func value(_ field: MetadataField, _ payload: MetadataPayload, _ provider: SourceInstanceKey,
                       _ item: SourceItemKey?) -> MetadataValue {
        MetadataValue(field: field, value: payload, provider: provider, sourceItem: item, fetchedAt: Date(timeIntervalSinceReferenceDate: 0))
    }

    @Test("the number comes with the name from one place, never from another place's")
    func samePlace() {
        let id = UUID()
        let record = SourceRecord(key: .copy(id), title: "黑暗森林", authors: ["劉慈欣"], language: nil, contentKind: .text,
                                  identifiers: [], copyID: id, acquisitions: [])
        let opf = SourceItemKey.copy(id)
        let calibreItem = SourceItemKey(instance: calibre, item: "7")
        let entry = WorkIndexService.entry(for: record, sidecar: ImportedMetadata(copyID: id, sourceItem: opf, identifiers: [], values: [
            value(.series, .text("地球往事"), .localLibrary, opf),
            value(.seriesIndex, .number(2), .localLibrary, opf),
            value(.seriesIndex, .number(9), calibre, calibreItem),
        ]))
        #expect(entry.seriesKey == WorkMatchKey.title("地球往事"))
        #expect(entry.seriesIndex == 2)

        // The name's place has no number: none, although Calibre has one.
        let named = WorkIndexService.series(in: [
            value(.series, .text("地球往事"), .localLibrary, opf),
            value(.seriesIndex, .number(9), calibre, calibreItem),
        ], for: record)
        #expect(named?.name == "地球往事")
        #expect(named?.number == nil)
        #expect(WorkIndexService.series(in: [value(.seriesIndex, .number(2), .localLibrary, opf)], for: record) == nil)
    }

    @Test("an index file from before series numbers is rebuilt")
    func schemaThreeIsDiscarded() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("series-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("index.json")
        let old = WorkIndexFile(schemaVersion: 3, inputs: [], remoteInputs: [], decisions: [], index: .empty)
        try JSONEncoder().encode(old).write(to: url)
        guard case .discarded = WorkIndexService.load(url) else {
            Issue.record("a schema-3 file is discarded")
            return
        }
    }

    @Test("an EPUB's series and number go to the sidecar; a number without a name does not")
    func capture() {
        let item = SourceItemKey.copy(UUID())
        func fields(_ series: ImportedMetadataCapture.EPUBSeries?) -> [MetadataField: MetadataPayload] {
            let read = ImportedMetadataCapture.epubFields(sourceItem: item, identifiers: [], languages: [], description: nil,
                                                          subjects: [], publishers: [], published: nil, series: series)
            return Dictionary(read.values.map { ($0.field, $0.value) }, uniquingKeysWith: { first, _ in first })
        }
        let numbered = fields(.init(name: "地球往事", position: 2))
        #expect(numbered[.series] == .text("地球往事"))
        #expect(numbered[.seriesIndex] == .number(2))
        #expect(fields(.init(name: "地球往事", position: nil))[.seriesIndex] == nil)
        #expect(fields(.init(name: "  ", position: 2)).isEmpty)
        #expect(fields(nil).isEmpty)
    }
}

/// The row on the shelf (5d-6b).
@MainActor
@Suite("Next in series row", .serialized)
struct NextInSeriesRowTests {
    @Test("系列下一本 on the shelf: the next number after a book read to the end, after the series pass")
    func shelfRow() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NextInSeries-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = BookStore(metadataFileURL: folder.appendingPathComponent("books_meta.json"))
        defer {
            store.importedMetadata.waitForPendingWritesForTesting()
            WorkIndexService.waitForPendingSavesForTesting()
            store.waitForQueuedWrites()
        }
        func book(_ title: String) -> ReadingBook {
            ReadingBook(title: title, author: "劉慈欣", source: "local_epub", contentFilename: "\(UUID().uuidString).epub")
        }
        var first = book("三體")
        first.lastOpenedDate = Date()
        let second = book("黑暗森林")
        let third = book("死神永生")
        let unrelated = book("球狀閃電")
        [first, second, third, unrelated].forEach { store.saveReadingBook($0) }
        for (copy, number) in [(first, 1.0), (second, 2), (third, 3)] {
            store.importedMetadata.write(ImportedMetadata(copyID: copy.id, sourceItem: .copy(copy.id), identifiers: [], values: [
                MetadataValue(field: .series, value: .text("地球往事"), provider: .localLibrary, sourceItem: .copy(copy.id), fetchedAt: Date()),
                MetadataValue(field: .seriesIndex, value: .number(number), provider: .localLibrary, sourceItem: .copy(copy.id), fetchedAt: Date()),
            ]))
        }
        store.importedMetadata.waitForPendingWritesForTesting()
        let section = HomeSection(layout: .row, binding: .nextInSeries)
        let provider = ShelfProvider(store: store)
        #expect(provider.loadPolicy(for: section) == .local)

        func titles() async throws -> [String] {
            try await provider.load(section).compactMap { entry -> String? in
                if case .item(let record, _, _) = entry { return record.title }
                return nil
            }
        }
        #expect(try await titles() == ["黑暗森林"])
        // The copies' files are not there: the pass read none, and does not try again.
        #expect(store.seriesNumberBackfill.isDone)

        store.markFinished(bookId: first.id)
        #expect(try await titles() == ["黑暗森林"], "read to the end, 三體 still leads to the next")
        store.markFinished(bookId: second.id)
        #expect(try await titles() == ["死神永生"])
    }

    @Test("with nothing opened the row is empty and the pass does not run")
    func nothingOpened() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NextInSeries-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = BookStore(metadataFileURL: folder.appendingPathComponent("books_meta.json"))
        defer { store.waitForQueuedWrites() }
        store.saveReadingBook(ReadingBook(title: "三體", author: "劉慈欣", source: "local_epub", contentFilename: "a.epub"))
        #expect(await ShelfProvider(store: store).nextInSeries(limit: HomeRow.limit).isEmpty)
        #expect(!store.seriesNumberBackfill.isDone)
    }
}
