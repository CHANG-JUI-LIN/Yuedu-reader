import Foundation
import Testing
@testable import yuedu_app

/// The channel between the Live Activity's pause button and the app.
///
/// The button cannot call the downloader: its intent has to compile inside the widget
/// extension, which does not build `OfflineDownloadManager`. It records a request instead, and
/// the app applies it — so the queue's only real obligation is that a request is delivered
/// exactly once.
///
/// Each test gets its own `UserDefaults` suite. The real queue is a process-wide singleton in
/// the app group, and tests sharing it drained each other's requests when the suite ran twice
/// concurrently — the failure looked like a collapsed tap and was purely the test's doing.
@Suite("Download activity command queue")
struct DownloadActivityCommandQueueTests {

    @Test("a request survives until it is drained, then is gone")
    func requestIsDeliveredExactlyOnce() throws {
        let defaults = try isolatedDefaults()
        let bookId = UUID().uuidString

        DownloadActivityCommandQueue.enqueueTogglePause(bookId: bookId, defaults: defaults)

        #expect(DownloadActivityCommandQueue.drain(defaults: defaults) == [bookId])
        // Draining twice must not replay it: the second toggle would undo the first.
        #expect(DownloadActivityCommandQueue.drain(defaults: defaults).isEmpty)
    }

    @Test("two taps before a drain stay two requests")
    func tapsDoNotCollapse() throws {
        let defaults = try isolatedDefaults()
        let bookId = UUID().uuidString

        DownloadActivityCommandQueue.enqueueTogglePause(bookId: bookId, defaults: defaults)
        DownloadActivityCommandQueue.enqueueTogglePause(bookId: bookId, defaults: defaults)

        // Collapsing them would leave the button and the downloader disagreeing about whether
        // the download is paused.
        #expect(DownloadActivityCommandQueue.drain(defaults: defaults) == [bookId, bookId])
    }

    @Test("draining an empty queue is not an error")
    func emptyDrainIsHarmless() throws {
        let defaults = try isolatedDefaults()
        #expect(DownloadActivityCommandQueue.drain(defaults: defaults).isEmpty)
    }

    @Test("the shipping queue really does point at the shared container")
    func productionQueueUsesTheAppGroup() {
        // The isolated suites above prove the logic; this proves the default argument is not
        // quietly nil, which would make the button a no-op in the real app.
        #expect(DownloadActivityCommandQueue.sharedDefaults != nil)
    }

    private func isolatedDefaults() throws -> UserDefaults {
        let suiteName = "DownloadActivityCommandQueueTests.\(UUID().uuidString)"
        return try #require(UserDefaults(suiteName: suiteName))
    }
}
