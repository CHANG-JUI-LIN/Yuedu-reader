import Foundation
import Testing
@testable import yuedu_app

/// Feedback #25 and #22: the top and bottom page margins a reader set came back as 上下邊距
/// after every sign-in, because the account gateway dropped both fields and a profile without
/// them overwrote them with `pageMarginV`.
@MainActor
@Suite("Synced reader margins", .serialized)
struct ReaderPreferencesMarginSyncTests {
    /// What the gateway returned before it kept the fields: the preferences without them.
    private func withoutTopAndBottom(_ preferences: ReaderPreferences) throws -> ReaderPreferences {
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as? [String: Any])
        object["pageMarginTop"] = nil
        object["pageMarginBottom"] = nil
        return try JSONDecoder().decode(ReaderPreferences.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test("a profile without top and bottom margins keeps this device's; one with them sets them")
    func missingMarginsKeepLocal() throws {
        let settings = GlobalSettings.shared
        let saved = ReaderPreferences.current(settings: settings)
        defer { saved.apply(to: settings) }
        settings.pageMarginV = 20
        settings.pageMarginTop = 88
        settings.pageMarginBottom = 110

        let synced = try withoutTopAndBottom(.current(settings: settings))
        #expect(synced.pageMarginTop == nil)
        synced.apply(to: settings)
        #expect(settings.pageMarginTop == 88)
        #expect(settings.pageMarginBottom == 110)

        var other = ReaderPreferences.current(settings: settings)
        other.pageMarginTop = 120
        other.pageMarginBottom = 64
        other.apply(to: settings)
        #expect(settings.pageMarginTop == 120)
        #expect(settings.pageMarginBottom == 64)
    }
}
