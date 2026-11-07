import Foundation
import UIKit
import Testing
@testable import yuedu_app

struct FixedPageWebtoonAutoScrollTests {
    @Test("auto-scroll covers the same distance per second at 60Hz and 120Hz")
    func autoScrollSpeedIgnoresRefreshRate() {
        let at60 = FixedPageWebtoonViewController.autoScrollStep(speedSetting: 3, frameInterval: 1.0 / 60)
        let at120 = FixedPageWebtoonViewController.autoScrollStep(speedSetting: 3, frameInterval: 1.0 / 120)
        // A 60Hz frame keeps the step the setting was tuned against: 0.8pt per unit.
        #expect(abs(at60 - 2.4) < 0.0001)
        #expect(abs(at60 * 60 - at120 * 120) < 0.0001)
        // The setting's floor still applies.
        #expect(abs(FixedPageWebtoonViewController.autoScrollStep(speedSetting: 0, frameInterval: 1.0 / 60) - 0.8) < 0.0001)
    }

    @Test("reader taps ignore controls and their nested labels")
    @MainActor
    func readerTapExcludesControls() {
        let page = UIView()
        let button = UIButton(type: .system)
        let nested = UIView()
        let label = UILabel()
        page.addSubview(button)
        button.addSubview(nested)
        nested.addSubview(label)
        #expect(FixedPageReaderControlTapDelegate.acceptsReaderTap(on: page))
        #expect(!FixedPageReaderControlTapDelegate.acceptsReaderTap(on: button))
        #expect(!FixedPageReaderControlTapDelegate.acceptsReaderTap(on: label))
    }

    @Test("auto-scroll reports its actual state and stops when the reader disappears")
    @MainActor
    func autoScrollStateFollowsReader() {
        let container = AutoScrollContainer()
        let width = FixedPageTargetWidth()
        width.value = 820
        let reader = FixedPageWebtoonViewController(
            fixedPageReaderConfiguration: .recommendedDefault(for: .webtoon), targetWidth: width
        )
        reader.container = container
        reader.toggleAutoScroll()
        #expect(reader.isAutoScrolling)
        #expect(container.states == [true])
        reader.startAutoScroll()
        #expect(container.states == [true])
        reader.stopAutoScroll()
        #expect(!reader.isAutoScrolling)
        #expect(container.states == [true, false])
        reader.toggleAutoScroll()
        reader.beginAppearanceTransition(false, animated: false)
        reader.endAppearanceTransition()
        #expect(!reader.isAutoScrolling)
        #expect(container.states == [true, false, true, false])
    }

    @Test("a speed change reaches the running webtoon reader without reinstalling it (FB-150)")
    @MainActor
    func speedChangeAppliesLive() throws {
        let metadata = FileManager.default.temporaryDirectory
            .appendingPathComponent("webtoon-speed-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: metadata) }
        let store = BookStore(metadataFileURL: metadata)
        var book = ReadingBook(title: "Strip", author: "", contentFilename: "")
        book.isOnline = true
        book.onlineChapters = [OnlineChapterRef(index: 0, title: "1", url: "https://example.invalid/0")]
        let webtoon = FixedPageReaderConfiguration.recommendedDefault(for: .webtoon)
        store.readerSettings.setFixedPageConfiguration(webtoon, for: book.id)
        let state = FixedPageReaderState()
        let controller = FixedPageReaderViewController(
            book: book, store: store, state: state, chapterFetcher: MockChapterFetcher())
        controller.loadViewIfNeeded()

        let strip = try #require(controller.reader as? FixedPageWebtoonViewController)
        strip.startAutoScroll()
        var faster = webtoon
        faster.autoScrollSpeed = 7
        state.onSetConfiguration?(faster)

        #expect(controller.reader === strip)
        #expect(strip.isAutoScrolling)
        #expect(strip.fixedPageReaderConfiguration.autoScrollSpeed == 7)
        #expect(state.fixedPageReaderConfiguration.autoScrollSpeed == 7)
        #expect(store.readerSettings.fixedPageConfiguration(for: book.id).autoScrollSpeed == 7)

        // Anything else still rebuilds the reader with the new configuration.
        var cropped = faster
        cropped.cropBorders.toggle()
        state.onSetConfiguration?(cropped)
        #expect(controller.reader !== strip)
        strip.stopAutoScroll()
    }

    @Test("only a speed-only difference skips the reinstall")
    func speedOnlyDifference() {
        let base = FixedPageReaderConfiguration.recommendedDefault(for: .webtoon)
        var speed = base
        speed.autoScrollSpeed = 9
        var both = speed
        both.pillarbox.toggle()
        #expect(FixedPageReaderViewController.differsOnlyInAutoScrollSpeed(base, speed))
        #expect(!FixedPageReaderViewController.differsOnlyInAutoScrollSpeed(base, both))
        #expect(!FixedPageReaderViewController.differsOnlyInAutoScrollSpeed(base, base))
    }

}


@MainActor
private final class AutoScrollContainer: FixedPageReaderContainer {
    var states: [Bool] = []
    func readerAutoScrollStateChanged(_ isActive: Bool) { states.append(isActive) }
    func reader(didMoveToPage page: Int, total: Int) {}
    func readerRequestsNextChapter() {}
    func readerRequestsPreviousChapter() {}
    func readerHideControlsForPageTurn() -> Bool { false }
    func readerToggleControls() {}
    func readerToggleBookmark() {}
    func readerShowTableOfContents() {}
}
