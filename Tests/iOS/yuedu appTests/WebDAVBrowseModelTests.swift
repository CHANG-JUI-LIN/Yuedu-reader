import Foundation
import Testing
@testable import yuedu_app

/// Unified library, Phase 0c: a WebDAV folder's listing is owned by `WebDAVBrowseModel`,
/// not by `WebDAVDirectoryView`. The model keeps the view's previous behavior: a spinner
/// until the first answer, the error text of the failure, and nothing touched by a
/// cancelled or superseded load.
@MainActor
@Suite("WebDAV browse model", .serialized)
struct WebDAVBrowseModelTests {
    @Test("a listing fills the folder")
    func listingFillsTheFolder() async {
        let route = makeRoute("success")
        var requested: [URL] = []
        let model = WebDAVBrowseModel(route: route) { url in
            requested.append(url)
            return [entry("Fiction/", in: route, directory: true), entry("Three-Body.epub", in: route)]
        }
        #expect(model.isLoading)
        #expect(!model.didLoad)

        await model.load()

        #expect(requested == [route.url])
        #expect(model.entries.map(\.name) == ["Fiction/", "Three-Body.epub"])
        #expect(model.didLoad)
        #expect(!model.isLoading)
        #expect(model.loadError == nil)
    }

    @Test("a failure shows the error's text and is logged with the host")
    func failureShowsTheErrorAndLogs() async {
        let route = makeRoute("failure")
        let failure = URLError(.cannotConnectToHost)
        let model = WebDAVBrowseModel(route: route) { _ in throw failure }
        let logged = { failureLogCount(host: route.url.host ?? "") }
        let before = logged()

        await model.load()

        #expect(model.loadError == failure.localizedDescription)
        #expect(model.entries.isEmpty)
        #expect(!model.didLoad)
        #expect(!model.isLoading)
        #expect(logged() - before == 1)
    }

    @Test("a failure after a listing keeps the listing and shows the error")
    func failureAfterListingKeepsEntries() async {
        let route = makeRoute("fail-after")
        var fails = false
        let model = WebDAVBrowseModel(route: route) { _ in
            if fails { throw URLError(.timedOut) }
            return [entry("Three-Body.epub", in: route)]
        }
        await model.load()

        fails = true
        await model.load()

        #expect(model.entries.map(\.name) == ["Three-Body.epub"])
        #expect(model.loadError == URLError(.timedOut).localizedDescription)
    }

    @Test("a removed connection gives the existing message")
    func removedConnectionMessage() async {
        let model = WebDAVBrowseModel(route: makeRoute("removed"))

        await model.load()

        #expect(model.loadError == localized("書庫連線已移除，請重新加入伺服器。"))
        #expect(!model.isLoading)
        #expect(model.entries.isEmpty)
    }

    @Test("a reload replaces the listing")
    func reloadReplacesTheListing() async {
        let route = makeRoute("reload")
        var answer = [entry("Old.epub", in: route)]
        let model = WebDAVBrowseModel(route: route) { _ in answer }
        await model.load()

        answer = [entry("New.epub", in: route)]
        await model.load()

        #expect(model.entries.map(\.name) == ["New.epub"])
    }

    @Test("an earlier load that answers last does not overwrite a later one")
    func staleLoadIsIgnored() async throws {
        let route = makeRoute("stale")
        let gate = ListingGate()
        var calls = 0
        let model = WebDAVBrowseModel(route: route) { _ in
            calls += 1
            if calls == 1 { return try await gate.wait() }
            return [entry("Later.epub", in: route)]
        }

        let earlier = Task { await model.load() }
        try await waitUntil { gate.isWaiting }
        await model.load()
        gate.release([entry("Earlier.epub", in: route)])
        await earlier.value

        #expect(model.entries.map(\.name) == ["Later.epub"])
        #expect(!model.isLoading)
        #expect(model.loadError == nil)
    }

    @Test("a cancelled load sets no error and leaves the folder as it was")
    func cancelledLoadSetsNoError() async throws {
        let route = makeRoute("cancelled")
        let gate = ListingGate()
        let model = WebDAVBrowseModel(route: route) { _ in try await gate.wait() }

        let load = Task { await model.load() }
        try await waitUntil { gate.isWaiting }
        load.cancel()
        gate.release([entry("Ignored.epub", in: route)])
        await load.value

        #expect(model.loadError == nil)
        #expect(model.entries.isEmpty)
        #expect(!model.didLoad)
    }

    // MARK: - Helpers

    /// A connection id no store knows, on a host unique to the test.
    private func makeRoute(_ name: String) -> WebDAVDirectoryRoute {
        WebDAVDirectoryRoute(
            connectionID: "phase0-\(name)-\(UUID().uuidString)",
            url: URL(string: "https://\(name).phase0-webdav.test/books/")!,
            title: "Books"
        )
    }

    private func entry(_ name: String, in route: WebDAVDirectoryRoute, directory: Bool = false) -> WebDAVBrowseClient.Entry {
        WebDAVBrowseClient.Entry(url: route.url.appendingPathComponent(name), name: name, isDirectory: directory, size: 0)
    }

    private func failureLogCount(host: String) -> Int {
        DiagnosticLog.shared.snapshot().filter { $0.message.contains("WebDAV listing failed (\(host))") }.count
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("Timed out waiting for the listing to start")
    }
}

/// Holds one listing until the test releases it, so a test decides which load answers first.
@MainActor
private final class ListingGate {
    private var continuation: CheckedContinuation<[WebDAVBrowseClient.Entry], Never>?

    var isWaiting: Bool { continuation != nil }

    func wait() async throws -> [WebDAVBrowseClient.Entry] {
        await withCheckedContinuation { continuation = $0 }
    }

    func release(_ entries: [WebDAVBrowseClient.Entry]) {
        continuation?.resume(returning: entries)
        continuation = nil
    }
}
