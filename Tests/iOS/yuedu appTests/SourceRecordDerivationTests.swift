import Foundation
import Testing
@testable import yuedu_app

/// Unified library, Phase 1a: every kind of book and remote item derives one source record,
/// and the 書籍資訊 「來源」 row reads from it.
@Suite("Source record derivation")
struct SourceRecordDerivationTests {
    // MARK: - Identifiers

    @Test("ISBNs are validated and become ISBN-13s")
    func isbnNormalization() {
        // 三體 (重慶出版社), ISBN 978-7-5366-9293-0; its ISBN-10 form 7-5366-9293-5.
        #expect(ExternalIdentifier.normalized(.isbn13, "978-7-5366-9293-0")?.value == "9787536692930")
        #expect(ExternalIdentifier.normalized(.isbn13, "urn:isbn:9787536692930")?.value == "9787536692930")
        #expect(ExternalIdentifier.normalized(.isbn13, "7-5366-9293-5")?.value == "9787536692930")
        #expect(ExternalIdentifier.normalized(.isbn13, "0-306-40615-2")?.value == "9780306406157")
        #expect(ExternalIdentifier.normalized(.isbn13, "080442957X")?.value == "9780804429573")
        #expect(ExternalIdentifier.normalized(.isbn13, "978-7-5366-9293-1") == nil, "wrong check digit")
        #expect(ExternalIdentifier.normalized(.isbn13, "7-5366-9293-9") == nil, "wrong check digit")
        #expect(ExternalIdentifier.normalized(.isbn13, "12345") == nil)
    }

