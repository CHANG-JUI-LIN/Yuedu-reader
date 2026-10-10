import Foundation
import SwiftUI
import Testing
import UIKit
@testable import yuedu_app

/// Scale probes for the bookshelf as the field's heavy users have it: 300 books in 10
/// groups, grid, sorted by title. They mount the real `HomeView` and measure the main
/// thread's time for what happens constantly while the app is open. Opt-in:
///
///     TEST_RUNNER_SHELF_RENDER_SCALE_TESTS=1
///
/// Each probe prints one `SCALE …` line; the numbers are the evidence, not assertions.
@Suite(.serialized)
@MainActor
struct ShelfRenderScaleTests {
    nonisolated private static let enabled: Bool = {
        let env = ProcessInfo.processInfo.environment
        return (env["SHELF_RENDER_SCALE_TESTS"] ?? env["TEST_RUNNER_SHELF_RENDER_SCALE_TESTS"]) == "1"
    }()

    private final class Fixture {
        let directory: URL
        let store: BookStore
        let host: WindowHost
        private let previousSort: Any?
        private let previousGrid: Any?

        @MainActor
        init(books count: Int) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ShelfRenderScale-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            store = BookStore(metadataFileURL: directory.appendingPathComponent("books_meta.json"))
            let books: [ReadingBook] = (0..<count).map { index in
                var book = ReadingBook(
                    title: "書名 \(String(UnicodeScalar(0x4E00 + (index * 37) % 2000)!)) \(index)",
                    author: "作者 \(index % 23)", contentFilename: ""
                )
                book.group = index % 3 == 0 ? "分組 \(index % 10)" : ""
                book.isOnline = true
                book.totalChapterNum = 1_000
                book.latestChapterTitle = "第\(index)章"
                return book
            }
            store.replaceBooksFromSync(books)
            store.waitForQueuedWrites()
            let defaults = UserDefaults.standard
            previousSort = defaults.object(forKey: "bookSortOrder")
            previousGrid = defaults.object(forKey: "bookLayoutIsGrid")
            defaults.set(BookSortOrder.title.rawValue, forKey: "bookSortOrder")
            defaults.set(true, forKey: "bookLayoutIsGrid")
            host = try WindowHost(HomeView().environmentObject(store))
            host.pump(seconds: 0.5)
        }

        @MainActor
        func tearDown() {
            host.tearDown()
            let defaults = UserDefaults.standard
            defaults.set(previousSort, forKey: "bookSortOrder")
            defaults.set(previousGrid, forKey: "bookLayoutIsGrid")
            store.waitForQueuedWrites()
            try? FileManager.default.removeItem(at: directory)
        }

        /// One run-loop turn plus layout: what the main thread does for one change.
        @MainActor
        func settle() {
            RunLoop.main.run(until: Date())
            host.controller.view.layoutIfNeeded()
        }
    }

    /// `SHELF_RENDER_SCALE_ROUNDS` lengthens every probe, for sampling it with `sample`.
    private static let rounds: Int = {
        let env = ProcessInfo.processInfo.environment
        return Int(env["SHELF_RENDER_SCALE_ROUNDS"] ?? env["TEST_RUNNER_SHELF_RENDER_SCALE_ROUNDS"] ?? "") ?? 30
    }()

    private func measureMs(_ body: () -> Void) -> Int {
        let startedAt = ProcessInfo.processInfo.systemUptime
        body()
        return Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
    }

    @Test("store publishes with a 300-book shelf", .enabled(if: enabled, "Set SHELF_RENDER_SCALE_TESTS=1"))
    func storePublishes() throws {
        let fixture = try Fixture(books: 300)
        defer { fixture.tearDown() }
        let ids = fixture.store.books.map(\.id)
        let ms = measureMs {
            for round in 0..<Self.rounds {
                fixture.store.updatePosition(bookId: ids[round % ids.count], position: Double(round + 1) / 10_000)
                fixture.settle()
            }
        }
        print("SCALE shelfPublish books=300 publishes=\(Self.rounds) totalMs=\(ms) perPublishMs=\(String(format: "%.1f", Double(ms) / Double(Self.rounds)))")
    }

    @Test("a reader setting dragged with the shelf mounted", .enabled(if: enabled, "Set SHELF_RENDER_SCALE_TESTS=1"))
    func settingTicks() throws {
        let fixture = try Fixture(books: 300)
        defer { fixture.tearDown() }
        let settings = GlobalSettings.shared
        let previous = settings.readerBrightness
        defer { settings.readerBrightness = previous }
        let ms = measureMs {
            for tick in 0..<Self.rounds {
                settings.readerBrightness = 0.3 + Double(tick % 60) / 100
                fixture.settle()
            }
        }
        print("SCALE settingTick books=300 ticks=\(Self.rounds) totalMs=\(ms) perTickMs=\(String(format: "%.1f", Double(ms) / Double(Self.rounds)))")
    }

    @Test("scrolling the 300-book grid", .enabled(if: enabled, "Set SHELF_RENDER_SCALE_TESTS=1"))
    func scrolling() throws {
        let fixture = try Fixture(books: 300)
        defer { fixture.tearDown() }
        let scrollView = try #require(Self.verticalScrollView(in: fixture.host.controller.view))
        let frames = 120
        let ms = measureMs {
            for frame in 0..<frames {
                scrollView.contentOffset.y = CGFloat(frame) * 12
                fixture.settle()
            }
        }
        print("SCALE shelfScroll books=300 frames=\(frames) totalMs=\(ms) perFrameMs=\(String(format: "%.2f", Double(ms) / Double(frames)))")
    }

    private static func verticalScrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height * 2 { return scroll }
        for subview in view.subviews {
            if let found = verticalScrollView(in: subview) { return found }
        }
        return nil
    }
}
