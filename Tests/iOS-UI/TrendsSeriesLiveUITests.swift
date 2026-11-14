import XCTest

/// A series on 趨勢 opens as a series first (maintainer, 2026-11-14: 「點進去先這樣」): the card of
/// a work the list names the volumes of opens the series' page, which lists them, and its button
/// opens the work's own 作品詳情: the work's own cover, and the series named on it as the way back.
///
/// Live: the lists are the day's, from gateway.yuedureader.com (趨勢 is an official module, its
/// lists made on the host). 凡人修仙傳 has been 華語's most viewed work since the lists began; a
/// day it is not on the year's list, or the host is down, the test is skipped.
final class TrendsSeriesLiveUITests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("TrendsSeries-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testASeriesCardOpensItsSeriesPage() throws {
        let section: [String: Any] = [
            "binding": ["type": "module", "moduleID": "trends", "entryID": "year"], "id": UUID().uuidString,
            "isEnabled": true, "layout": "row", "parameters": ["region": "zh-Hant"], "title": ""]
        let home = directory.appendingPathComponent("explore_home.json")
        try JSONSerialization.data(withJSONObject: ["configurations": [Any](), "schemaVersion": 2, "sections": [section]])
            .write(to: home)
        let app = XCUIApplication()
        app.launchArguments = ["-reset-explore-home", "-explore-home-file", home.path, "-onboarding.completed", "YES",
                               "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW"]
        app.launch()
        let tab = app.tabBars.buttons["探索"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30))
        tab.tap()
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'home.card.module.' AND label BEGINSWITH %@",
                                                    "凡人修仙傳")).firstMatch
        try XCTSkipUnless(card.waitForExistence(timeout: 60), "凡人修仙傳 is not on today's list, or the lists did not load")
        card.tap()

        // The series' page: its name, 「系列」 alone (the list's books are not the series' count),
        // and a row for each volume as Bangumi names it. A print volume has no page of its own.
        let volumes = app.descendants(matching: .any).matching(identifier: "detail.series.volume")
        XCTAssertTrue(volumes.firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.staticTexts["系列"].firstMatch.exists, app.debugDescription)
        XCTAssertGreaterThan(volumes.count, 3)
        XCTAssertTrue(volumes.firstMatch.label.hasPrefix("凡人修仙傳"), volumes.firstMatch.label)
        XCTAssertEqual(app.buttons.matching(identifier: "detail.series.volume").count, 0, "only named: no button")
        attach(app, "trends-series-page")
        app.swipeUp()
        attach(app, "trends-series-page-volumes")
        app.swipeDown()

        // The button: the work's own 作品詳情, which leads to no series page again.
        let open = app.buttons["作品詳情"].firstMatch
        XCTAssertTrue(open.isHittable, app.debugDescription)
        open.tap()
        XCTAssertTrue(app.descendants(matching: .any)["detail.info.source"].firstMatch.waitForExistence(timeout: 15)
                      || app.staticTexts["簡介"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(volumes.count, 0, "the work's page lists no volumes")
        attach(app, "trends-series-work-detail")
        // It names the series, and the name leads back to the series' page.
        let series = app.buttons["detail.link.series"].firstMatch
        XCTAssertTrue(series.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(series.label, "系列")
        series.tap()
        XCTAssertTrue(volumes.firstMatch.waitForExistence(timeout: 10), app.debugDescription)
    }

    /// 英語's series are the pool's books of one series: each row is a book that opens as a work
    /// of its own, its page naming the series as the way back.
    @MainActor
    func testAnEnglishSeriesOpensItsBooks() throws {
        let section: [String: Any] = [
            "binding": ["type": "module", "moduleID": "trends", "entryID": "year"], "id": UUID().uuidString,
            "isEnabled": true, "layout": "row", "parameters": ["region": "en"], "title": ""]
        let home = directory.appendingPathComponent("explore_home.json")
        try JSONSerialization.data(withJSONObject: ["configurations": [Any](), "schemaVersion": 2, "sections": [section]])
            .write(to: home)
        let app = XCUIApplication()
        app.launchArguments = ["-reset-explore-home", "-explore-home-file", home.path, "-onboarding.completed", "YES",
                               "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW"]
        app.launch()
        let tab = app.tabBars.buttons["探索"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30))
        tab.tap()
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'home.card.module.'"))
        try XCTSkipUnless(cards.firstMatch.waitForExistence(timeout: 60), "the lists did not load")
        // The first card on screen that stands for a series; a book alone opens its own page.
        let rows = app.buttons.matching(identifier: "detail.series.volume")
        var opened = false
        for index in 0..<min(cards.count, 4) where !opened {
            cards.element(boundBy: index).tap()
            opened = rows.firstMatch.waitForExistence(timeout: 6)
            if !opened { app.navigationBars.buttons.firstMatch.tap() }
        }
        try XCTSkipUnless(opened, "none of the first cards is a series today")
        XCTAssertGreaterThan(rows.count, 1, app.debugDescription)
        attach(app, "trends-series-en-page")

        // A book of the series: its own page, the series over its title, which leads back.
        let second = rows.element(boundBy: 1)
        let name = second.label
        second.tap()
        let series = app.buttons["detail.link.series"].firstMatch
        XCTAssertTrue(series.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.staticTexts[name].firstMatch.exists, "\(name)\n\(app.debugDescription)")
        XCTAssertNotEqual(series.label, "系列", "an English series has a name")
        attach(app, "trends-series-en-volume")
        series.tap()
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10), app.debugDescription)
    }
}
