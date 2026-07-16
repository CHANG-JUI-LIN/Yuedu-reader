import Foundation
import Testing
@testable import yuedu_app

@Suite("大灰狼聚合音频檢測")
struct DahuilangAudioTests {

    // MARK: - data URI 解析行為

    @Test("data URI with type qingtian3 is correctly parsed")
    func dataURIQingtian3Parsed() throws {
        let payload = #"{"book_id":"7088580281963187214","item_id":"7088926490901122078","sources":"番茄","tab":"听书","url":""}"#
        let b64 = payload.data(using: .utf8)!.base64EncodedString()
        let ruleUrl = "data:;base64,\(b64),{\"type\":\"qingtian3\"}"
        let au = AnalyzeUrl(ruleUrl: ruleUrl)
        #expect(au.isDataUri)
        #expect(au.type == "qingtian3")

        let decoded = try #require(au.decodeDataUri())
        #expect(decoded.mimeType == "")
        let roundtrip = String(data: decoded.data, encoding: .utf8)
        #expect(roundtrip == payload)
    }

    @Test("data URI qingtian3 hex roundtrip via JS engine")
    func dataURIHexRoundtrip() {
        // bodyForDataURI with type=qingtian3 returns hex-encoded.
        // The content JS then hexDecodeToString + JSON.parse.
        let payload = #"{"book_id":"7088580281963187214","item_id":"7088926490901122078","sources":"番茄","tab":"听书","url":""}"#
        let hex = payload.data(using: .utf8)!.map { String(format: "%02x", $0) }.joined()

        let engine = JSCoreEngine()
        let decoded = engine.evaluate("""
        (function(){
            var r = String(java.hexDecodeToString('\(hex)'));
            var o = JSON.parse(r);
            return o.sources + '|' + o.tab;
        })()
        """) ?? ""
        #expect(decoded == "番茄|听书")
    }

    @Test("data URI without type is parsed as UTF-8")
    func dataURINoTypeUTF8() throws {
        let payload = #"{"book_id":"b1"}"#
        let b64 = payload.data(using: .utf8)!.base64EncodedString()
        let ruleUrl = "data:;base64,\(b64)"
        let au = AnalyzeUrl(ruleUrl: ruleUrl)
        #expect(au.type == nil)

        let decoded = try #require(au.decodeDataUri())
        let body = String(data: decoded.data, encoding: .utf8)
        #expect(body == payload)
    }

    // MARK: - 推斷鏈：data URL → OnlineBookContentKind.audio

