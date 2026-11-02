import XCTest

/// Scroll mode's 閱讀進度 slider lands on a chapter and lets go of the scrub when the finger lifts.
///
/// On the iOS 26.5 simulator a release anywhere but exactly on a chapter's notch moved the reader
/// to that chapter, but the scrub preview (percent and chapter title) and the slider's value stayed
/// at the release position for good: iOS 26's slider sends one last `valueChanged` as its thumb
/// settles after `touchUpInside`, and a SwiftUI `Slider` took that as a new scrub that never ended
/// (`ReaderProgressSlider`). It showed first on 守燈人手記 jumping between writing-mode segments,
/// but a release inside one segment stuck the same way.
///
/// The book is the converted `vertical-zh.azw3` fixture (spine 0 cover, 1 and 2 vertical-rl
/// chapters, 3 a horizontal Calibre TOC), so the slider's notches are 0, 33, 67 and 100%. It is
/// imported at launch (`-auto-import-epub`, DEBUG) and left on the shelf for the next run.
final class ReaderChapterSliderUITests: XCTestCase {
    private static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("iOS/yuedu appTests/Fixtures/MOBI/vertical-zh.azw3")
    private static let title = "守燈人手記"
    private static let notches: Set<String> = ["0%", "33%", "67%", "100%"]
    private var folder: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ReaderChapterSlider-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Self.fixture, to: folder.appendingPathComponent("vertical-zh.azw3"))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    @MainActor
    func testReleasingTheSliderLandsOnAChapterAndEndsTheScrub() throws {
        // iOS 17.5 otherwise puts a system Apple ID sign-in over the app at launch.
        _ = try StoreKitTestSessions.fresh(StoreKitTestSessions.yueduPro())
        let app = XCUIApplication()
        app.launchArguments = ["-no-official-modules", "-onboarding.completed", "YES",
                               "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
                               "-reset-reading-settings", "-yd_scroll_mode", "YES",
                               "-auto-import-epub", folder.appendingPathComponent("vertical-zh.azw3").path,
                               "-auto-import-title", Self.title]
        app.launch()
        let shelfTab = app.tabBars.buttons["書架"].firstMatch
        XCTAssertTrue(shelfTab.waitForExistence(timeout: 30), app.debugDescription)
        shelfTab.tap()
        let book = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", Self.title + "，")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 30), app.debugDescription)
        book.tap()

        let slider = app.sliders["閱讀進度"].firstMatch
        for _ in 0..<3 where !slider.waitForExistence(timeout: 5) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
        }
        XCTAssertTrue(slider.exists, app.debugDescription)

        // To the Calibre TOC; then a release inside the last chapters' range, wherever the drag
        // ends; then into the first chapter's vertical segment, where it was first seen stuck.
        slider.adjust(toNormalizedSliderPosition: 1)
        assertLanded(slider, in: app, on: ["100%"])
        slider.adjust(toNormalizedSliderPosition: 0.9)
        assertLanded(slider, in: app, on: Self.notches)
        slider.adjust(toNormalizedSliderPosition: 0.34)
        assertLanded(slider, in: app, on: ["33%"])

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "landed on 第一章"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// The slider's value reaches one of `values` and the scrub preview, whose first line is the
    /// percent alone, is gone.
    @MainActor
    private func assertLanded(_ slider: XCUIElement, in app: XCUIApplication, on values: Set<String>,
                              file: StaticString = #filePath, line: UInt = #line) {
        let preview = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "^[0-9]+%$"))
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let value = slider.value as? String, values.contains(value), preview.count == 0 { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTFail("slider at \(String(describing: slider.value)), preview \(preview.allElementsBoundByIndex.map(\.label)); "
                + "expected one of \(values.sorted()) and no preview", file: file, line: line)
    }
}
