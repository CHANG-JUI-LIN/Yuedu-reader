import Foundation
import Testing
@testable import yuedu_app

/// Explicit release-check measurement, never part of an ordinary offline test run.
/// Run with TEST_RUNNER_PUBLIC_LIBRARY_LIVE_MEASURE=1 and select this struct.
@Suite("Public library release measurements", .serialized)
struct PublicLibraryMeasurementTests {
    private static var enabled: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["PUBLIC_LIBRARY_LIVE_MEASURE"] == "1"
            || environment["TEST_RUNNER_PUBLIC_LIBRARY_LIVE_MEASURE"] == "1"
    }

    @Test(.enabled(if: enabled))
    func rootAndFixtureCatalogColdThenWarm() async throws {
        let root = URL(string: PublicLibrary.gutenberg.url)!
        let http = RemoteLibraryHTTPClient(baseURL: root)
        let client = OPDSClient(httpClient: http)
        for phase in ["cold", "warm"] {
            let feed = try await SourcePerfTrace.spanAsync("publicLibrary.measure.root.\(phase)", thresholdMs: 0) {
                try await client.fetchFeed(root)
            }
            #expect(!feed.entries.isEmpty)
        }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/AozoraCatalog/works.json")
        let bytes = try Data(contentsOf: fixture)
        for phase in ["cold", "warm"] {
            let index = try await Task.detached {
                try SourcePerfTrace.span("publicLibrary.measure.catalog.\(phase)", "fixtureBytes=\(bytes.count)", thresholdMs: 0) {
                    try AozoraCatalogStore.decodeAndIndex(bytes)
                }
            }.value
            #expect(!index.worksByID.isEmpty)
        }
    }
}
