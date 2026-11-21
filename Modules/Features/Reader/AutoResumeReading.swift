import Combine
import UIKit

/// 閱讀設定 › 自動接續閱讀: a cold launch goes straight back into the book that was being
/// read when the app was last left.
///
/// The book is written down when the app leaves the foreground, not when its reader opens,
/// and a launch takes the note away before acting on it. A book whose reader never survived
/// to that moment is therefore never reopened by itself: one that crashes as it opens
/// cannot hold every later launch.
///
/// Kept on this device only (`UserDefaults`): what another device was reading says nothing
/// about what this one was showing.
@MainActor
final class AutoResumeReading: ObservableObject {
    static let shared = AutoResumeReading()

    /// The reader a launch asks for, shown by `ImportedBookPresentation` above whichever
    /// tab the app opens on (the shelf is not always one of them).
    @Published private(set) var request: SharedImportQueueDrainer.ReaderRequest?

    private static let bookKey = "yd_auto_resume_reading_book"
    private let defaults: UserDefaults
    /// Readers on screen, the one opened last at the end: one can be shown above another
    /// (a file handed to the app while a book is open), and closing it leaves the other.
    private var readersOnScreen: [UUID] = []
    private var handledLaunch = false
    private var leaveObservers: [NSObjectProtocol] = []

    init(defaults: UserDefaults = .standard, notificationCenter: NotificationCenter? = .default) {
        self.defaults = defaults
        guard let notificationCenter else { return }
        // Resigning active as well as entering the background: an app flicked away in the
        // app switcher, or killed right after Home, is gone before the second one arrives
        // (simulator, 2026-11-21: terminated straight after Home, nothing had been written).
        leaveObservers = [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification].map {
            notificationCenter.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.appLeftForeground() }
            }
        }
    }

    /// A reader is on screen (`BookReaderView`), whichever page opened it.
    func readerAppeared(bookID: UUID) {
        readersOnScreen.removeAll { $0 == bookID }
        readersOnScreen.append(bookID)
    }

    /// That reader left the screen: closed, or covered by a page pushed above it.
    func readerDisappeared(bookID: UUID) {
        readersOnScreen.removeAll { $0 == bookID }
    }

    func appLeftForeground() {
        AppLogger.info("⟐ autoResume: left the foreground, reader on screen=\(readersOnScreen.last?.uuidString ?? "none")")
        if let frontmost = readersOnScreen.last {
            defaults.set(frontmost.uuidString, forKey: Self.bookKey)
        } else {
            defaults.removeObject(forKey: Self.bookKey)
        }
    }

    /// Once per process, when the launch has nothing left to show first.
    func resumeAtLaunch(isEnabled: Bool, bookExists: (UUID) -> Bool) {
        guard !handledLaunch else { return }
        handledLaunch = true
        let stored = defaults.string(forKey: Self.bookKey).flatMap(UUID.init(uuidString:))
        defaults.removeObject(forKey: Self.bookKey)
        AppLogger.info("⟐ autoResume: launch, enabled=\(isEnabled) book=\(stored?.uuidString ?? "none")")
        guard isEnabled, let stored else { return }
        guard bookExists(stored) else {
            AppLogger.info("⟐ autoResume: book \(stored) is no longer in the library; staying on the launch screen")
            return
        }
        AppLogger.info("⟐ autoResume: reopening book \(stored)")
        request = SharedImportQueueDrainer.ReaderRequest(bookID: stored)
    }

    func didPresent(requestID: UUID) {
        if request?.id == requestID { request = nil }
    }

    /// Something else opened a reader first (a file handed to the app at launch).
    func cancel() {
        request = nil
    }
}
