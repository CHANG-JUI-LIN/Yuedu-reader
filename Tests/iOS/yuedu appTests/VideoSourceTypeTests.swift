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

    @Test("validation prefers a video result for a video source")
    func validationPrefersVideo() {
        let video = source(type: 4)
        var audioResult = onlineBook(source: video, bookURL: "https://example.com/a?type=1")
        audioResult.runtimeVariables = ["type": "听书"]
        let plain = onlineBook(source: video, bookURL: "https://example.com/v")
        let chosen = OnlineBookValidationSelector.preferredBook(from: [audioResult, plain], for: video)
        #expect(chosen?.bookUrl == plain.bookUrl)
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
