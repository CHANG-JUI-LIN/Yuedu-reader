import XCTest

/// FB-195: on iPadOS 27 a tap on a 最近搜索 entry did nothing — the lists went, the field
/// stayed empty, and no search ran. An active search with an empty field takes a tap in
/// the page as its Cancel on iPad, so the lists now show while the field is at rest, and
/// one tap there must run the search: the field holds the words and the idle hint does
/// not come back.
final class SearchRecentsTapUITests: XCTestCase {
    private var sourcesDirectory: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        sourcesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SearchRecentsTap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sourcesDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: sourcesDirectory)
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testTappingARecentSearchRunsIt() {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW", "-no-official-modules",
                               "-onboarding.completed", "YES", "-yd_source_disclaimer_accepted", "YES",
                               "-book-source-store-dir", sourcesDirectory.path,
                               // A quoted plist string: unquoted, the argument domain does not read it as the
                               // JSON string 最近搜索 is stored as.
                               "-yd_search_recent_queries", #""[\"FB195\"]""#]
        app.launch()

        // The iPhone's tab bar and iPad's top tab bar alike.
        let tab = app.buttons["搜尋"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30))
        tab.tap()

        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        // Listed without touching the field, as a button VoiceOver reads by its words.
        let recent = app.buttons["FB195"].firstMatch
        XCTAssertTrue(recent.waitForExistence(timeout: 10), app.debugDescription)
        attach(app, "recents")
        recent.tap()

        // One tap runs the search: the field holds the words.
        expectation(for: NSPredicate(format: "value == %@", "FB195"), evaluatedWith: field)
        waitForExpectations(timeout: 10)
        attach(app, "after tap")
        XCTAssertFalse(app.staticTexts["輸入書名或作者搜尋"].firstMatch.exists, app.debugDescription)
    }
}
