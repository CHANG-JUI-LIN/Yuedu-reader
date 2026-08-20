import Foundation
import UIKit

/// Holds one `UIApplication` background-task assertion for as long as any offline download is
/// running, and gives the downloader a chance to stop cleanly when iOS reclaims it.
///
/// **This is not background downloading.** iOS has no equivalent of the Android foreground
/// service legado's `CacheBookService` relies on. The only API that survives suspension — a
/// background `URLSession` — hands back a file and a few seconds of runtime, which cannot
/// carry the work a chapter actually needs (fetch → parse → cache-write → verify → commit),
/// let alone the `WKWebView` that sources declaring `webJs` or `{"webView": true}` require and
/// that WebKit refuses to run while the app is suspended.
///
/// What the assertion buys is the difference between *stopping* and *being frozen*. Without
/// it the download's tasks are suspended wherever they happen to be, and the metadata write
/// that records their progress may never run; the next foreground reconcile then has to
/// reconstruct a half-written state. With it, the expiry handler pauses the queue and the
/// store flushes, so returning to the foreground resumes from a point that was written down.
@MainActor
final class OfflineDownloadBackgroundTask {
    static let shared = OfflineDownloadBackgroundTask()

    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private var holders = 0

    /// Invoked just before iOS reclaims the assertion. The downloader pauses its running
    /// books here; the assertion is released immediately afterwards regardless.
    var onExpiration: (() -> Void)?

    private init() {}

    /// Balanced with `release()`. Nested acquires share one assertion — several books
    /// download concurrently and each would otherwise take its own.
    func acquire() {
        holders += 1
        guard identifier == .invalid else { return }
        identifier = UIApplication.shared.beginBackgroundTask(
            withName: "Offline Book Download"
        ) { [weak self] in
            guard let self else { return }
            AppLogger.cache("⟐ offline download background time expired")
            self.onExpiration?()
            self.endAssertion()
        }
        AppLogger.cache("⟐ offline download background task started", context: [
            "id": identifier.rawValue,
        ])
    }

    func release() {
        holders = max(0, holders - 1)
        guard holders == 0 else { return }
        endAssertion()
    }

    private func endAssertion() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        AppLogger.cache("⟐ offline download background task ended", context: [
            "id": identifier.rawValue,
        ])
        identifier = .invalid
        holders = 0
    }
}
