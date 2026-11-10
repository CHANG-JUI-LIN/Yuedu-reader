import Foundation
import Testing
@testable import yuedu_app

/// The audiobook player's right-hand button (feedback #170): 快轉 15 秒 unless someone picks
/// 下一章, so nothing changes for anyone who has not.
struct AudiobookForwardButtonTests {
    private func defaults() -> UserDefaults {
        let name = "AudiobookForwardButtonTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("nothing saved reads as 快轉 15 秒")
    func defaultsToSkipForward() {
        #expect(AudiobookForwardButton.saved(in: defaults()) == .skipForward15)
    }

    @Test("a saved choice reads back")
    func readsSavedChoice() {
        let defaults = defaults()
        defaults.set(AudiobookForwardButton.nextChapter.rawValue, forKey: AudiobookForwardButton.storageKey)
        #expect(AudiobookForwardButton.saved(in: defaults) == .nextChapter)
    }

    @Test("an unknown value falls back to 快轉 15 秒")
    func unknownValue() {
        let defaults = defaults()
        defaults.set("bogus", forKey: AudiobookForwardButton.storageKey)
        #expect(AudiobookForwardButton.saved(in: defaults) == .skipForward15)
    }
}
