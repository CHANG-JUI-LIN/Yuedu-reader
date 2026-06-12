import Foundation
import Testing
@testable import yuedu_app

@Suite("Audiobook content detection")
struct AudiobookDetectionTests {
    private func dataURL(_ payload: [String: Any], type: String = "qingtian") throws -> String {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return "data:;base64,\(data.base64EncodedString()),{\"type\":\"\(type)\"}"
    }

    @Test("plain mp3 direct link is detected as audio")
    func plainMP3() {
        let content = "https://cdn.example.com/audio/ch1.mp3"
        #expect(DirectChapterAudioResolver.looksLikeAudioContent(content))
        let request = DirectChapterAudioResolver.request(from: content)
        #expect(request?.url?.absoluteString == content)
    }

    @Test("Legado url,{headers} form resolves and is detected")
    func legadoOptionsForm() {
        let content = #"https://cdn.example.com/ch1.m4a,{"headers":{"Referer":"https://example.com"}}"#
        #expect(DirectChapterAudioResolver.looksLikeAudioContent(content))
        #expect(DirectChapterAudioResolver.request(from: content)?.url != nil)
    }

    @Test("<audio> element is detected as audio")
    func audioTag() {
        let content = #"<audio controls src="https://cdn.example.com/a.aac"></audio>"#
        #expect(DirectChapterAudioResolver.looksLikeAudioContent(content))
        #expect(DirectChapterAudioResolver.request(from: content)?.url != nil)
    }

    @Test("audiobook path without a file extension is detected")
    func audiobookPath() {
        let content = "https://api.example.com/audiobook/stream?id=42"
        #expect(DirectChapterAudioResolver.looksLikeAudioContent(content))
    }

    // Real 番茄畅听 CDN link shape: no file extension, a /video/ path (!), and the
    // only audio marker is `mime_type=audio_mpeg` in the query. This is what the
    // 光遇聚合 /content endpoint returns for 听书 chapters.
    @Test("fanqie CDN link with mime_type=audio query is detected")
    func fanqieCDNAudioLink() {
        let content = "https://v5-ex-novelapp.fqnovelvod.com/1a409e5bb93d06d864bd670dc57562ef/6a2d5360/video/tos/cn/tos-cn-v-710116/056d517d10fd46d29ea6c776d33df5ab/?a=1967&ch=0&br=250&mime_type=audio_mpeg&qs=13&btag=c0000e00038000&dy_q=1781268193&l=20260612204313D39F4F9E3549091FD894\n"
        #expect(DirectChapterAudioResolver.looksLikeAudioContent(content))
        #expect(DirectChapterAudioResolver.request(from: content)?.url != nil)
    }

    @Test("prose text is not audio")
    func prose() {
        let content = "第一章 風起\n他站在山巔，望著遠方的雲海，心中百感交集。"
        #expect(!DirectChapterAudioResolver.looksLikeAudioContent(content))
        #expect(DirectChapterAudioResolver.request(from: content) == nil)
    }

    @Test("prose with a single embedded audio link stays prose")
    func proseWithOneLink() {
        let content = """
        這是一段很長的正文內容，講述了主角的冒險旅程，充滿了細節描寫與情感刻畫。
        延伸收聽：https://cdn.example.com/extra.mp3
        故事還在繼續，主角踏上了新的征途，前方充滿未知與挑戰。
        """
        #expect(!DirectChapterAudioResolver.looksLikeAudioContent(content))
    }

    @Test("manga image list is not audio")
    func mangaList() {
        let content = #"["https://cdn.example.com/1.jpg","https://cdn.example.com/2.jpg","https://cdn.example.com/3.jpg"]"#
        #expect(!DirectChapterAudioResolver.looksLikeAudioContent(content))
        #expect(DirectChapterAudioResolver.request(from: content) == nil)
    }

    // An online book tagged `.audio` (from a bookSourceType==1 source) must keep that
    // pipeline kind so BookReaderView routes it to AudiobookReaderView instead of the
    // text reader. `resolvedPipelineKind` checks `.audio` BEFORE the `isOnline → .html`
    // fallback, which is the invariant the audiobook routing relies on.
    @Test("online .audio book resolves to audiobook reader, not text reader")
    func audioPipelineResolvesToAudio() {
        var book = ReadingBook(title: "Audiobook", author: "Narrator", contentFilename: "")
        book.isOnline = true
        book.contentPipelineKind = .audio
        #expect(book.resolvedPipelineKind == .audio)
        #expect(book.allowsUserSelectedReaderFont == false)
    }

    @Test("aggregate data URL with listening tab routes as audio")
    func aggregateDataURLListeningTabRoutesAsAudio() throws {
        let url = try dataURL([
            "book_id": "b1",
            "sources": "番茄",
            "tab": "听书",
            "url": ""
        ])

        let kind = OnlineBookContentInference.infer(sourceType: 0, urls: [url])
        #expect(kind == .audio)
    }

