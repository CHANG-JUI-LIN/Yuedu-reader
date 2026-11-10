import Foundation
import Testing
@testable import yuedu_app

/// legado `bookSourceType` 4 (video) — the same value in legado-E, Sigma, MD3 and huajideshutiao.
@MainActor
@Suite("Video source type", .serialized)
struct VideoSourceTypeTests {
    private func onlineBook(source: BookSource, bookURL: String = "https://example.com/vod/1") -> OnlineBook {
        OnlineBook(
            name: "短劇", author: "", intro: "", coverUrl: "",
            bookUrl: bookURL, tocUrl: "", wordCount: "", lastChapter: "", kind: "",
            sourceId: source.id, sourceName: source.bookSourceName
        )
    }

    private func source(type: Int, content: String = "") -> BookSource {
        var source = BookSource(bookSourceUrl: "https://example.com", bookSourceName: "影視")
        source.bookSourceType = type
        source.ruleContent.content = content
        return source
    }

    @Test("a type-4 source's books are videos")
    func sourceTypeFourIsVideo() {
        let video = source(type: 4)
        #expect(onlineBook(source: video).inferredContentKind(source: video) == .video)
    }

    @Test("the source's declared type wins over a book's 小说 marker")
    func declaredTypeWinsOverTextMarker() {
        let kind = OnlineBookContentInference.infer(
            sourceType: 4, runtimeVariables: ["type": "小说"], urls: [], metadataText: []
        )
        #expect(kind == .video)
    }

    // `kind(fromTypeNumber:)` also reads URL query values, where 4 is usually a novel category.
    @Test("a 4 in a text source's URL query is not a video")
    func queryFourStaysText() {
        let text = source(type: 0)
        let book = onlineBook(source: text, bookURL: "https://example.com/book?type=4&id=9")
        #expect(book.inferredContentKind(source: text) == .text)
    }

