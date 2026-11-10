import Foundation
import Testing
@testable import yuedu_app

@Suite("Chapter content validation", .serialized)
struct ChapterContentValidationTests {
    @Test("error-page signatures are still rejected", arguments: [
        "应用程序中的服务器错误 运行时错误",
        "應用程式中的伺服器錯誤 運行時錯誤",
        "Server Error in '/' Application. Runtime Error",
        "server error in / application web.config",
        "如遇到章节错误 关闭浏览器的阅读/畅读/小说模式 关闭广告屏蔽过滤功能",
        "如遇到章节错误 關閉瀏覽器的閱讀/暢讀/小說模式 關閉廣告屏蔽過濾功能",
        "Checking your browser before accessing",
        "Verify you are human",
        "cf-browser-verification",
        "Attention Required cf-ray",
        "Cloudflare 人机验证",
        "Cloudflare 人機驗證",
        "Cloudflare Check Your Browser",
        "Cloudflare DDOS",
        "访问异常 请验证",
        "訪問異常 請驗證",
    ])
    func rejectedSignatures(_ signature: String) {
        #expect(ChapterFetcher.shared.isRejectedChapterContent(signature))
        // Do not make validation cheaper by only looking at a short prefix.
        let lateSignature = String(repeating: "正常故事中的人物繼續往前走。\n", count: 1000) + signature
        #expect(ChapterFetcher.shared.isRejectedChapterContent(lateSignature))
    }

    @Test("prose mentioning only part of a signature stays readable", arguments: [
        "他介紹了 Cloudflare 的工作原理。",
        "Attention required: the train is arriving.",
        "web.config 是這一章討論的設定檔。",
        "故事裡出現人機驗證，人物仍然往前走。",
        "如遇到章节错误，可以向作者反映。",
        "關閉廣告屏蔽過濾功能，是人物看到的一句提示。",
    ])
    func validProse(_ content: String) {
        #expect(!ChapterFetcher.shared.isRejectedChapterContent(content))
    }

    /// Legado keeps any chapter text that is not blank (`BookContent.getContent`): a volume's
    /// opening page that holds only its name is a chapter like any other.
    @Test("text that is only the chapter's title is kept")
    func titleOnlyKept() async {
        #expect(!ChapterFetcher.shared.isRejectedChapterContent("\n 第 一章\u{3000}ABC \t"))
        #expect(!ChapterFetcher.shared.isRejectedChapterContent("正文"))
        let resolved = await ChapterFetcher.shared.resolveContent(parsed: ChapterParsePayload(
            content: "<section id=\"nr\"><h2>正文</h2><br /></section>", title: "正文", sourceMatched: true, isPay: false
        ))
        #expect(resolved == "正文")
    }

    @Test("cached prose validation benchmark preserves the full read policy")
    func offlineValidationBenchmark() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let roots = OfflineStorageRoots(textRoot: root.appendingPathComponent("text"), mangaRoot: root.appendingPathComponent("manga"))
        let repository = ChapterCacheRepository(rootDirectory: roots.textRoot)
        let bookID = UUID()
        let content = String(repeating: "夕陽照著遠方的山，旅人沿著溪流走回村莊。他想起朋友說過的話，又翻開手中的書。\n", count: 256)
        let url = "https://example.com/chapter/0"
        try repository.saveToCache(content: content, bookId: bookID, chapterIndex: 0, sourceURL: url, tocTitle: "旅程")
        let store = OfflineChapterStore(roots: roots)
        let start = SourcePerfTrace.now
        var completed = 0
        for _ in 0..<128 {
            let state = await store.validationState(bookId: bookID, chapterIndex: 0, expectedSourceURL: url, expectedTOCTitle: "旅程", requiresManga: false, hasBookSource: true)
            if state == .complete { completed += 1 }
        }
        let milliseconds = (SourcePerfTrace.now - start) * 1000
        SourcePerfTrace.record("offline.validation.benchmark", "chapters=128 bytes=\(content.utf8.count)", since: start, thresholdMs: 0)
        print("OFFLINE_VALIDATION_BENCHMARK chapters=128 bytes=\(content.utf8.count) ms=\(milliseconds)")
        #expect(completed == 128)
    }
}
