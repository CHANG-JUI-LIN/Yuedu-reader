import XCTest

/// MOBI plan, step 6: an AZW3 picked in the system's document picker reaches the shelf and
/// opens. The unit tests convert the same fixture; what only this route proves is that the
/// Kindle types the app declares (`org.mobipocket.mobi`, `com.amazon.azw`) let the picker
/// offer an `.azw3` at all, and that what the picker hands over ends as a readable book.
///
/// The fixture goes into the Files app's On My iPhone — the simulator's
/// `group.com.apple.FileProvider.LocalStorage` app group — under a name unique to the run, and
/// the book is deleted from the shelf at the end.
final class KindleImportUITests: XCTestCase {
    private static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("iOS/yuedu appTests/Fixtures/MOBI/features.azw3")
    private static let title = "The Lantern Keeper's Almanac"
    /// The first sentence of the book's first chapter.
    private static let opening = "This almanac begins on the night"
    private var staged: URL?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        if let staged { try FileManager.default.removeItem(at: staged) }
    }

    @MainActor
    func testAZW3PickedInFilesOpensInTheReader() throws {
        let name = "Lantern-\(Int.random(in: 1000...9999))"
        staged = try stageInFiles(Self.fixture, as: name + ".azw3")

        let app = XCUIApplication()
        app.launchArguments = ["-no-official-modules", "-onboarding.completed", "YES",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-yd_root_tab_visible_ids", "(bookshelf, settings)", "-bookLayoutIsGrid", "YES"]
        app.launch()

        let addBook = app.buttons["home_add_book"]
        XCTAssertTrue(addBook.waitForExistence(timeout: 20), app.debugDescription)
        // A run cut short leaves its book behind. It goes first, so the shelf check below
        // can only be met by this run's copy.
        let copies = app.scrollViews["home_book_grid"].buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", Self.title))
        deleteAll(copies, in: app)
        addBook.tap()
        // A menu item from iOS 18, a row of the dismissal-sequenced chooser on iOS 17.
        let fromFiles = app.buttons["Import from Files…"].firstMatch
        XCTAssertTrue(fromFiles.waitForExistence(timeout: 5), app.debugDescription)
        fromFiles.tap()
        let choose = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Tap to Choose")).firstMatch
        XCTAssertTrue(choose.waitForExistence(timeout: 10), app.debugDescription)
        choose.tap()

        pick(name, in: app)

        // The picker allows several files, so it can stay up until Open.
        let open = app.buttons.matching(NSPredicate(format: "label IN %@", ["Open", "打開"])).firstMatch
        if open.waitForExistence(timeout: 3), open.isEnabled { open.tap() }

        // The sheet closes itself once every picked file is on the shelf.
        let book = copies.firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 60), "the book never reached the shelf\n\(app.debugDescription)")
        book.tap()

        // Paged mode, the default: the converted book may open on its cover page.
        let text = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", Self.opening)).firstMatch
        for _ in 0..<4 where !text.waitForExistence(timeout: 10) {
            app.swipeLeft()
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "converted AZW3 in the reader"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertTrue(text.exists, "the first chapter never showed\n\(app.debugDescription)")

        leaveReader(app)
        deleteAll(copies, in: app)
    }

    // MARK: - Files

    /// Copies `file` into On My iPhone's root. The test runner's home is
    /// `…/data/Containers/Data/Application/<id>`; the app group is under `…/data/Containers/Shared`.
    @MainActor
    private func stageInFiles(_ file: URL, as name: String) throws -> URL {
        // A simulator that never ran Files has the app group but not its storage folder yet.
        let files = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
        files.launch()
        files.terminate()

        let containers = URL(fileURLWithPath: NSHomeDirectory())
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let groups = containers.appendingPathComponent("Shared/AppGroup")
        let group = try FileManager.default.contentsOfDirectory(at: groups, includingPropertiesForKeys: nil).first { group in
            let metadata = group.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
            let plist = (try? Data(contentsOf: metadata))
                .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
            return plist?["MCMMetadataIdentifier"] as? String == "group.com.apple.FileProvider.LocalStorage"
        }
        let storage = try XCTUnwrap(group, "no Files local storage under \(groups.path)")
            .appendingPathComponent("File Provider Storage", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storage.path), "Files never made \(storage.path)")
        let target = storage.appendingPathComponent(name)
        try FileManager.default.copyItem(at: file, to: target)
        return target
    }

    /// Browse › On My iPhone › the file. Recents does not list a file no app has opened.
    @MainActor
    private func pick(_ name: String, in app: XCUIApplication) {
        let browse = app.buttons.matching(NSPredicate(format: "label IN %@", ["Browse", "瀏覽"])).firstMatch
        XCTAssertTrue(browse.waitForExistence(timeout: 15), "no document picker\n\(app.debugDescription)")
        let onMyPhone = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label IN %@", ["On My iPhone", "我的 iPhone"])).firstMatch
        // The picker reopens where it was left; a second tap on Browse goes back to its root.
        for _ in 0..<2 where !onMyPhone.waitForExistence(timeout: 3) {
            browse.tap()
        }
        XCTAssertTrue(onMyPhone.waitForExistence(timeout: 5), app.debugDescription)
        onMyPhone.tap()

        // Files may leave the extension off the name it shows.
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "\(name) is not in On My iPhone\n\(app.debugDescription)")
        // A type the app does not declare is listed dimmed and cannot be picked.
        XCTAssertTrue(row.isEnabled, "the picker offers \(name) but will not let it be picked")
        row.tap()
    }

    // MARK: - Cleanup

    @MainActor
    private func leaveReader(_ app: XCUIApplication) {
        let back = app.buttons["reader_back_button"]
        let chrome = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            if back.exists { return true }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            return false
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [chrome], timeout: 20), .completed, app.debugDescription)
        back.tap()
        XCTAssertTrue(app.buttons["home_add_book"].waitForExistence(timeout: 10), app.debugDescription)
    }

    /// Deletes every copy on the shelf, so runs do not pile copies up.
    @MainActor
    private func deleteAll(_ copies: XCUIElementQuery, in app: XCUIApplication) {
        while copies.count > 0 {
            let left = copies.count
            // A grid cell is a single element, and a press on it opens the book. Its •••
            // menu sits in the cell's bottom trailing corner, 28–32 pt square.
            copies.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
                .withOffset(CGVector(dx: -12, dy: -12)).tap()
            let delete = app.buttons["Delete Book"].firstMatch
            XCTAssertTrue(delete.waitForExistence(timeout: 5), app.debugDescription)
            delete.tap()
            let confirm = app.alerts["Confirm Deletion"].buttons["Delete"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription)
            confirm.tap()
            let fewer = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in copies.count < left }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [fewer], timeout: 10), .completed, app.debugDescription)
        }
    }
}
