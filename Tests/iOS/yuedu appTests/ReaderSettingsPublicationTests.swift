import Combine
import XCTest
@testable import yuedu_app

@MainActor
final class ReaderSettingsPublicationTests: XCTestCase {
    func testChangedThemeAppliesOnceAndIdenticalThemeDoesNotRepublish() throws {
        let original = ReaderPreferences.current()
        defer { original.apply() }
        original.apply()
        let theme = try XCTUnwrap(ReaderTheme.allCases.first { $0.rawValue != original.theme })
        var next = original
        next.theme = theme.rawValue
        var themes: [ReaderTheme] = []
        let token = ReaderConfig.shared.$theme.dropFirst().sink { themes.append($0) }
        next.apply()
        next.apply()
        XCTAssertEqual(ReaderTheme.loadPersisted(), theme)
        XCTAssertEqual(ReaderConfig.shared.theme, theme)
        XCTAssertEqual(themes, [theme])
        withExtendedLifetime(token) {}
    }

    func testIdenticalPreferencesAndConfigPublishNothing() {
        let settings = GlobalSettings.shared
        let preferences = ReaderPreferences.current()
        preferences.apply()
        var configPublications = 0
        let settingsRecorder = ObservationRecorder { ReaderPreferences.current(settings: settings) }
        let configToken = ReaderConfig.shared.objectWillChange.sink { configPublications += 1 }
        preferences.apply()
        ReaderConfig.shared.syncFromGlobalSettings()
        XCTAssertEqual(settingsRecorder.changeCount, 0)
        XCTAssertEqual(configPublications, 0)
        settingsRecorder.cancel()
        withExtendedLifetime(configToken) {}
    }

    func testIdenticalProfileAndBubbleSyncPublishNothing() {
        let settings = GlobalSettings.shared
        let wasLoggedIn = settings.isLoggedIn
        defer { settings.isLoggedIn = wasLoggedIn }
        let profile = UserProfile(uid: settings.accountUserIdentifier,
            displayName: settings.accountDisplayName, email: settings.accountEmail,
            provider: settings.accountProvider, photoURL: settings.accountPhotoURL)
        settings.applyFirebaseProfile(profile)
        settings.applyCommentBubbleSync(styles: settings.commentBubbleCustomStyles)
        let recorder = ObservationRecorder {
            (settings.isLoggedIn, settings.accountUserIdentifier, settings.accountDisplayName,
             settings.accountEmail, settings.accountProvider, settings.accountPhotoURL,
             settings.commentBubbleCustomStyles)
        }
        settings.applyFirebaseProfile(profile)
        settings.applyCommentBubbleSync(styles: settings.commentBubbleCustomStyles)
        XCTAssertEqual(recorder.changeCount, 0)
        recorder.cancel()
    }

    func testRemoteChangeSupersedesPendingLocalWritebackWithoutEcho() {
        let settings = GlobalSettings.shared
        let original = ReaderPreferences.current()
        defer { original.apply() }
        original.apply()
        // This edit has already entered the existing slider debounce when sync arrives.
        ReaderConfig.shared.fontSize = CGFloat(original.readerFontSize + 1)
        var remote = original
        remote.readerFontSize += 2
        remote.readerHeaderTopPadding = (original.readerHeaderTopPadding ?? 0) + 5
        let fontValues = ObservationRecorder { settings.readerFontSize }
        remote.apply()
        RunLoop.main.run(until: Date())
        XCTAssertEqual(fontValues.values, [remote.readerFontSize])
        XCTAssertEqual(ReaderConfig.shared.fontSize, CGFloat(remote.readerFontSize))
        XCTAssertEqual(settings.readerHeaderTopPadding, remote.readerHeaderTopPadding)
        let echo = ObservationRecorder { ReaderPreferences.current(settings: settings) }
        // Runs past a known 120 ms debounce, not waiting for app readiness.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        XCTAssertEqual(echo.changeCount, 0, "remote sync must not echo after the slider debounce")
        XCTAssertEqual(fontValues.values, [remote.readerFontSize])
        echo.cancel()
        fontValues.cancel()
    }

    func testUserEditStillWritesBackAfterRemoteSync() {
        let settings = GlobalSettings.shared
        let original = ReaderPreferences.current()
        defer { original.apply() }
        original.apply()
        let expected = original.readerFontSize + 1
        ReaderConfig.shared.fontSize = CGFloat(expected)
        // The write-back is debounced; run the main loop until it lands, up to 2 s.
        let deadline = Date(timeIntervalSinceNow: 2)
        while settings.readerFontSize != expected, Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        XCTAssertEqual(settings.readerFontSize, expected)
    }

    func testBubbleDeletionRepairsSelectionAndPreservesSyncClock() {
        let settings = GlobalSettings.shared
        let styles = settings.commentBubbleCustomStyles
        let selected = settings.commentBubbleSelectedCustomStyleID
        let mode = settings.commentBubblePresetMode
        let clock = settings.commentBubbleSelectionSyncClock
        defer {
            settings.applyCommentBubbleSync(styles: styles)
            settings.applyCommentBubbleSync(selection: selected)
            settings.commentBubblePresetMode = mode
        }
        let style = ReaderCommentBubbleCustomStyle(name: "Publication test", svg: "<svg/>")
        settings.applyCommentBubbleSync(styles: styles + [style])
        settings.applyCommentBubbleSync(selection: style.id)
        let recorder = ObservationRecorder {
            (settings.commentBubbleSelectedCustomStyleID, settings.commentBubblePresetMode,
             settings.commentBubbleSelectionSyncClock, settings.commentBubbleCustomStyles)
        }
        settings.applyCommentBubbleSync(selection: style.id)
        XCTAssertEqual(recorder.changeCount, 0)
        recorder.cancel()
        settings.applyCommentBubbleSync(styles: styles)
        XCTAssertNil(settings.commentBubbleSelectedCustomStyleID)
        XCTAssertEqual(settings.commentBubblePresetMode, .builtin)
        XCTAssertEqual(settings.commentBubbleSelectionSyncClock, clock)
    }
}
