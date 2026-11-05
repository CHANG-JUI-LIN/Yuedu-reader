import Combine
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import yuedu_app

/// 漫畫閱讀器讀著讀著存進度，不能讓書庫發布變更。
///
/// 回饋 #133（iOS 27.2、線上漫畫、條漫）：捲動時大約每秒一次 67–150 ms 沒有新幀。每停在一頁
/// 0.8 秒，閱讀器就存一次位置；`updateMangaPosition` 一律發 `objectWillChange`，閱讀器底下的
/// 書架（`ContentView`、`HomeView` 都掛著 `@EnvironmentObject store`）和閱讀器自己的 SwiftUI
/// 外殼整個重算一次——`ShelfRerenderBudgetTests` 記下的就是這條路。文字閱讀器早就改成捲動中
/// 安靜寫入、離開時才發布；漫畫閱讀器（分頁和條漫共用這段存檔）一直沒有跟上。
@Suite("Fixed page position save", .serialized)
@MainActor
struct FixedPagePositionSaveTests {

    @Test("reading page after page saves each position without publishing the library; leaving publishes it once")
    func readingDoesNotPublishTheLibrary() async throws {
        let harness = try await Harness()
        defer { harness.tearDown() }

        for page in 1...3 {
            try await harness.read(page: page)
        }
        #expect(harness.publishes == 0, "a position saved while reading rebuilt the shelf behind the reader")
        #expect(harness.store.books.first { $0.id == harness.bookID }?.mangaPage == 3)

        harness.leave()
        #expect(harness.publishes == 1, "leaving the reader shows the shelf where the reader is")
        #expect(harness.store.books.first { $0.id == harness.bookID }?.mangaPage == 3)
    }

    /// The main thread's own time for each page read, with the real `HomeView` and 300 books
    /// mounted behind the reader: what one position save costs while the strip moves.
    /// Opt-in (`TEST_RUNNER_SHELF_RENDER_SCALE_TESTS=1`), like `ShelfRenderScaleTests`; the
    /// numbers are the evidence, not assertions.
    @Test(
        "reading pages with a 300-book shelf mounted",
        .enabled(if: ShelfScale.enabled, "Set SHELF_RENDER_SCALE_TESTS=1")
    )
    func readingCostWithShelfMounted() async throws {
        let harness = try await Harness(shelfBooks: 300)
        defer { harness.tearDown() }
        let pages = 6

        var readCPU: [Double] = []
        for page in 1...pages {
            let start = SourcePerfTrace.threadCPU
            try await harness.read(page: page)
            harness.settle()
            readCPU.append((SourcePerfTrace.threadCPU - start) * 1000)
        }
        // The same wait with nothing read: what the test host's main thread spends anyway.
        var idleCPU: [Double] = []
        for _ in 0..<3 {
            let start = SourcePerfTrace.threadCPU
            try await Task.sleep(for: .milliseconds(900))
            harness.settle()
            idleCPU.append((SourcePerfTrace.threadCPU - start) * 1000)
        }
        let perPage = readCPU.reduce(0, +) / Double(readCPU.count)
        let idle = idleCPU.reduce(0, +) / Double(idleCPU.count)
        print(
            "SCALE webtoonPageRead books=300 pages=\(pages) publishes=\(harness.publishes) "
                + "perPageCpuMs=\(String(format: "%.1f", perPage)) idleCpuMs=\(String(format: "%.1f", idle)) "
                + "pages=[\(readCPU.map { String(format: "%.1f", $0) }.joined(separator: ","))]"
        )
    }

    private enum ShelfScale {
        nonisolated static let enabled: Bool = {
            let env = ProcessInfo.processInfo.environment
            return (env["SHELF_RENDER_SCALE_TESTS"] ?? env["TEST_RUNNER_SHELF_RENDER_SCALE_TESTS"]) == "1"
        }()
    }

    /// An online manga on the shelf (with `shelfBooks` others, and the real `HomeView` mounted
    /// when there are any), open in the fixed-page reader, and a count of the store's publishes
    /// from the moment its first chapter is on screen.
    @MainActor
    private final class Harness {
        static let pagesPerChapter = 8

        let directory: URL
        let store: BookStore
        let bookID: UUID
        let reader: FixedPageReaderViewController
        private let window: UIWindow
        private let shelf: WindowHost?
        private var cancellable: AnyCancellable?
        private(set) var publishes = 0

        init(shelfBooks: Int = 0) async throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("FixedPagePositionSaveTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            store = BookStore(metadataFileURL: directory.appendingPathComponent("books_meta.json"))

            var book = ReadingBook(title: "Manga", author: "", contentFilename: "")
            book.isOnline = true
            book.onlineChapters = (0..<3).map {
                OnlineChapterRef(index: $0, title: "Chapter \($0 + 1)", url: "https://example.invalid/chapter/\($0)")
            }
            bookID = book.id
            let others: [ReadingBook] = (0..<shelfBooks).map { index in
                var other = ReadingBook(title: "書名 \(index)", author: "作者 \(index % 23)", contentFilename: "")
                other.group = index % 3 == 0 ? "分組 \(index % 10)" : ""
                other.isOnline = true
                other.totalChapterNum = 1_000
                other.latestChapterTitle = "第\(index)章"
                return other
            }
            store.replaceBooksFromSync([book] + others)
            store.waitForQueuedWrites()
            shelf = shelfBooks > 0 ? try WindowHost(HomeView().environmentObject(store)) : nil
            shelf?.pump(seconds: 0.5)

            let fetcher = MockChapterFetcher()
            for chapter in 0..<3 {
                for _ in 0..<12 {
                    await fetcher.enqueuePackage(chapterIndex: chapter, package: Self.package(of: book, chapter: chapter))
                }
            }
            // The strip, as 回饋 #133 reads it.
            store.readerSettings.setFixedPageConfiguration(.recommendedDefault(for: .webtoon), for: book.id)
            let state = FixedPageReaderState()
            reader = FixedPageReaderViewController(book: book, store: store, state: state, chapterFetcher: fetcher)
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
            window.rootViewController = reader
            window.makeKeyAndVisible()

            let deadline = ContinuousClock.now + .seconds(5)
            while state.totalPages != Self.pagesPerChapter, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(state.totalPages == Self.pagesPerChapter, "the first chapter never opened")

            cancellable = store.objectWillChange.sink { [weak self] _ in
                MainActor.assumeIsolated { self?.publishes += 1 }
            }
        }

        /// The strip scrolls to `page` of the first chapter and stays there until its position
        /// is saved.
        func read(page: Int) async throws {
            let strip = try #require(reader.reader as? FixedPageWebtoonViewController)
            strip.goToPage(page, animated: false)
            try #require(strip.currentPageIndex() == page)
            let deadline = ContinuousClock.now + .seconds(3)
            while store.books.first(where: { $0.id == bookID })?.mangaPage != page, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(store.books.first { $0.id == bookID }?.mangaPage == page, "page \(page) was never saved")
        }

        /// One run-loop turn plus layout of the shelf: SwiftUI's update for what was published.
        func settle() {
            RunLoop.main.run(until: Date())
            shelf?.controller.view.layoutIfNeeded()
        }

        /// The reader goes away, as a pop or a dismiss takes it.
        func leave() {
            reader.beginAppearanceTransition(false, animated: false)
            reader.endAppearanceTransition()
        }

        func tearDown() {
            cancellable = nil
            window.isHidden = true
            window.rootViewController = nil
            shelf?.tearDown()
            store.waitForQueuedWrites()
            try? FileManager.default.removeItem(at: directory)
        }

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
}
