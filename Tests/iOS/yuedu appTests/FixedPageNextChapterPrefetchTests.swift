import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// 讀到一章最後四分之一時，每翻一頁都會去預抓下一章的前幾張圖。原本每翻一頁就重抓一次下一章、
/// 在主執行緒重新解析它的 HTML，還取消上一次（FB-114）；一章只需要問一次。
@Suite("Fixed page next chapter prefetch", .serialized)
@MainActor
struct FixedPageNextChapterPrefetchTests {

    @Test("turning pages in a chapter's last quarter asks for the next chapter once")
    func nextChapterIsPrefetchedOnce() async throws {
        let fetcher = MockChapterFetcher()
        var book = ReadingBook(title: "Manga", author: "", contentFilename: "")
        book.isOnline = true
        book.onlineChapters = (0..<3).map {
            OnlineChapterRef(index: $0, title: "Chapter \($0 + 1)", url: "https://example.invalid/chapter/\($0)")
        }
        for chapter in 0..<3 {
            for _ in 0..<12 {
                await fetcher.enqueuePackage(chapterIndex: chapter, package: Self.package(of: book, chapter: chapter))
            }
        }
        let metadata = FileManager.default.temporaryDirectory
            .appendingPathComponent("next-chapter-prefetch-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: metadata) }
        let state = FixedPageReaderState()
        let reader = FixedPageReaderViewController(
            book: book, store: BookStore(metadataFileURL: metadata),
            state: state, chapterFetcher: fetcher)

        let scene = try #require(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        window.rootViewController = reader
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }

        let deadline = ContinuousClock.now + .seconds(5)
        while state.totalPages != Self.pagesPerChapter, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(state.totalPages == Self.pagesPerChapter, "the first chapter never opened")

        // Back and forth over the chapter's last quarter (pages 6 and 7 of 8).
        for turn in 0..<8 {
            reader.reader(didMoveToPage: 6 + turn % 2, total: Self.pagesPerChapter)
            await Task.yield()
        }
        // The asks run in tasks of their own; give each one the time to reach the fetcher.
        try await Task.sleep(for: .milliseconds(300))

        // One from opening the book (the chapters around it), one for its first images.
        let prefetches = await fetcher.priorities(for: 1).filter { $0 == .prefetch }.count
        #expect(prefetches == 2)
    }

    private static let pagesPerChapter = 8

    private static func package(of book: ReadingBook, chapter: Int) -> ChapterPackage {
        let content = (0..<pagesPerChapter)
            .map { #"<img src="https://example.invalid/c\#(chapter)/p\#($0).jpg">"# }
            .joined(separator: "\n")
        return ChapterPackage(
            bookId: book.id,
            chapterIndex: chapter,
            sourceURL: nil,
            tocTitle: nil,
            canonicalTitle: nil,
            content: content,
            contentChecksum: "",
            rawHTMLFilename: nil,
            normalizedHTMLFilename: nil,
            savedAt: Date(),
            state: .cached,
            failureReason: nil
        )
    }
}