    // UAA's TOC: a text source, `book.type = 8`, and the kind in legado's hex option.
    @Test("a video URL outranks a text book type")
    func videoURLOutranksTextBookType() {
        let kind = OnlineBookContentInference.infer(
            sourceType: 0, runtimeVariables: ["book.type": "8"],
            urls: [#"https://api.example.com/video/info?id=12,{"type":"video"}"#]
        )
        #expect(kind == .video)
    }

    @Test("an aggregate API's video path is a video")
    func videoPathIsVideo() {
        let kind = OnlineBookContentInference.infer(
            sourceType: 0, urls: ["http://example.com:8020/api/video/detail?series_id=7"]
        )
        #expect(kind == .video)
    }

    // legado's `type` option turns on a hex response; any value does, so a number names no kind.
    @Test("a number in the hex option is no kind")
    func hexOptionNumberIsNoKind() {
        let kind = OnlineBookContentInference.explicitKind(
            urls: [#"https://example.com/chapter?id=1,{"type":"1"}"#]
        )
        #expect(kind == nil)
    }

    // 光遇聚合: the detail payload's tab, under a source whose markers say 听书.
    @Test("a 短剧 tab is a video over the source's audio markers")
    func shortDramaTabIsVideo() throws {
        let payload = try JSONSerialization.data(withJSONObject: ["book_id": "1", "tab": "短剧"])
        let kind = OnlineBookContentInference.infer(
            sourceType: 0,
            urls: ["https://example.com/gydetail,data:;base64," + payload.base64EncodedString()],
            metadataText: ["听书"]
        )
        #expect(kind == .video)
    }

    private func base64JSON(_ object: [String: String]) throws -> String {
        try JSONSerialization.data(withJSONObject: object).base64EncodedString()
    }

    // The aggregate sources whose 短剧 play from a page, each as its URLs are shaped.
    @Test("大灰狼's 短剧 search result is a video")
    func dahuilangShortDrama() throws {
        let payload = try base64JSON(["book_id": "1", "sources": "番茄", "tab": "短剧", "url": ""])
        let kind = OnlineBookContentInference.infer(
            sourceType: 0, urls: ["data:;base64,\(payload),{\"type\":\"qingtian\"}"]
        )
        #expect(kind == .video)
    }

    @Test("七猫-OE's 短剧 detail URL is a video")
    func qimaoShortDrama() {
        let kind = OnlineBookContentInference.infer(
            sourceType: 0, urls: ["http://103.0.0.1:11459/api/drama/detail?playlet_id=9&api_key=k"]
        )
        #expect(kind == .video)
    }

    @Test("书山's video catalog, a data URL with a media type, is a video")
    func shushanVideoCatalog() throws {
        let payload = try base64JSON(["source": "番茄短剧", "url": "x", "name": "劇", "tab": "video"])
        let kind = OnlineBookContentInference.infer(
            sourceType: 0, urls: ["data:detailsUrl;base64,e30=", "data:catalogUrl;base64,\(payload),{\"type\":\"susan\"}"]
        )
        #expect(kind == .video)
    }

    @Test("legado-E's and the original's video book types are videos")
    func videoBookTypes() {
        for type in ["4", "2048"] {
            #expect(OnlineBookContentInference.explicitKind(runtimeVariables: ["book.type": type]) == .video)
        }
    }

    @Test("a video book keeps the video pipeline and no reader font")
    func videoPipelineResolves() {
        var book = ReadingBook(title: "短劇", author: "", contentFilename: "")
        book.isOnline = true
        book.contentPipelineKind = OnlineBookContentKind.video.pipelineKind
        #expect(book.resolvedPipelineKind == .video)
        #expect(!book.allowsUserSelectedReaderFont)
        #expect(ContentKind(book.resolvedPipelineKind) == .video)
    }

    @Test("a video book round-trips through its JSON record")
    func videoPipelineRoundTrips() throws {
        var book = ReadingBook(title: "短劇", author: "", contentFilename: "")
        book.isOnline = true
        book.contentPipelineKind = .video
        let data = try JSONEncoder().encode(book)
        let decoded = try JSONDecoder().decode(ReadingBook.self, from: data)
        #expect(decoded.contentPipelineKind == .video)
    }

    @Test("videos carry their own tag, badge and search group")
    func videoPresentation() {
        #expect(ContentKind.video.mediaTag == localized("影片"))
        #expect(ContentKind.video.coverBadgeSymbol != nil)
        #expect(ContentKind.text.mediaTag == nil)
        #expect(ContentKind.searchGroupOrder.contains(.video))
    }

    // A build before `.video` decodes the kind by inference (online → `.html`) and uploads that.
    @Test("a video record synced back as text from an older build is a video again")
    func olderBuildRecordIsVideoAgain() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("VideoSync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let video = source(type: 4)
        let text = source(type: 0)
        let previousSources = BookSourceStore.shared.sources
        BookSourceStore.shared.replaceSources([video, text])
        defer { BookSourceStore.shared.replaceSources(previousSources) }
        let store = BookStore(metadataFileURL: folder.appendingPathComponent("books_meta.json"))
        let copy = store.addOnlineBook(name: "短劇", author: "", sourceId: video.id,
                                       bookInfoURL: "https://example.com/vod/1", chapters: [])
        #expect(copy.contentPipelineKind == .video)

        var older = copy.withoutTableOfContents()
        older.contentPipelineKind = .html
        older.audioTimeSeconds = 42
        let snapshot = try #require(store.snapshotForSync([older], expectedMutationRevision: store.mutationRevision))
        #expect(store.applySyncSnapshot(try await BookStore.encodeSyncSnapshot(snapshot)))
        let applied = try #require(store.readingBook(id: copy.id))
        #expect(applied.contentPipelineKind == .video)
        #expect(applied.audioTimeSeconds == 42, "the rest of the newer record lands")

        // Switched to a text source on another device: that `.html` is the book's.
        var switched = older
        switched.bookSourceId = text.id
        let other = try #require(store.snapshotForSync([switched]))
        #expect(store.applySyncSnapshot(try await BookStore.encodeSyncSnapshot(other)))
        #expect(store.readingBook(id: copy.id)?.contentPipelineKind == .html)
        store.waitForQueuedWrites()
    }

    @Test("a media source with no content rule reads the chapter URL as the chapter")
    func emptyContentRuleReadsChapterURL() {
        #expect(source(type: 4).readsChapterURLAsContent)
        #expect(source(type: 1).readsChapterURLAsContent)
        #expect(!source(type: 4, content: "video@src").readsChapterURLAsContent)
        #expect(!source(type: 0).readsChapterURLAsContent)
    }
}
