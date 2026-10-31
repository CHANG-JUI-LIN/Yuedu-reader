import StoreKitTest
import XCTest

// TEMPORARY (SDF crash investigation, 2026-10-29): opens the fixture book from 書架 and closes it
// with the reader's back button, repeatedly, so lldb can watch SwiftUI's SDF styles during the
// card transition's programmatic pop. Delete before committing.
final class ScratchReaderCloseLoopUITests: XCTestCase {
    private static let fixture = "http://localhost:18771"
    private static let sourceName = "Chrome Source"
    private var directory: URL!
    private var storeKitSession: SKTestSession?
    private let token = String(Int.random(in: 1000...9999))
    private var title: String { "Chrome Fixture \(token)" }

    override func setUpWithError() throws {
        continueAfterFailure = false
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScratchReaderClose-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source: [String: Any] = [
            "bookSourceName": Self.sourceName,
            "bookSourceUrl": Self.fixture,
            "bookSourceType": 0,
            "enabled": true,
            "enabledExplore": true,
            "exploreUrl": "熱門::\(Self.fixture)/explore?page={{page}}",
            "searchUrl": "\(Self.fixture)/search?q={{key}}&page={{page}}",
            "ruleExplore": ["bookList": "class.book", "name": "tag.h3@text", "author": "class.author@text",
                            "bookUrl": "tag.a@href"],
            "ruleSearch": ["bookList": "class.book", "name": "tag.h3@text", "author": "class.author@text",
                           "bookUrl": "tag.a@href"],
            "ruleToc": ["chapterList": "class.chapter", "chapterName": "tag.a@text", "chapterUrl": "tag.a@href"],
            "ruleContent": ["content": "id.content@html"],
            "lastUpdateTime": Int(Date().timeIntervalSince1970 * 1000),
        ]
        try JSONSerialization.data(withJSONObject: [source])
            .write(to: directory.appendingPathComponent("book_sources.json"))
        _ = try Data(contentsOf: URL(string: "\(Self.fixture)/reset?token=\(token)")!)
    }

    @MainActor
    func testShelfReaderCloseLoop() throws {
        // A fresh simulator has no StoreKit configuration; AppTransaction.shared then keeps
        // presenting the Apple Account sign-in sheet over the app.
        storeKitSession = try StoreKitTestSessions.fresh(StoreKitTestSessions.yueduPro())
        let app = XCUIApplication()
        app.launchArguments = ["-no-official-modules", "-onboarding.completed", "YES", "-AppleLanguages", "(zh-Hant)",
                               "-AppleLocale", "zh_TW", "-yd_source_disclaimer_accepted", "YES",
                               "-book-source-store-dir", directory.path]
        app.launch()
        // Gives lldb (waiting on the process name) time to attach before the reader opens.
        XCTAssertTrue(app.tabBars.buttons["資源庫"].firstMatch.waitForExistence(timeout: 60))
        Thread.sleep(forTimeInterval: Double(ProcessInfo.processInfo.environment["SCRATCH_ATTACH_WAIT"] ?? "") ?? 8)

        for attempt in 1...3 {
            app.tabBars.buttons["資源庫"].firstMatch.tap()
            if app.navigationBars["資源庫"].firstMatch.waitForExistence(timeout: 5) { break }
            print("SCRATCH TAB SWITCH FAILED attempt \(attempt): still \(app.navigationBars.firstMatch.identifier)")
        }
        let all = app.buttons["library.sources.all"].firstMatch
        for _ in 0..<6 where !all.exists { app.scrollViews.firstMatch.swipeUp(velocity: .slow) }
        XCTAssertTrue(all.waitForExistence(timeout: 10), app.debugDescription)
        all.tap()
        let source = app.buttons["library.source.\(Self.sourceName)"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 10), app.debugDescription)
        source.tap()
        let book = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 30), app.debugDescription)
        book.tap()
        let read = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '立即閱讀' OR label BEGINSWITH '開始閱讀'"))
            .firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 30), app.debugDescription)
        read.tap()
        waitForPage(app)
        showChrome(app)
        app.buttons["reader_back_button"].tap()
        let add = app.buttons["加入書架"].firstMatch
        let onShelf = app.buttons["移除書架"].firstMatch
        let left = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in add.exists || onShelf.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [left], timeout: 15), .completed, app.debugDescription)
        if add.exists { add.tap() }
        for _ in 0..<6 where !app.tabBars.buttons["書架"].firstMatch.exists {
            let back = app.buttons["BackButton"].firstMatch
            guard back.waitForExistence(timeout: 5) else { break }
            back.tap()
        }
        app.tabBars.buttons["書架"].firstMatch.tap()

        let rounds = Int(ProcessInfo.processInfo.environment["SCRATCH_ROUNDS"] ?? "") ?? 6
        for round in 1...rounds {
            let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 20), "round \(round)\n\(app.debugDescription)")
            card.tap()
            waitForPage(app)
            exerciseReader(app, round: round)
            showChrome(app)
            app.buttons["reader_back_button"].tap()
            XCTAssertTrue(app.buttons["reader_back_button"].waitForNonExistence(timeout: 10), "round \(round)")
        }
    }

    /// What a long reading session does between opening and closing: chrome on and off, page
    /// turns, the book card popover, the progress slider.
    @MainActor
    private func exerciseReader(_ app: XCUIApplication, round: Int) {
        let middle = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let toggles = Int(ProcessInfo.processInfo.environment["SCRATCH_TOGGLES"] ?? "") ?? 3
        for _ in 0..<toggles {
            showChrome(app)
            middle.tap()
            app.swipeLeft()
            app.swipeRight()
        }
        showChrome(app)
        let cover = app.buttons["書本選單"].firstMatch
        if cover.exists, cover.isHittable {
            cover.tap()
            _ = app.otherElements["PopoverDismissRegion"].firstMatch.waitForExistence(timeout: 3)
            let dismiss = app.otherElements["PopoverDismissRegion"].firstMatch
            if dismiss.exists { dismiss.tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap() }
        }
        // The title capsule is the nav bar's interactive glass: a tap opens the book card, a
        // long press opens 換源 as a sheet over the reader.
        showChrome(app)
        let capsule = app.buttons["reader_title_capsule"].firstMatch
        if capsule.exists, capsule.isHittable {
            capsule.tap()
            let dismiss = app.otherElements["PopoverDismissRegion"].firstMatch
            if dismiss.waitForExistence(timeout: 3) { dismiss.tap() }
            showChrome(app)
            capsule.press(forDuration: 0.9)
            let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
            top.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
            _ = app.buttons["reader_back_button"].waitForExistence(timeout: 5)
        }
        showChrome(app)
        let slider = app.sliders.firstMatch
        if slider.exists, slider.isHittable {
            slider.adjust(toNormalizedSliderPosition: round.isMultiple(of: 2) ? 0.9 : 0.1)
            waitForPage(app)
        }
    }

    @MainActor
    private func waitForPage(_ app: XCUIApplication) {
        let text = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "測試閱讀器工具列")).firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 60), app.debugDescription)
    }

    @MainActor
    private func showChrome(_ app: XCUIApplication) {
        let back = app.buttons["reader_back_button"]
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            if back.exists, back.isHittable { return true }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            return false
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: 60), .completed, app.debugDescription)
    }
}
