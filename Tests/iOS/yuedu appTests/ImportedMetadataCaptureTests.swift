import Foundation
import Testing
@testable import yuedu_app

/// Unified library 1b: what each import reads beyond title and author.
@Suite("Imported metadata capture")
struct ImportedMetadataCaptureTests {
    private let copy = ReadingBook(title: "三體", author: "劉慈欣", source: "local_epub", contentFilename: "x.epub")
    private let fixed = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - OPF identifiers

    @Test("every dc:identifier is read, with its scheme, not only the unique one")
    func opfIdentifiers() {
        let opf = """
        <package unique-identifier="bookid" xmlns="http://www.idpf.org/2007/opf">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
            <dc:identifier id="bookid">urn:uuid:7408D53A-5383-40AA-8078-5256C872AE41</dc:identifier>
            <dc:identifier opf:scheme="ISBN">978-7-5366-9293-0</dc:identifier>
            <dc:identifier opf:scheme="calibre">6ba7b810-9dad-11d1-80b4-00c04fd430c8</dc:identifier>
            <dc:identifier>  </dc:identifier>
            <meta property="dcterms:identifier">not-an-element</meta>
          </metadata>
        </package>
        """
        let identifiers = PublicationSession.opfIdentifiers(in: opf)

        #expect(identifiers == [
            .init(value: "urn:uuid:7408D53A-5383-40AA-8078-5256C872AE41", scheme: nil),
            .init(value: "978-7-5366-9293-0", scheme: "ISBN"),
            .init(value: "6ba7b810-9dad-11d1-80b4-00c04fd430c8", scheme: "calibre"),
        ])
    }

    @Test("identifiers are classified as ISBN, Calibre uuid or a package-only identifier")
    func classification() {
        typealias OPF = PublicationSession.OPFIdentifier
        #expect(ImportedMetadataCapture.classify(OPF(value: "978-7-5366-9293-0", scheme: "ISBN")) == .normalized(.isbn13, "9787536692930"))
        #expect(ImportedMetadataCapture.classify(OPF(value: "urn:isbn:7536692935", scheme: nil)) == .normalized(.isbn13, "9787536692930"))
        #expect(ImportedMetadataCapture.classify(OPF(value: "9787536692930", scheme: nil)) == .normalized(.isbn13, "9787536692930"))
        // Calibre's two identifiers: the application id is no uuid of the book; the uuid is,
        // but only in a package Calibre wrote (Sigil also writes opf:scheme="UUID").
        let calibrePackage = [OPF(value: "42", scheme: "calibre"), OPF(value: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8", scheme: "uuid")]
        #expect(ImportedMetadataCapture.classify(calibrePackage[0], in: calibrePackage) == nil)
        #expect(ImportedMetadataCapture.classify(calibrePackage[1], in: calibrePackage)
            == .normalized(.calibreUUID, "6ba7b810-9dad-11d1-80b4-00c04fd430c8"))
        #expect(ImportedMetadataCapture.classify(OPF(value: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8", scheme: "UUID"))
            == .normalized(.epubUniqueIdentifier, "6BA7B810-9DAD-11D1-80B4-00C04FD430C8"))
        // OPF 3 has no opf:scheme; calibre's opf3.py writes the scheme into the text.
        let calibre3 = [OPF(value: "calibre:42", scheme: nil), OPF(value: "uuid:6BA7B810-9DAD-11D1-80B4-00C04FD430C8", scheme: nil)]
        #expect(ImportedMetadataCapture.classify(calibre3[0], in: calibre3) == nil)
        #expect(ImportedMetadataCapture.classify(calibre3[1], in: calibre3)
            == .normalized(.calibreUUID, "6ba7b810-9dad-11d1-80b4-00c04fd430c8"))
        #expect(ImportedMetadataCapture.classify(calibre3[1]) == .normalized(.epubUniqueIdentifier, "uuid:6BA7B810-9DAD-11D1-80B4-00C04FD430C8"),
                "without calibre's own identifier, a uuid: text is only a package id")
        #expect(ImportedMetadataCapture.classify(OPF(value: "urn:uuid:ABC-1", scheme: nil)) == .normalized(.epubUniqueIdentifier, "abc-1"))
        #expect(ImportedMetadataCapture.classify(OPF(value: "1234567890123", scheme: nil)) == .normalized(.epubUniqueIdentifier, "1234567890123"),
                "13 digits with a wrong check digit are not an ISBN")
    }

    @Test("an EPUB's languages, description, subjects, publisher and date become values")
    func epubValues() {
        let sourceItem = SourceItemKey.copy(copy.id)
        let metadata = ImportedMetadataCapture.epub(
            copy: copy, sourceItem: sourceItem,
            identifiers: [.init(value: "978-7-5366-9293-0", scheme: "ISBN")],
            languages: ["zh-Hans", "zh-Hans", " "], description: "<p>地球往事<b>三部曲</b></p>",
            subjects: ["科幻", "小說"], publishers: ["重慶出版社"], published: fixed, now: fixed
        )

        #expect(metadata.copyID == copy.id)
        #expect(metadata.sourceItem == sourceItem)
        #expect(metadata.identifiers == [.normalized(.isbn13, "9787536692930")!])
        #expect(value(.language, in: metadata) == .texts(["zh-Hans"]))
        #expect(value(.intro, in: metadata) == .text("地球往事三部曲"))
        #expect(value(.tags, in: metadata) == .texts(["科幻", "小說"]))
        #expect(value(.publisher, in: metadata) == .text("重慶出版社"))
        #expect(value(.publishedDate, in: metadata) == .date(fixed))
        #expect(metadata.values.allSatisfy { $0.provider == sourceItem.instance && $0.sourceItem == sourceItem })
    }

    @Test("an EPUB with nothing beyond title and author leaves nothing to write")
    func emptyEPUB() {
        let metadata = ImportedMetadataCapture.epub(
            copy: copy, sourceItem: .copy(copy.id), identifiers: [], languages: [], description: nil,
            subjects: [], publishers: [], published: nil
        )
        #expect(metadata.isEmpty)
    }

    // MARK: - Remote libraries

    @Test("a remote item keeps its summary, authors, language and identifiers")
    func remoteItem() {
        let item = RemoteLibraryItem(
            id: "urn:uuid:6ba7b810-9dad-11d1-80b4-00c04fd430c8", connectionID: "c", title: "三體",
            summary: "地球往事", formats: [],
            authorNames: ["劉慈欣", "Ken Liu"], language: "zh", identifiers: ["urn:isbn:9787536692930"]
        )
        let sourceItem = SourceItemKey(instance: SourceInstanceKey(type: .calibre, id: "c"), item: item.id)
        let metadata = ImportedMetadataCapture.remote(item: item, copy: copy, sourceItem: sourceItem, connectionKind: .calibre, now: fixed)

        #expect(Set(metadata.identifiers) == [
            .normalized(.isbn13, "9787536692930")!,
            .normalized(.calibreUUID, "6ba7b810-9dad-11d1-80b4-00c04fd430c8")!,
        ])
        #expect(value(.intro, in: metadata) == .text("地球往事"))
        #expect(value(.authors, in: metadata) == .texts(["劉慈欣", "Ken Liu"]))
        #expect(value(.language, in: metadata) == .texts(["zh"]), "the same shape as every other capture")
    }

    @Test("OPDS 1 entries keep dc:language and dc:identifier")
    func opds1Fields() throws {
        let atom = """
        <feed xmlns="http://www.w3.org/2005/Atom" xmlns:dc="http://purl.org/dc/terms/">
          <id>feed</id><title>Feed</title>
          <entry>
            <id>urn:uuid:entry-1</id><title>三體</title>
            <dc:language>zh-Hans</dc:language>
            <dc:identifier>urn:isbn:9787536692930</dc:identifier>
            <link rel="http://opds-spec.org/acquisition" href="/a.epub" type="application/epub+zip"/>
          </entry>
        </feed>
        """
        let feed = try OPDSClient.parseFeed(data: Data(atom.utf8), feedURL: URL(string: "https://opds.example/feed")!)
        let entry = try #require(feed.entries.first)
        #expect(entry.language == "zh-Hans")
        #expect(entry.identifiers == ["urn:isbn:9787536692930"])
        #expect(RemoteLibraryBookRoute(entry: entry, connectionID: "c").item.identifiers == ["urn:isbn:9787536692930"])
        #expect(RemoteLibraryBookRoute(entry: entry, connectionID: "c").item.language == "zh-Hans")
    }

    @Test("OPDS 2 publications keep their language and identifier")
    func opds2Fields() throws {
        let json = """
        {"metadata":{"title":"Feed"},"publications":[{"metadata":{"identifier":"urn:isbn:9787536692930","title":"三體","language":["zh-Hans","en"]},
        "links":[{"rel":"http://opds-spec.org/acquisition/open-access","href":"/a.epub","type":"application/epub+zip"}]}]}
        """
        let feed = try OPDSClient.parseFeed(data: Data(json.utf8), feedURL: URL(string: "https://opds.example/feed")!, contentType: "application/opds+json")
        let entry = try #require(feed.entries.first)
        #expect(entry.language == "zh-Hans")
        #expect(entry.identifiers == ["urn:isbn:9787536692930"])
    }

    // MARK: - Calibre wireless and Aozora

    @Test("Calibre's uuid, ISBN, languages, tags, comments, series and publisher are kept")
    func calibre() {
        let metadata: [String: CalibreJSON] = [
            "uuid": .string("6BA7B810-9DAD-11D1-80B4-00C04FD430C8"),
            "isbn": .string("9787536692930"),
            "identifiers": .object(["isbn": .string("7-5366-9293-5"), "goodreads": .string("1")]),
            "languages": .array([.string("zho")]),
            "tags": .array([.string("科幻"), .string("雨果獎")]),
            "comments": .string("<div><p>地球往事</p></div>"),
            "series": .string("地球往事"),
            "series_index": .number(1),
            "publisher": .string("重慶出版社"),
            "pubdate": .string("2008-01-01T00:00:00+00:00"),
        ]
        let captured = ImportedMetadataCapture.calibre(metadata: metadata, copy: copy, libraryID: "lib-1", now: fixed)

        #expect(captured.identifiers == [
            .normalized(.calibreUUID, "6ba7b810-9dad-11d1-80b4-00c04fd430c8")!,
            .normalized(.isbn13, "9787536692930")!,
        ])
        #expect(value(.language, in: captured) == .texts(["zho"]))
        #expect(value(.tags, in: captured) == .texts(["科幻", "雨果獎"]))
        #expect(value(.intro, in: captured) == .text("地球往事"))
        #expect(value(.series, in: captured) == .text("地球往事"))
        #expect(value(.seriesIndex, in: captured) == .number(1))
        #expect(value(.publisher, in: captured) == .text("重慶出版社"))
        #expect(value(.publishedDate, in: captured) == .date(Date(timeIntervalSince1970: 1_199_145_600)))
        #expect(captured.sourceItem == .copy(copy.id), "the copy is still a local copy")
        let calibre = ImportedMetadataCapture.calibreWirelessInstance(libraryID: "lib-1")
        #expect(captured.values.allSatisfy { $0.provider == calibre && $0.sourceItem?.item == "6ba7b810-9dad-11d1-80b4-00c04fd430c8" })
    }

    @Test("Calibre's values sit beside the OPF's instead of replacing them")
    func calibreKeepsTheOPFValues() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("calibre-merge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ImportedMetadataStore(directory: directory)
        store.write(ImportedMetadataCapture.epub(
            copy: copy, sourceItem: .copy(copy.id), identifiers: [], languages: ["zh"], description: nil,
            subjects: ["小說"], publishers: [], published: nil, now: fixed
        ))
        store.write(ImportedMetadataCapture.calibre(
            metadata: ["uuid": .string("6ba7b810-9dad-11d1-80b4-00c04fd430c8"), "languages": .array([.string("zho")])],
            copy: copy, libraryID: "lib-1", now: fixed
        ))
        store.waitForPendingWritesForTesting()

        let merged = try #require(store.read(copyID: copy.id))
        #expect(Set(merged.values.filter { $0.field == .language }.map(\.value)) == [.texts(["zh"]), .texts(["zho"])])
        #expect(merged.values.contains { $0.field == .tags && $0.value == .texts(["小說"]) })
    }

    @Test("an Aozora work gives its work id, Japanese, and its classification as tags")
    func aozora() {
        let work = AozoraWork(id: "000789", title: "吾輩は猫である", yomi: "わがはいはねこである", sortYomi: "", subtitle: "",
                              kanaStyle: "新字新仮名", ndc: "NDC 913", published: "", updated: "", card: "", text: "",
                              textUpdated: "", credits: [], source: "", sourcePublisher: "")
        let sourceItem = SourceRecord.derived(from: work).key
        let captured = ImportedMetadataCapture.aozora(work: work, copy: copy, sourceItem: sourceItem, now: fixed)

        #expect(captured.identifiers == [.normalized(.aozoraWork, "000789")!])
        #expect(value(.language, in: captured) == .texts(["ja"]))
        #expect(value(.tags, in: captured) == .texts(["NDC 913", "新字新仮名"]))
        #expect(captured.sourceItem == sourceItem)
    }

    private func value(_ field: MetadataField, in metadata: ImportedMetadata) -> MetadataPayload? {
        metadata.values.first { $0.field == field }?.value
    }
}
