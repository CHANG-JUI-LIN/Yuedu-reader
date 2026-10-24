import XCTest

/// Module ecosystem M5c: a book of なろう's module read in the app — searched in 搜尋, its
/// chapters listed on 作品詳情, its first episode open in the reader, added to the shelf.
///
/// The bundled なろう file is read with its two sites moved to a fixture served from outside
/// the simulator, from the repo root: `python3 -I scripts/narou_reading_fixture.py` (port 18770).
/// It is the only official module the app reads (`-official-modules-dir`), so nothing leaves
/// the machine.
final class NarouReadingUITests: XCTestCase {
    // `localhost`, not 127.0.0.1: a request to a reserved address is refused (`safeURL`).
    private static let fixture = "http://localhost:18770"
    private static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    private var directory: URL!
    /// This run's work: a new one each run, so no copy an earlier run left is read instead.
    private let ncode = "N\(Int.random(in: 1000...9999))ZZ"

    override func setUpWithError() throws {
        continueAfterFailure = false
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("NarouReading-\(UUID().uuidString)")
        let official = directory.appendingPathComponent("official")
        try FileManager.default.createDirectory(at: official, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("sources"), withIntermediateDirectories: true)
        let bundled = try String(contentsOf: Self.repo.appendingPathComponent("Resources/Assets/official-module-narou.json"),
                                 encoding: .utf8)
        var module = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(bundled
            .replacingOccurrences(of: "https://api.syosetu.com", with: Self.fixture)
            .replacingOccurrences(of: "https://ncode.syosetu.com", with: Self.fixture).utf8)) as? [String: Any])
        module["hosts"] = ["localhost"]
        try JSONSerialization.data(withJSONObject: module).write(to: official.appendingPathComponent("official-module-narou.json"))
        _ = try Data(contentsOf: URL(string: "\(Self.fixture)/reset?ncode=\(ncode)")!)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func asked() throws -> [String] {
        let data = try Data(contentsOf: URL(string: "\(Self.fixture)/log")!)
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testSearchReadAndShelve() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-onboarding.completed", "YES", "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
                               "-official-modules-dir", directory.appendingPathComponent("official").path,
                               "-yd_source_disclaimer_accepted", "YES",
                               "-book-source-store-dir", directory.appendingPathComponent("sources").path,
                               "-reset-explore-home"]
        app.launchEnvironment["YUEDU_PUBLIC_LIBRARY_FIXTURES"] = directory.path
        app.launch()

        let tab = app.tabBars.buttons["搜尋"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30))
        tab.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Mushoku\n")

        let work = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Mushoku Tensei \(ncode)")).firstMatch
        XCTAssertTrue(work.waitForExistence(timeout: 30), app.debugDescription)
        attach(app, "narou-search")
        work.tap()

        // 作品詳情 reads its chapter list through the module: both pages, then no more.
        let chapter = app.descendants(matching: .any)["detail.toc.1"].firstMatch
        for _ in 0..<6 where !chapter.exists { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(chapter.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(app.staticTexts["小説家になろう"].firstMatch.exists, "its 來源 is the module\n\(app.debugDescription)")
        // An earlier run's book stays on this simulator's shelf, and launch asks for its update
        // (`/N…ZZ/` of that run): only this run's work counts here.
        let earlierRuns = try NSRegularExpression(pattern: "^/N\\d{4}ZZ/$")
        XCTAssertEqual(try asked().filter { path in
            !path.hasPrefix("/novelapi") && (path == "/\(ncode)/"
                || earlierRuns.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) == nil)
        }, ["/\(ncode)/", "/n9669bk/?p=2"])
        attach(app, "narou-detail")

        let read = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '開始閱讀'")).firstMatch
        for _ in 0..<6 where !read.isHittable { app.swipeDown(velocity: .slow) }
        XCTAssertTrue(read.isHittable, app.debugDescription)
        read.tap()

        // The prologue's text, read through the module.
        let text = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "住所不定無職")).firstMatch
        for _ in 0..<3 where !text.waitForExistence(timeout: 20) { app.swipeLeft() }
        XCTAssertTrue(text.exists, app.debugDescription)
        let requested = try asked()
        XCTAssertTrue(requested.contains("/n9669bk/1/"), requested.joined(separator: "\n"))
        attach(app, "narou-reader")

        // Leaving a book read without 加入書架 asks; adding it puts it on the shelf.
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
        let add = app.buttons["加入書架"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10), app.debugDescription)
        add.tap()
        XCTAssertTrue(app.buttons["已加入書架"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        attach(app, "narou-shelved")
    }
}
