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

    @Test func runningUpdates() async throws {
        let suite = "PublicLibraryAvailabilityTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let availability = PublicLibraryAvailability(defaults: defaults)
        let updates = AsyncStream<String> { continuation in
            continuation.yield("CHN")
            continuation.finish()
        }
        await availability.observe(updates)
        #expect(!availability.isAvailable)
    }
}
