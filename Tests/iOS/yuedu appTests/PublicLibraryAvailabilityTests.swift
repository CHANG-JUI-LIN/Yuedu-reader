import Foundation
import Testing
@testable import yuedu_app

@Suite("Public library storefront availability", .serialized)
@MainActor
struct PublicLibraryAvailabilityTests {
    @Test func countriesAndColdStart() throws {
        let suite = "PublicLibraryAvailabilityTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let availability = PublicLibraryAvailability(defaults: defaults)
        #expect(availability.isAvailable)
        availability.receive(countryCode: "CHN")
        #expect(!availability.isAvailable)
        #expect(!PublicLibraryAvailability(defaults: defaults).isAvailable)
        availability.receive(countryCode: nil)
        #expect(!availability.isAvailable) // A missing answer must not erase the last known storefront.
        availability.receive(countryCode: "USA")
        #expect(availability.isAvailable)
        #expect(PublicLibraryAvailability(defaults: defaults).isAvailable)
    }

    @Test func refreshFollowsStorefrontOnlyOnceStarted() async throws {
        let suite = "PublicLibraryAvailabilityTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var storefront: String? = "USA"
        let availability = PublicLibraryAvailability(defaults: defaults) { storefront }
        // A country pinned before `start()` (UI tests' `-debug-storefront-country`)
        // survives the app becoming active.
        availability.receive(countryCode: "CHN")
        await availability.refresh()
        #expect(availability.countryCode == "CHN")

        availability.start()
        await availability.refresh()
        #expect(availability.countryCode == "USA")
        storefront = "CHN" // Changed in Settings while the app was away.
        await availability.refresh()
        #expect(!availability.isAvailable)
        storefront = nil // A transient missing answer keeps the last known country.
        await availability.refresh()
        #expect(availability.countryCode == "CHN")
    }
}
