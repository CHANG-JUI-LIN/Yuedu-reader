import Foundation
import Testing
@testable import yuedu_app

@Suite("Explore modes", .serialized)
struct ExploreModeTests {
    @Test @MainActor func modeMenuAvailability() {
        #expect(!ExploreTabRoot.showsModeMenu(hasImportedSources: false, librariesAvailable: true))
        #expect(ExploreTabRoot.showsModeMenu(hasImportedSources: true, librariesAvailable: true))
        #expect(!ExploreTabRoot.showsModeMenu(hasImportedSources: true, librariesAvailable: false))
    }

    @Test func effectiveMode() {
        for stored in ExploreMode.allCases {
            for hasSources in [false, true] {
                #expect(ExploreMode.effective(stored: stored, hasImportedSources: hasSources, librariesAvailable: false) == .bookSources)
            }
            #expect(ExploreMode.effective(stored: stored, hasImportedSources: false, librariesAvailable: true) == .publicLibraries)
            #expect(ExploreMode.effective(stored: stored, hasImportedSources: true, librariesAvailable: true) == stored)
        }
    }

    @Test func migrationAndStorage() throws {
        #expect(ExploreSettings.modeKey == "explore.mode")
        #expect(ExploreMode.publicLibraries.rawValue == "libraries")
        #expect(ExploreMode.bookSources.rawValue == "sources")
        #expect(ExploreMode.initialValue(hasImportedSources: true) == .bookSources)
        #expect(ExploreMode.initialValue(hasImportedSources: false) == .publicLibraries)
        #expect(ExploreMode.storedValue("future", hasImportedSources: true) == .bookSources)
        #expect(ExploreMode.storedValue("future", hasImportedSources: false) == .publicLibraries)
        let suite = "ExploreModeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        ExploreMode.initializeIfNeeded(hasImportedSources: false, defaults: defaults)
        #expect(defaults.string(forKey: ExploreSettings.modeKey) == "libraries")
        ExploreMode.initializeIfNeeded(hasImportedSources: true, defaults: defaults)
        #expect(defaults.string(forKey: ExploreSettings.modeKey) == "libraries")
        defaults.removeObject(forKey: ExploreSettings.modeKey)
        ExploreMode.initializeIfNeeded(hasImportedSources: true, defaults: defaults)
        #expect(defaults.string(forKey: ExploreSettings.modeKey) == "sources")
        for mode in ExploreMode.allCases {
            defaults.set(mode.rawValue, forKey: ExploreSettings.modeKey)
            #expect(ExploreMode.storedValue(defaults.string(forKey: ExploreSettings.modeKey), hasImportedSources: true) == mode)
        }
    }
}