    @Test("Calibre uuids drop urn:uuid: and are lowercased; Gutenberg numbers come from urns and URLs")
    func uuidAndGutenberg() {
        #expect(ExternalIdentifier.normalized(.calibreUUID, "urn:uuid:6BA7B810-9DAD-11D1-80B4-00C04FD430C8")?.value
            == "6ba7b810-9dad-11d1-80b4-00c04fd430c8")
        #expect(ExternalIdentifier.normalized(.calibreUUID, "not-a-uuid") == nil)
        #expect(ExternalIdentifier.normalized(.gutenberg, "1342")?.value == "1342")
        #expect(ExternalIdentifier.normalized(.gutenberg, "urn:gutenberg:1342:2")?.value == "1342")
        #expect(ExternalIdentifier.normalized(.gutenberg, "第1342") == nil)
        #expect(ExternalIdentifier.gutenbergNumber(from: "urn:gutenberg:1342:2") == "1342")
        #expect(ExternalIdentifier.gutenbergNumber(from: "https://www.gutenberg.org/ebooks/1342.opds") == "1342")
        #expect(ExternalIdentifier.gutenbergNumber(from: "https://www.gutenberg.org/ebooks/79734") == "79734")
        #expect(ExternalIdentifier.gutenbergNumber(from: "https://example.com/ebooks/1342") == nil)
    }

    // MARK: - The shared detail URL key

    @Test("the detail URL key keeps the shelf lookup's behavior")
    func onlineBookURLKey() {
        #expect(OnlineBookURLKey.normalize(" https://Site.example/Book/1#chapter ") == "https://site.example/book/1")
        #expect(OnlineBookURLKey.normalize("https://site.example/book/1") == "https://site.example/book/1")
        #expect(OnlineBookURLKey.normalize("   ") == "")
        #expect(OnlineBookURLKey.normalize(nil) == "")
    }

    @MainActor
    @Test("the shelf still finds an online book added with a differently written URL")
    func shelfLookupUsesTheSharedKey() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("source-record-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BookStore(metadataFileURL: directory.appendingPathComponent("books_meta.json"))
        let sourceID = UUID()
        let added = store.addOnlineBook(
            name: "Phase 1a", author: "", sourceId: sourceID,
            bookInfoURL: "https://phase1a.test/Book/1#top", chapters: []
        )

        #expect(store.onlineBook(sourceId: sourceID, bookInfoURL: "https://PHASE1A.test/book/1")?.id == added.id)
        #expect(store.onlineBook(sourceId: UUID(), bookInfoURL: "https://phase1a.test/book/1") == nil)
    }

    // MARK: - Copies on this device

    @Test("local files: the copy is the record, kind follows the pipeline")
    func localCopies() {
        let cases: [(source: String, pipeline: BookPipelineKind, kind: ContentKind)] = [
            ("local", .txt, .text),
            ("local_epub", .epub, .text),
            ("local_epub", .fixedPage, .text),
            ("local_pdf", .fixedPage, .text),
            ("local_manga", .manga, .comic),
            ("local_audio", .audio, .audio),
        ]
        for testCase in cases {
            var book = ReadingBook(title: "三體", author: "劉慈欣", source: testCase.source, contentFilename: "x")
            book.contentPipelineKind = testCase.pipeline
            let record = SourceRecord.derived(from: book, context: context())

            #expect(record.key == .copy(book.id), "\(testCase.source)")
            #expect(record.copyID == book.id)
            #expect(record.copyKey == .copy(book.id))
            #expect(record.contentKind == testCase.kind, "\(testCase.source) \(testCase.pipeline)")
            #expect(record.authors == ["劉慈欣"])
            #expect(record.acquisitions == [.openCopy(book.id)])
            #expect(record.identifiers.isEmpty)
        }
    }

    @Test("Aozora copies are keyed by their catalog work id")
    func aozoraCopy() {
        var book = ReadingBook(title: "吾輩は猫である", source: "local_epub", contentFilename: "x")
        book.aozora = AozoraBookSource(originalFilename: "x.zip", sourceEncoding: 0, catalogWorkID: "000789")
        let record = SourceRecord.derived(from: book, context: context())

        #expect(record.key == SourceItemKey(instance: SourceInstanceKey(type: .aozora, id: "builtin.aozora"), item: "000789"))
        #expect(record.identifiers == [ExternalIdentifier.normalized(.aozoraWork, "000789")!])
        #expect(record.copyID == book.id)

        book.aozora?.catalogWorkID = nil
        #expect(SourceRecord.derived(from: book, context: context()).key == .copy(book.id))
    }

    @Test("remote copies are keyed by connection and entry; WebDAV by the path below the root")
    func remoteCopies() {
        let opds = remoteBook(connectionID: "c-opds", entryID: "urn:isbn:9787536692930", format: "epub")
        let calibre = remoteBook(connectionID: "c-calibre", entryID: "urn:uuid:6BA7B810-9DAD-11D1-80B4-00C04FD430C8", format: "pdf")
        let webDAV = remoteBook(connectionID: "c-dav", entryID: "https://dav.phase1a.test/books/%E4%B8%89%E9%AB%94%20I.epub", format: "epub")
        let ctx = context(kinds: ["c-opds": .opds, "c-calibre": .calibre, "c-dav": .webDAV],
                          roots: ["c-dav": URL(string: "https://dav.phase1a.test/books/")!])

        let opdsRecord = SourceRecord.derived(from: opds, context: ctx)
        #expect(opdsRecord.key == SourceItemKey(instance: SourceInstanceKey(type: .opds, id: "c-opds"), item: "urn:isbn:9787536692930"))
        #expect(opdsRecord.identifiers == [ExternalIdentifier.normalized(.isbn13, "9787536692930")!])

        let calibreRecord = SourceRecord.derived(from: calibre, context: ctx)
        #expect(calibreRecord.key.instance == SourceInstanceKey(type: .calibre, id: "c-calibre"))
        #expect(calibreRecord.identifiers == [ExternalIdentifier.normalized(.calibreUUID, "6ba7b810-9dad-11d1-80b4-00c04fd430c8")!])

        let davRecord = SourceRecord.derived(from: webDAV, context: ctx)
        #expect(davRecord.key == SourceItemKey(instance: SourceInstanceKey(type: .webDAV, id: "c-dav"), item: "三體 I.epub"))
        #expect(davRecord.copyID == webDAV.id)
    }

    @Test("a uuid entry id on a plain OPDS connection is not a Calibre identifier")
    func uuidOnOPDSIsNotCalibre() {
        let book = remoteBook(connectionID: "c-opds", entryID: "urn:uuid:6ba7b810-9dad-11d1-80b4-00c04fd430c8", format: "epub")
        #expect(SourceRecord.derived(from: book, context: context(kinds: ["c-opds": .opds])).identifiers.isEmpty)
    }

    @Test("Gutenberg copies are keyed by ebook number")
    func gutenbergCopy() {
        let book = remoteBook(connectionID: "builtin.gutenberg", entryID: "https://www.gutenberg.org/ebooks/1342.opds", format: "epub")
        let record = SourceRecord.derived(from: book, context: context())

        #expect(record.key == SourceItemKey(instance: SourceInstanceKey(type: .gutenberg, id: "builtin.gutenberg"), item: "1342"))
        #expect(record.identifiers == [ExternalIdentifier.normalized(.gutenberg, "1342")!])
    }

    @Test("a copy whose connection was removed keeps its own key")
    func removedConnection() {
        let book = remoteBook(connectionID: "gone", entryID: "urn:isbn:9787536692930", format: "epub")
        #expect(SourceRecord.derived(from: book, context: context()).key == .copy(book.id))
    }

    @Test("book source copies are keyed by the source's URL and the normalized detail URL")
    func bookSourceCopies() {
        let sourceID = UUID()
        var book = ReadingBook(title: "斗罗大陆", author: "唐家三少", source: "https://Site.example/Book/9#x", contentFilename: "")
        book.isOnline = true
        book.bookSourceId = sourceID
        book.bookInfoURL = "https://Site.example/Book/9#x"
        book.contentPipelineKind = .html

        let present = SourceRecord.derived(from: book, context: context(sources: [sourceID: "https://source.example"]))
        #expect(present.key == SourceItemKey(
            instance: SourceInstanceKey(type: .bookSource, id: "https://source.example"),
            item: "https://site.example/book/9"
        ))
        #expect(present.copyID == book.id)

        let missing = SourceRecord.derived(from: book, context: context())
        #expect(missing.key.instance == SourceInstanceKey(type: .bookSource, id: "missing:\(sourceID.uuidString.lowercased())"))
    }

    @Test("browser imports are copies on this device")
    func browserImport() {
        var book = ReadingBook(title: "網頁", source: "https://page.example/a", contentFilename: "x")
        book.isOnline = true
        #expect(SourceRecord.derived(from: book, context: context()).key == .copy(book.id))
    }

    // MARK: - Items not yet on the shelf

    @Test("an OPDS entry keeps all its authors and its formats")
    func opdsEntry() {
        var entry = OPDSEntry(id: "urn:isbn:9787536692930", title: "三體")
        entry.authorNames = ["劉慈欣", "Ken Liu"]
        entry.acquisitions = [
            OPDSAcquisition(url: URL(string: "https://opds.example/a.epub")!, type: "application/epub+zip", rel: "http://opds-spec.org/acquisition"),
            OPDSAcquisition(url: URL(string: "https://opds.example/a.pdf")!, type: "application/pdf", rel: "http://opds-spec.org/acquisition"),
        ]
        let record = SourceRecord.derived(from: entry, connectionID: "c", connectionKind: .opds)

        #expect(record.key == SourceItemKey(instance: SourceInstanceKey(type: .opds, id: "c"), item: "urn:isbn:9787536692930"))
        #expect(record.authors == ["劉慈欣", "Ken Liu"])
        #expect(record.acquisitions == [.readRemote(format: "epub"), .download(format: "epub"), .readRemote(format: "pdf"), .download(format: "pdf")])
        #expect(record.copyID == nil)
    }

    @Test("a WebDAV file below the root is keyed by its path; a folder is not a record")
    func webDAVEntry() {
        let root = URL(string: "https://dav.example/library/")!
        let file = WebDAVBrowseClient.Entry(url: URL(string: "https://dav.example/library/sci-fi/a.epub")!, name: "a.epub", isDirectory: false, size: 1)
        let folder = WebDAVBrowseClient.Entry(url: URL(string: "https://dav.example/library/sci-fi/")!, name: "sci-fi", isDirectory: true, size: 0)
        let outside = WebDAVBrowseClient.Entry(url: URL(string: "https://dav.example/other/a.epub")!, name: "a.epub", isDirectory: false, size: 1)

        #expect(SourceRecord.derived(from: file, connectionID: "d", root: root)?.key.item == "sci-fi/a.epub")
        #expect(SourceRecord.derived(from: folder, connectionID: "d", root: root) == nil)
        #expect(SourceRecord.derived(from: outside, connectionID: "d", root: root) == nil)
    }

    @Test("a book source result is keyed like the copy it would become")
    func onlineBook() {
        var source = BookSource()
        source.bookSourceUrl = "https://source.example"
        let book = OnlineBook(name: "斗罗大陆", author: "唐家三少", intro: "", coverUrl: "",
                              bookUrl: "https://Site.example/Book/9#x", tocUrl: "", wordCount: "",
                              lastChapter: "", kind: "", sourceId: source.id, sourceName: "S")
        let record = SourceRecord.derived(from: book, source: source)

        #expect(record.key == SourceItemKey(
            instance: SourceInstanceKey(type: .bookSource, id: "https://source.example"),
            item: "https://site.example/book/9"
        ))
        #expect(record.acquisitions == [.readOnline])
    }

    @Test("Aozora works and Gutenberg books carry their own identifiers")
    func publicLibraryItems() {
        let work = AozoraWork(id: "000789", title: "吾輩は猫である", yomi: "", sortYomi: "", subtitle: "",
                              kanaStyle: "", ndc: "", published: "", updated: "", card: "", text: "",
                              textUpdated: "", credits: [], source: "", sourcePublisher: "")
        let aozora = SourceRecord.derived(from: work)
        #expect(aozora.key.item == "000789")
        #expect(aozora.language == "ja")
        #expect(aozora.identifiers == [ExternalIdentifier.normalized(.aozoraWork, "000789")!])

        let gutenberg = SourceRecord.derived(from: GutenbergBook(id: 1342, title: "Pride and Prejudice", author: "Jane Austen"))
        #expect(gutenberg.key.item == "1342")
        #expect(gutenberg.identifiers == [ExternalIdentifier.normalized(.gutenberg, "1342")!])
    }

    // MARK: - The 「來源」 row

    @Test("the 「來源」 row names where each copy came from")
    func sourceLabel() {
        func label(_ book: ReadingBook, _ ctx: SourceRecordContext = context()) -> String {
            SourceLabel.text(for: book, record: .derived(from: book, context: ctx))
        }
        var epub = ReadingBook(title: "a", source: "local_epub", contentFilename: "x")
        epub.contentPipelineKind = .epub
        #expect(label(ReadingBook(title: "a", source: "local", contentFilename: "x")) == localized("本機文件"))
        #expect(label(epub) == localized("本機文件"))
        #expect(label(ReadingBook(title: "a", source: "local_pdf", contentFilename: "x")) == localized("本機文件"))
        #expect(label(ReadingBook(title: "a", source: "local_manga", contentFilename: "x")) == localized("本機文件"))
        #expect(label(ReadingBook(title: "a", source: "local_audio", contentFilename: "x")) == localized("本機文件"))

        var browsed = ReadingBook(title: "a", source: "https://page.example", contentFilename: "x")
        browsed.isOnline = true
        #expect(label(browsed) == localized("網頁匯入"))
        #expect(label(ReadingBook(title: "a", source: "https://page.example", contentFilename: "x")) == localized("網頁匯入"))

        let sourceID = UUID()
        var online = ReadingBook(title: "a", source: "https://site.example/b", contentFilename: "")
        online.isOnline = true
        online.bookSourceId = sourceID
        #expect(label(online, context(sources: [sourceID: "https://source.example"])) == localized("網路書籍"))

        let kinds: [String: RemoteLibraryKind] = ["o": .opds, "w": .webDAV, "c": .calibre]
        let roots = ["w": URL(string: "https://dav.example/")!]
        #expect(label(remoteBook(connectionID: "o", entryID: "e", format: "epub"), context(kinds: kinds)) == localized("OPDS 書庫"))
        #expect(label(remoteBook(connectionID: "w", entryID: "https://dav.example/a.epub", format: "epub"), context(kinds: kinds, roots: roots)) == localized("WebDAV 書庫"))
        #expect(label(remoteBook(connectionID: "c", entryID: "e", format: "epub"), context(kinds: kinds)) == localized("Calibre 書庫"))
        #expect(label(remoteBook(connectionID: "builtin.gutenberg", entryID: "urn:gutenberg:1342", format: "epub")) == localized("Project Gutenberg"))
        #expect(label(remoteBook(connectionID: "removed", entryID: "e", format: "epub")) == localized("遠端書庫"))

        var aozora = ReadingBook(title: "a", source: "local_epub", contentFilename: "x")
        aozora.aozora = AozoraBookSource(originalFilename: "x.zip", sourceEncoding: 0, catalogWorkID: "000789")
        #expect(label(aozora) == localized("青空文庫"))
        aozora.aozora?.catalogWorkID = nil
        #expect(label(aozora) == localized("青空文庫"))
    }

    // MARK: - Helpers

    private func context(
        sources: [UUID: String] = [:],
        kinds: [String: RemoteLibraryKind] = [:],
        roots: [String: URL] = [:]
    ) -> SourceRecordContext {
        SourceRecordContext(
            bookSourceURL: { sources[$0] },
            connectionKind: { kinds[$0] },
            webDAVRoot: { roots[$0] }
        )
    }

    private func remoteBook(connectionID: String, entryID: String, format: String) -> ReadingBook {
        var book = ReadingBook(title: "三體", author: "劉慈欣", source: "local_\(format)", contentFilename: "x")
        book.remoteSource = RemoteBookReference(
            connectionID: connectionID,
            entryID: entryID,
            format: RemoteLibraryFormat(url: URL(string: "https://remote.example/a.\(format)")!, fileExtension: format, mimeType: "")
        )
        return book
    }
}
