import Foundation
import Testing
@testable import yuedu_app

/// FB-125: 網路設定 →「預讀章節數」 sets how far ahead an online book reads, and read-ahead is
/// paced per book so ten chapters ahead do not open ten connections to one site at once.
@MainActor
@Suite("Chapter prefetch window", .serialized)
struct ChapterPrefetchWindowTests {

    @Test("the forward window is as long as the setting", arguments: [2, 5, 10])
    func forwardWindowFollowsSetting(ahead: Int) {
        let window = OnlineBookCoordinator.adjacentPrefetchWindow(
            center: 10, chapterCount: 100, ahead: ahead)
        let forward = window.filter { $0.priority == .prefetch }.map(\.index)
        let backward = window.filter { $0.priority == .background }.map(\.index)
        #expect(forward == Array(11...(10 + ahead)))
        // Back-navigation keeps its two chapters whatever the forward setting.
        #expect(backward == [9, 8])
        // Nearest first: forward before backward, so the gate's queue serves N+1 first.
        #expect(window.map(\.index) == Array(11...(10 + ahead)) + [9, 8])
    }

    @Test("the window stops at the book's last chapter")
    func forwardWindowClipsAtEnd() {
        let window = OnlineBookCoordinator.adjacentPrefetchWindow(
            center: 7, chapterCount: 10, ahead: 10)
        #expect(window.map(\.index) == [8, 9, 6, 5])
    }

    @Test("the default keeps the two chapters ahead the reader always had")
    func defaultIsTwo() {
        #expect(NetworkSearchSettings.defaultChapterPrefetchCount == 2)
        #expect(NetworkSearchSettings.chapterPrefetchOptions == [2, 5, 10])
        #expect(NetworkSearchSettings.clampedChapterPrefetchCount(50) == 10)
        #expect(NetworkSearchSettings.clampedChapterPrefetchCount(0) == 1)
    }

    @Test("the reader's prefetch reads the setting")
    func readerPrefetchFollowsSetting() async {
        let settings = GlobalSettings.shared
        let saved = settings.chapterPrefetchCount
        defer { settings.chapterPrefetchCount = saved }
        settings.chapterPrefetchCount = 5

        let fetcher = MockChapterFetcher()
        var book = ReadingBook(title: "Book", author: "Author", source: "https://example.com", contentFilename: "")
        book.isOnline = true
        book.onlineChapters = (0..<20).map {
            OnlineChapterRef(index: $0, title: "Chapter \($0 + 1)", url: "https://example.com/\($0 + 1)")
        }
        for index in 0..<20 { await fetcher.setCached(chapterIndex: index) }
        let viewModel = ReaderViewModel(chapterFetcher: fetcher, bookSourceFetcher: StubBookSourceFetcher())

        await viewModel.prefetchAround(book: book, center: 3, store: nil)

        for index in [1, 2, 4, 5, 6, 7, 8] {
            #expect(viewModel.chapterStates[index] == .ready, "chapter \(index)")
        }
        #expect(viewModel.chapterStates[9] == nil)
        #expect(viewModel.chapterStates[0] == nil)
    }

    @Test("only read-ahead waits for the book's gate")
    func onlyReadAheadIsGated() {
        let bookId = UUID()
        let prefetch = ChapterFetchManager.readAheadGateKey(bookId: bookId, priority: .prefetch)
        #expect(prefetch != nil)
        #expect(ChapterFetchManager.readAheadGateKey(bookId: bookId, priority: .background) == prefetch)
        #expect(ChapterFetchManager.readAheadGateKey(bookId: UUID(), priority: .prefetch) != prefetch)
        for priority in [ChapterFetchPriority.immediate, .jump, .download] {
            #expect(ChapterFetchManager.readAheadGateKey(bookId: bookId, priority: priority) == nil)
        }
    }
}