    @Test("aggregate data URL with novel tab stays text")
    func aggregateDataURLNovelTabStaysText() throws {
        let url = try dataURL([
            "book_id": "b1",
            "sources": "番茄",
            "tab": "小说",
            "url": ""
        ])

        let kind = OnlineBookContentInference.infer(sourceType: 0, urls: [url])
        #expect(kind == .text)
    }

    @Test("runtime book type infers aggregate content kind")
    func runtimeBookTypeInfersContentKind() {
        #expect(OnlineBookContentInference.infer(
            sourceType: 0,
            runtimeVariables: ["book.type": "1"]
        ) == .audio)
        #expect(OnlineBookContentInference.infer(
            sourceType: 0,
            runtimeVariables: ["book.type": "32"]
        ) == .audio)
        #expect(OnlineBookContentInference.infer(
            sourceType: 0,
            runtimeVariables: ["book.type": "2"]
        ) == .manga)
        #expect(OnlineBookContentInference.infer(
            sourceType: 0,
            runtimeVariables: ["book.type": "64"]
        ) == .manga)
    }

    @Test("search book prefers audio origin from aggregate source")
    func searchBookPrefersAudioOrigin() throws {
        let textURL = try dataURL(["book_id": "b1", "sources": "番茄", "tab": "小说", "url": ""])
        let audioURL = try dataURL(["book_id": "b1", "sources": "番茄", "tab": "听书", "url": ""])
        let sourceId = UUID()
        let textOrigin = BookOrigin(
            sourceId: sourceId,
            sourceName: "聚合",
            bookUrl: textURL,
            tocUrl: "",
            coverUrl: "",
            intro: "",
            lastChapter: "",
            wordCount: "",
            kind: "",
            runtimeVariables: nil
        )
        let audioOrigin = BookOrigin(
            sourceId: sourceId,
            sourceName: "聚合",
            bookUrl: audioURL,
            tocUrl: "",
            coverUrl: "",
            intro: "",
            lastChapter: "",
            wordCount: "",
            kind: "",
            runtimeVariables: nil
        )
        let book = SearchBook(name: "測試書", author: "作者", origins: [textOrigin, audioOrigin])

        #expect(book.inferredContentKind() == .audio)
        #expect(book.preferredOrigin(for: .audio)?.bookUrl == audioURL)
    }

    @Test("book store creates aggregate listening result as audio")
    func bookStoreCreatesAggregateListeningResultAsAudio() throws {
        let source = BookSource(bookSourceUrl: "https://example.com", bookSourceName: "聚合")
        let previousSources = BookSourceStore.shared.sources
        BookSourceStore.shared.sources = [source]
        defer { BookSourceStore.shared.sources = previousSources }

        let metadataURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("books-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: metadataURL) }

        let store = BookStore(metadataFileURL: metadataURL)
        let bookURL = try dataURL(["book_id": "b1", "sources": "番茄", "tab": "听书", "url": ""])
        let book = store.addOnlineBook(
            name: "測試聽書",
            author: "作者",
            sourceId: source.id,
            bookInfoURL: bookURL,
            tocURL: nil,
            runtimeVariables: nil,
            chapters: []
        )

        #expect(book.contentPipelineKind == .audio)
        #expect(book.resolvedPipelineKind == .audio)
    }

    @Test("updating aggregate audiobook chapters refreshes runtime state")
    func updatingAggregateAudiobookChaptersRefreshesRuntimeState() throws {
        let source = BookSource(bookSourceUrl: "https://example.com", bookSourceName: "聚合")
        let previousSources = BookSourceStore.shared.sources
        BookSourceStore.shared.sources = [source]
        defer { BookSourceStore.shared.sources = previousSources }

        let metadataURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("books-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: metadataURL) }

        let store = BookStore(metadataFileURL: metadataURL)
        let bookURL = try dataURL(["book_id": "b1", "sources": "番茄", "tab": "听书", "url": ""])
        let book = store.addOnlineBook(
            name: "測試聽書",
            author: "作者",
            sourceId: source.id,
            bookInfoURL: bookURL,
            runtimeVariables: ["book.type": "1"],
            contentKind: .audio,
            chapters: []
        )
        let chapters = [
            OnlineChapterRef(index: 0, title: "第1章", url: "https://example.com/chapter/1")
        ]

        store.updateOnlineChapters(
            bookId: book.id,
            chapters: chapters,
            runtimeVariables: ["book.type": "1", "book_id": "b1", "tab": "听书"]
        )

        let updated = try #require(store.books.first(where: { $0.id == book.id }))
        #expect(updated.onlineChapters?.count == 1)
        #expect(updated.runtimeVariables?["book_id"] == "b1")
        #expect(updated.runtimeVariables?["tab"] == "听书")
    }
}
