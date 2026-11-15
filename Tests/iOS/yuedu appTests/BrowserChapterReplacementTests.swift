@testable import YueduCoreText
import Testing
import UIKit
@testable import yuedu_app

/// A browser chapter whose content changes while its layout is still running (a module's
/// comments arrive for a chapter being laid out): the chapter is laid out again from the new
/// content. The running layout's pages used to come back as the answer.
@MainActor
@Suite("A browser chapter replaced mid-layout")
struct BrowserChapterReplacementTests {
    /// Reads the chapter as it is now, then holds the chapter's CSS until `release()`: the
    /// layout that read the old HTML is in flight while the test changes it.
    @MainActor
    private final class HeldAfterReadResource: BrowserLayoutResourceProviding {
        let base: MockBrowserLayoutResource
        private var isHolding = true
        private var readers: [CheckedContinuation<Void, Never>] = []
        private(set) var heldReaders = 0
        init(_ base: MockBrowserLayoutResource) { self.base = base }
        func release() {
            isHolding = false
            let waiting = readers
            readers.removeAll()
            waiting.forEach { $0.resume() }
        }
        var chapterCount: Int { base.chapterCount }
        func chapterTitle(at index: Int) -> String { base.chapterTitle(at: index) }
        func chapterSourceHref(at index: Int) -> String? { base.chapterSourceHref(at: index) }
        func chapterHTML(at index: Int) async throws -> String { try await base.chapterHTML(at: index) }
        func cssFrontendInput(forChapter index: Int, html: String) async -> CSSFrontendInput {
            if isHolding {
                heldReaders += 1
                await withCheckedContinuation { readers.append($0) }
            }
            return await base.cssFrontendInput(forChapter: index, html: html)
        }
        func prepareFonts(requests: Set<BrowserFontRequest>) async {}
        func prefetchImages(forChapter index: Int, html: String, renderWidth: CGFloat) async -> [String: UIImage] { [:] }
        func loadImage(forChapter index: Int, source: String, renderWidth: CGFloat) async -> UIImage? { nil }
        func fontResolver() -> BrowserFontResolver? { nil }
    }

    private func settings() -> ReaderRenderSettings {
        ReaderRenderSettings(
            theme: "paper", textColor: .black, backgroundColor: .white, fontSize: 17, lineHeightMultiple: 1.4,
            lineSpacing: 0, paragraphSpacing: 6, letterSpacing: 0, marginH: 12, marginV: 12, footerHeight: 24,
            contentInsets: UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12))
    }

    private func chapter(_ text: String) -> MockBrowserLayoutResource.Chapter {
        .init(title: "Chapter 0", href: "chapter0.xhtml", html: "<html><body><p>\(text)</p></body></html>", css: [])
    }

    @Test("content that changes while the chapter is being laid out is what the chapter shows")
    func replacedMidLayout() async throws {
        let base = MockBrowserLayoutResource(chapters: [chapter("OLD content of the chapter.")])
        let resource = HeldAfterReadResource(base)
        let store = CharOffsetStore(directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent("bl-replace-\(UUID().uuidString)"))
        let delegate = CoreTextPageEngine(attributedBuilder: MockAttributedStringBuilder(texts: ["Chapter 0"]),
                                          renderSettings: settings(), offsetStore: store)
        let engine = BrowserLayoutPageEngine(resource: resource, delegate: delegate, settings: settings(), mode: .browserAuto)
        let starting = Task { await engine.start(renderSize: CGSize(width: 300, height: 400), bookId: "test") }
        for _ in 0..<2_000 where resource.heldReaders == 0 { await Task.yield() }
        #expect(resource.heldReaders > 0, "the first layout read the old chapter and is in flight")

        base.chapters[0] = chapter("NEW content of the chapter.")
        let replacing = Task { await engine.notifyChapterDataChanged(at: 0) }
        for _ in 0..<50 { await Task.yield() }
        resource.release()
        await starting.value
        await replacing.value

        let text = try #require(engine.chapterText(forSpine: 0))
        #expect(text.contains("NEW") && !text.contains("OLD"), "the chapter shows \(text)")
        #expect(engine.totalPages >= 1)
        let vc = try #require(engine.pageViewController(at: 0) as? BrowserLayoutPageViewController)
        let drawn = vc.pageView.displayList.items.compactMap { item -> String? in
            if case .text(let text) = item { return text.text }
            return nil
        }.joined()
        #expect(drawn.contains("NEW") && !drawn.contains("OLD"), "the page draws \(drawn)")
    }
}
