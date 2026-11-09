import Combine
import XCTest
@testable import yuedu_app

@MainActor
final class ReaderSettingsPublicationTests: XCTestCase {
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

    func testUserEditStillWritesBack() {
        let settings = GlobalSettings.shared
        let original = settings.readerFontSize
        defer {
            settings.readerFontSize = original
            ReaderConfig.shared.syncFromGlobalSettings()
        }
        let expected = original + 1
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
