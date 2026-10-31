import UIKit
import XCTest

/// FB-100: 探索's 繼續閱讀 opens the reader as immersive as 書架 does — no status bar and no tab
/// bar over the page. On iOS 17 both stayed over every reader 探索 pushed, while 書架's, which
/// UIKit pushes, hid them (iOS 17.7.2; iOS 17.5 simulator): 探索's stack was built after the tab's
/// first frame, and such a tab never hands the status bar to the pages pushed on it
/// (`ExploreHome`); and the root's `.toolbar(.automatic, for: .tabBar)` overrode the pushed
/// reader's `.hidden` (`hidesRootTabBar`).
///
/// The book is a text file the test writes, imported at launch (`-auto-import-epub` with an
/// absolute path, DEBUG); the test deletes it from the shelf at the end.
final class ReaderEntryImmersionUITests: XCTestCase {
    private let title = "沉浸入口測試"
    private let body = "沉浸入口測試正文，用來確認閱讀器打開了這本書。"
    private var folder: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ReaderEntryImmersion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let text = "第一章 開始\n\n\(body)\n\n" + String(repeating: "\(body)\n", count: 20)
        try Data(text.utf8).write(to: folder.appendingPathComponent("\(title).txt"))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    /// The system's chrome over the reader.
    private struct Chrome: Equatable {
        var statusBar: Bool
        var tabBar: Bool
    }

    @MainActor
    private func chrome(over app: XCUIApplication) -> Chrome {
        let tabBar = app.tabBars.firstMatch
        return Chrome(statusBar: statusBarIsDrawn(over: app), tabBar: tabBar.exists && tabBar.isHittable)
    }

    /// Whether anything but the page's background is drawn in the status bar's band. XCUITest's
    /// status bar is SpringBoard's, there and the same whether the app hides the bar or not, so
    /// the screen is read instead: the reader leaves that band to its plain background (no pixel
    /// off it over 書架's reader, 2.5% of them over 探索's on the iOS 17.5 simulator).
    @MainActor
    private func statusBarIsDrawn(over app: XCUIApplication) -> Bool {
        let band = XCUIApplication(bundleIdentifier: "com.apple.springboard").statusBars.firstMatch.frame
        guard band.height > 0, let image = app.screenshot().image.cgImage else { return false }
        let width = image.width
        let height = Int(band.maxY * CGFloat(width) / app.frame.width)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            // The image's top rows: the context's origin is its bottom left.
            context?.draw(image, in: CGRect(x: 0, y: height - image.height, width: width, height: image.height))
        }
        // The background is the band's bottom middle, under the Dynamic Island, between the clock
        // and the battery.
        let middle = ((height - 1) * width + width / 2) * 4
        let background = pixels[middle..<middle + 3].map(Int.init)
        let drawn = stride(from: 0, to: pixels.count, by: 4).count { offset in
            (0..<3).contains { abs(Int(pixels[offset + $0]) - background[$0]) > 48 }
        }
        return drawn * 500 > width * height
    }

    /// The chrome once the reader's own has gone: the bars leave with an animation.
    @MainActor
    private func settledChrome(over app: XCUIApplication) -> Chrome {
        let immersive = Chrome(statusBar: false, tabBar: false)
        let deadline = Date().addingTimeInterval(5)
        var seen = chrome(over: app)
        while seen != immersive, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            seen = chrome(over: app)
        }
        return seen
    }

    @MainActor
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// The book's shelf cell: grid and list both make it one element labelled with the title first.
    @MainActor
    private func shelfBook(_ app: XCUIApplication) -> XCUIElement {
        let cell = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title + "，")).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 30), app.debugDescription)
        return cell
    }

    @MainActor
    private func waitForReader(_ app: XCUIApplication) -> XCUIElement {
        let content = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", body)).firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 30), "The reader opens the book.\n\(app.debugDescription)")
        return content
    }

    /// Back out of the reader with the edge swipe every reader keeps.
    @MainActor
    private func leaveReader(_ app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 1, dy: app.frame.height * 0.5))
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
    }

    @MainActor
    func testExploreContinueReadingIsAsImmersiveAsTheShelf() {
        let app = XCUIApplication()
        app.launchArguments = ["-no-official-modules", "-onboarding.completed", "YES", "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW", "-reset-explore-home",
                               "-auto-import-epub", folder.appendingPathComponent("\(title).txt").path,
                               "-auto-import-title", title, "-yd_page_turn_style", "滑動", "-yd_scroll_mode", "NO",
                               "-book-source-store-dir", folder.appendingPathComponent("sources").path]
        app.launch()
        let shelfTab = app.tabBars.buttons["書架"].firstMatch
        XCTAssertTrue(shelfTab.waitForExistence(timeout: 30))
        shelfTab.tap()

        // 書架: the shelf's card opens the reader.
        shelfBook(app).tap()
        let content = waitForReader(app)
        let fromShelf = settledChrome(over: app)
        screenshot(app, "shelf-reader")
        leaveReader(app)
        XCTAssertTrue(content.waitForNonExistence(timeout: 10), app.debugDescription)

        // 探索: the book is in 繼續閱讀 now, and its card opens the reader on 探索's stack.
        app.tabBars.buttons["探索"].firstMatch.tap()
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'home.card.library.' AND label BEGINSWITH %@", title)).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15), app.debugDescription)
        card.tap()
        let resumed = waitForReader(app)
        let fromExplore = settledChrome(over: app)
        screenshot(app, "explore-reader")
        leaveReader(app)
        XCTAssertTrue(resumed.waitForNonExistence(timeout: 10), app.debugDescription)

        // The book leaves the shelf, so the next run starts from the same place.
        shelfTab.tap()
        let cell = shelfBook(app)
        let more = cell.buttons["更多"].firstMatch
        if more.exists {
            more.tap()
        } else {
            cell.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.96)).tap()
        }
        let delete = app.buttons["刪除書籍"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5), app.debugDescription)
        delete.tap()
        let confirm = app.alerts.buttons["刪除"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription)
        confirm.tap()
        XCTAssertTrue(cell.waitForNonExistence(timeout: 10))

        XCTAssertEqual(fromShelf, Chrome(statusBar: false, tabBar: false), "書架's reader is immersive")
        XCTAssertEqual(fromExplore, fromShelf, "探索's 繼續閱讀 opens the reader as 書架 does")
    }
}
