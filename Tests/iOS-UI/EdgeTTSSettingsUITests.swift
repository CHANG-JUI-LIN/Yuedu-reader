import XCTest

final class EdgeTTSSettingsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testBuiltInVoiceSelectionAndNativePicker() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        seedImportedVoices(app)
        app.launch()
        openSettings(app)

        let source = app.buttons["tts_edge_source"]
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        let system = app.buttons["tts_system_source"]
        XCTAssertTrue(system.exists)
        system.tap()
        XCTAssertEqual(system.value as? String, "In Use")
        source.tap()
        XCTAssertEqual(system.value as? String, "Not Selected")
        XCTAssertEqual(source.value as? String, "In Use")
        XCTAssertTrue(app.staticTexts["tts_builtin_section"].exists)
        XCTAssertTrue(app.staticTexts["tts_imported_section"].exists)
        let imported = app.descendants(matching: .any)["tts_imported_fixture-account"].firstMatch
        XCTAssertTrue(imported.exists)
        XCTAssertFalse(app.staticTexts["@js:fixture-account"].exists)
        XCTAssertFalse(app.staticTexts["Requires Login"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "sent to Microsoft")).firstMatch.exists)
        let builtInCell = app.cells.containing(.button, identifier: "tts_edge_source").firstMatch
        let importedCell = app.cells.containing(.any, identifier: "tts_imported_fixture-account").firstMatch
        XCTAssertEqual(builtInCell.frame.height, importedCell.frame.height, accuracy: 1)
        attach("edge-tts-settings")

        let picker = app.descendants(matching: .any)["tts_edge_voice"].firstMatch
        XCTAssertTrue(picker.exists)
        picker.tap()
        let voice = app.buttons["Yunxi · Mandarin · Male"].firstMatch
        for _ in 0..<4 where !voice.isHittable { app.swipeUp() }
        XCTAssertTrue(voice.waitForExistence(timeout: 5))
        attach("edge-tts-voice-picker")
        voice.tap()
        // Native navigation-link pickers may return immediately after selection.
        if !source.waitForExistence(timeout: 2) { app.navigationBars.buttons.element(boundBy: 0).tap() }
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        XCTAssertTrue((picker.value as? String)?.contains("Yunxi") == true)
        XCTAssertTrue(app.buttons["tts_edge_preview"].exists)
        attach("edge-tts-selected-voice")
    }

    @MainActor
    func testTraditionalChineseLargestTextLayout() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
            "-AppleInterfaceStyle", "Dark",
        ]
        seedImportedVoices(app)
        app.launch()
        openSettings(app)
        let source = app.buttons["tts_edge_source"]
        for _ in 0..<4 where !source.isHittable { app.swipeUp() }
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        attach("edge-tts-traditional-chinese-large-text")
        let picker = app.descendants(matching: .any)["tts_edge_voice"].firstMatch
        for _ in 0..<3 where !picker.isHittable { app.swipeUp() }
        picker.tap()
        let firstVoice = app.buttons["曉臻・台灣華語・女聲"].firstMatch
        for _ in 0..<4 where !firstVoice.isHittable { app.swipeDown() }
        XCTAssertTrue(firstVoice.waitForExistence(timeout: 5))
        attach("edge-tts-voice-picker-large-text")
    }

    @MainActor
    private func seedImportedVoices(_ app: XCUIApplication) {
        let json = #"[{"id":"fixture-account","name":"小米 MiMo TTS","urlTemplate":"@js:fixture-account","headers":{},"loginUi":"[]"},{"id":"fixture-simple","name":"納米 AI TTS","urlTemplate":"https://example.invalid/tts","headers":{}}]"#
        let hex = Data(json.utf8).map { String(format: "%02x", $0) }.joined()
        app.launchArguments += ["-yd_imported_tts_sources", "<\(hex)>"]
    }

    @MainActor
    private func openSettings(_ app: XCUIApplication) {
        let notNow = app.buttons["Don’t Allow"]
        if notNow.waitForExistence(timeout: 2) { notNow.tap() }
        let settings = app.tabBars.buttons.matching(NSPredicate(format: "label IN %@", ["Settings", "設定"])).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 20))
        settings.tap()
        let entry = app.staticTexts.matching(NSPredicate(format: "label IN %@", ["TTS Settings", "語音朗讀設定"])).firstMatch
        for _ in 0..<6 where !entry.isHittable { app.swipeUp() }
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
    }

    @MainActor
    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