    @Test("大灰狼 data URL with tab=听书 infers as audio")
    func dahuilangDataURLInfersAudio() throws {
        let payload: [String: Any] = [
            "book_id": "7088580281963187214",
            "sources": "番茄",
            "tab": "听书",
            "url": ""
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let b64 = data.base64EncodedString()
        let url = "data:;base64,\(b64),{\"type\":\"qingtian\"}"

        let kind = OnlineBookContentInference.infer(sourceType: 0, urls: [url])
        #expect(kind == .audio)
    }

    @Test("大灰狼 runtimeVariables with book.type=1 infers audio")
    func dahuilangRuntimeVarsInfersAudio() {
        let kind = OnlineBookContentInference.infer(
            sourceType: 0,
            runtimeVariables: ["book.type": "1", "tab": "听书", "sources": "番茄"]
        )
        #expect(kind == .audio)
    }

    // MARK: - BookStore 建立與升級

    @Test("addOnlineBook with 听书 data URL sets pipeline to audio")
    func addOnlineBookSetsAudioPipeline() throws {
        let source = BookSource(bookSourceUrl: "https://example.com", bookSourceName: "大灰狼聚合")
        let previousSources = BookSourceStore.shared.sources
        BookSourceStore.shared.sources = [source]
        defer { BookSourceStore.shared.sources = previousSources }

        let metadataURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("books-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: metadataURL) }

        let store = BookStore(metadataFileURL: metadataURL)
        let payload: [String: Any] = [
            "book_id": "7088580281963187214",
            "sources": "番茄",
            "tab": "听书",
            "url": ""
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let b64 = data.base64EncodedString()
        let bookURL = "data:;base64,\(b64),{\"type\":\"qingtian\"}"
        let book = store.addOnlineBook(
            name: "大圣归来",
            author: "天命蜉蝣",
            sourceId: source.id,
            bookInfoURL: bookURL,
            tocURL: nil,
            runtimeVariables: nil,
            chapters: []
        )

        #expect(book.contentPipelineKind == .audio)
        #expect(book.resolvedPipelineKind == .audio)
    }

    @Test("upgradeToAudioIfDetected promotes html book on audio content")
    func upgradeToAudioIfDetectedPromotes() throws {
        let metadataURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("books-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: metadataURL) }
        let store = BookStore(metadataFileURL: metadataURL)

        let book = store.addOnlineBook(
            name: "大圣归来",
            author: "天命蜉蝣",
            sourceId: UUID(),
            bookInfoURL: "https://example.com/book",
            contentKind: .text,
            chapters: []
        )

        let audioURL = "https://v5-ex-novelapp.fqnovelvod.com/a?mime_type=audio_mpeg\n"
        let promoted = store.upgradeToAudioIfDetected(bookId: book.id, content: audioURL)
        #expect(promoted)

        let updated = try #require(store.books.first(where: { $0.id == book.id }))
        #expect(updated.contentPipelineKind == .audio)
    }

    @Test("upgradeToAudioIfDetected does not promote prose content")
    func upgradeToAudioIfDetectedRejectsProse() throws {
        let metadataURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("books-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: metadataURL) }
        let store = BookStore(metadataFileURL: metadataURL)

        let book = store.addOnlineBook(
            name: "大圣归来",
            author: "天命蜉蝣",
            sourceId: UUID(),
            bookInfoURL: "https://example.com/book",
            contentKind: .text,
            chapters: []
        )

        let prose = "第一章 江流儿\n长安城外的山道上，一个少年快步前行。"
        let promoted = store.upgradeToAudioIfDetected(bookId: book.id, content: prose)
        #expect(!promoted)
    }

    // MARK: - DirectChapterAudioResolver 邊緣案例

    @Test("fanqie CDN URL with trailing newline is audio")
    func fanqieCDNURLWithNewline() {
        let content = "https://v5-ex-novelapp.fqnovelvod.com/1a409e5bb93d06d864bd670dc57562ef/6a2d5360/video/tos/cn/tos-cn-v-710116/056d517d10fd46d29ea6c776d33df5ab/?a=1967&ch=0&br=250&mime_type=audio_mpeg&qs=13&btag=c0000e00038000&dy_q=1781268193&l=20260612204313D39F4F9E3549091FD894\n"
        #expect(DirectChapterAudioResolver.looksLikeAudioContent(content))
        let req = DirectChapterAudioResolver.request(from: content)
        #expect(req?.url != nil)
    }

    @Test("audio URL with Legado headers form is detected")
    func audioURLWithLegadoHeaders() {
        let content = #"https://cdn.example.com/ch1.mp3,{"headers":{"Referer":"https://fanqienovel.com"}}"#
        #expect(DirectChapterAudioResolver.looksLikeAudioContent(content))
        #expect(DirectChapterAudioResolver.request(from: content)?.url != nil)
    }

    @Test("json-wrapped audio URL is not detected as prose")
    func jsonWrappedAudioURL() {
        let content = #"{"code":0,"data":{"audio_url":"https://cdn.example.com/a.mp3","duration":1800}}"#
        // The resolver should find the URL via urlLikeMatches even in JSON
        #expect(DirectChapterAudioResolver.looksLikeAudioContent(content))
        #expect(DirectChapterAudioResolver.request(from: content)?.url != nil)
    }

    @Test("absolute silence or empty is not audio")
    func emptyContentNotAudio() {
        #expect(!DirectChapterAudioResolver.looksLikeAudioContent(""))
        #expect(!DirectChapterAudioResolver.looksLikeAudioContent("  "))
        #expect(!DirectChapterAudioResolver.looksLikeAudioContent("\n\n"))
    }

    @Test("server error HTML is not audio")
    func serverErrorHTMLNotAudio() {
        let html = "<!DOCTYPE html><html><body><h1>503 Service Unavailable</h1></body></html>"
        #expect(!DirectChapterAudioResolver.looksLikeAudioContent(html))
        #expect(DirectChapterAudioResolver.request(from: html) == nil)
    }

    @Test("multiple URLs with one audio link is detected")
    func multipleURLsOneAudio() {
        let content = """
        https://cdn.example.com/cover.jpg
        https://cdn.example.com/chapter1.mp3
        https://cdn.example.com/data.json
        """
        #expect(DirectChapterAudioResolver.looksLikeAudioContent(content))
        let req = DirectChapterAudioResolver.request(from: content)
        #expect(req?.url?.absoluteString.contains("chapter1.mp3") ?? false)
    }

    // MARK: - 錯誤訊息

    @Test("missing audio error includes content length and preview")
    func missingAudioErrorIncludesContentPreview() {
        // The error is thrown by OnlineChapterAudioProvider.audio() when
        // DirectChapterAudioResolver.request(from:) returns nil. The assoc
        // values are logged in ReaderTelemetry, not displayed to the user.
        let error = ChapterAudioProviderError.missingAudio(
            contentLength: 42,
            preview: "第一章 江流儿"
        )
        // errorDescription is a localized static string — assoc values are
        // for telemetry only. Verify the error is at least LocalizedError.
        #expect(error.errorDescription != nil)
        if case .missingAudio(let len, let prev) = error {
            #expect(len == 42)
            #expect(prev == "第一章 江流儿")
        } else {
            Issue.record("expected missingAudio case")
        }
    }

    @Test("inference order: sourceType > runtimeVars > urls > metadata")
    func inferenceOrder() {
        // sourceType=1 (.audio) should win over text in runtime/URL
        let kind = OnlineBookContentInference.infer(
            sourceType: 1,
            runtimeVariables: ["book.type": "2"],
            urls: ["https://example.com/novel"],
            metadataText: ["当前模式：小说"]
        )
        #expect(kind == .audio)
    }

    @Test("runtime variables with book.type=1 overrides text URL")
    func runtimeVarsOverrideURL() {
        let kind = OnlineBookContentInference.infer(
            sourceType: 0,
            runtimeVariables: ["book.type": "1"],
            urls: ["https://example.com/detail?book=123"],
            metadataText: []
        )
        #expect(kind == .audio)
    }
}
