import AppIntents
import Foundation

/// The pause / resume button in the offline-download Live Activity.
///
/// **This file is duplicated, deliberately**, exactly like `DownloadActivityAttributes` and for
/// the same reason: the two targets use file-system-synchronized folders, so one file cannot
/// belong to both without restructuring the project. The two copies must stay identical —
/// change one and you must change the other.
///
/// Staying identical is only possible because `perform()` does not touch the downloader: the
/// widget target does not compile `OfflineDownloadManager`. It records a request in the shared
/// container instead, and the app applies it. That indirection is not only a compile trick — it
/// is also what makes the button correct wherever the system decides to run it. `LiveActivityIntent`
/// is documented to run in the app's process, but a request that lands while the app is not
/// running is simply picked up on next launch rather than lost.
@available(iOS 17.0, *)
struct ToggleDownloadPauseIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "暫停或繼續下載"
    static var isDiscoverable: Bool { false }

    @Parameter(title: "書籍")
    var bookId: String

    init() {}

    init(bookId: String) {
        self.bookId = bookId
    }

    func perform() async throws -> some IntentResult {
        DownloadActivityCommandQueue.enqueueTogglePause(bookId: bookId)
        return .result()
    }
}

/// One-way channel from the Live Activity's button to the app.
///
/// A queue rather than a single slot: two taps before the app drains must not collapse into
/// one, or the button and the downloader end up disagreeing about whether it is paused.
enum DownloadActivityCommandQueue {
    /// Posted after a request is written, so an app already in the foreground reacts at once
    /// instead of waiting for its next lifecycle event.
    static let didChangeNotification = "com.zhangruilin.yuedureader.downloadActivityCommand"

    private static let defaultsKey = "download_activity_commands"

    /// The shared store both processes see. Injectable for the same reason
    /// `SharedImportQueueDrainer` makes it injectable: a queue that only exists as one
    /// process-wide singleton cannot be tested without two tests fighting over it.
    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: DownloadActivityAttributes.appGroupID)
    }

    static func enqueueTogglePause(bookId: String, defaults: UserDefaults? = sharedDefaults) {
        guard let defaults else { return }
        var pending = defaults.stringArray(forKey: defaultsKey) ?? []
        pending.append(bookId)
        defaults.set(pending, forKey: defaultsKey)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(didChangeNotification as CFString),
            nil,
            nil,
            true
        )
    }

    /// Returns every pending request and clears the queue. Draining is all-or-nothing on
    /// purpose: a request left behind would be replayed on the next drain and toggle twice.
    static func drain(defaults: UserDefaults? = sharedDefaults) -> [String] {
        guard let defaults else { return [] }
        let pending = defaults.stringArray(forKey: defaultsKey) ?? []
        guard !pending.isEmpty else { return [] }
        defaults.removeObject(forKey: defaultsKey)
        return pending
    }
}
