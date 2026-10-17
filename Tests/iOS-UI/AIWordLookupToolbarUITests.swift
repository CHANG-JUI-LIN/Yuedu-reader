import XCTest

/// AI 查詞's 繼續問 AI keeps one width whatever its title's length, with the title inside
/// its capsule. Runs on the design fixture: no AI key, book or network needed.
final class AIWordLookupToolbarUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAskAIKeepsOneWidthInEveryLanguage() throws {
        var widths: [String: CGFloat] = [:]
        for language in ["zh-Hant", "ja", "en"] {
            let app = XCUIApplication()
            app.launchArguments = ["-no-official-modules", "-AppleLanguages", "(\(language))",
                                   "-ai-chat-design-fixture", "-ai-word-lookup"]
            app.launch()
            let askAI = app.buttons["ai_word_lookup_ask_ai"]
            XCTAssertTrue(askAI.waitForExistence(timeout: 20), app.debugDescription)
            widths[language] = askAI.frame.width
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "AI lookup bottom bar, \(language)"
            attachment.lifetime = .keepAlways
            add(attachment)
            app.terminate()
        }
        let distinct = Set(widths.values.map { ($0 * 2).rounded() })
        XCTAssertEqual(distinct.count, 1, "繼續問 AI changed width with the language: \(widths)")
    }
}
