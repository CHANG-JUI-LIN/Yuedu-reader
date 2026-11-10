import BackgroundTasks
import Foundation
import UIKit

/// Keeps a 書源檢查 going once the app leaves the foreground, and ends it cleanly when it
/// cannot go on.
///
/// Legado runs its check in an Android foreground service, which carries it through any
/// amount of time in the background. iOS has two things short of that:
/// - A `UIApplication` background task: about 30 seconds after the app leaves the foreground.
/// - From iOS 26, a `BGContinuedProcessingTask` the user started from the foreground: the run
///   goes on with the system's own progress display, for as long as the system allows.
///
/// Whichever ends first, the run ends as 停止 does — the sources finished so far are written,
/// the ones in flight write nothing. The alternative is worse: a suspended app's in-flight
/// sources would sit frozen and, the moment it came back, fail their timeout, so a 校验超时
/// would be written onto every source that happened to be in flight.
@MainActor
final class BookSourceCheckBackgroundTask {
    static let shared = BookSourceCheckBackgroundTask()

    /// `BGTaskSchedulerPermittedIdentifiers` holds the wildcard form, `<bundle id>.sourceCheck.*`.
    private static let identifierPrefix = Bundle.main.bundleIdentifier.map { $0 + ".sourceCheck" }

    private var assertion: UIBackgroundTaskIdentifier = .invalid
    private var onExpire: (@MainActor () -> Void)?
    private var total = 0
    private var finished = 0
    /// The continued-processing request submitted for the run in progress.
    private var requestIdentifier: String?
    /// That request's `BGContinuedProcessingTask`, once the system started it.
    private var continuedTask: BGTask?
    private var lastSubtitleUpdate: TimeInterval = 0
    private var registrationAttempted = false
    private var isRegistered = false

    private init() {}

    /// - Parameter onExpire: ends the run; called when iOS is about to stop the app running.
    func runStarted(total: Int, onExpire: @escaping @MainActor () -> Void) {
        runEnded()
        self.total = total
        finished = 0
        self.onExpire = onExpire
        assertion = UIApplication.shared.beginBackgroundTask(withName: "Source Check") { [weak self] in
            self?.assertionExpired()
        }
        if #available(iOS 26.0, *) {
            submitContinuedProcessing()
        }
    }

    func progress(finished: Int) {
        self.finished = finished
        guard #available(iOS 26.0, *),
              let task = continuedTask as? BGContinuedProcessingTask else { return }
        task.progress.completedUnitCount = Int64(finished)
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastSubtitleUpdate >= 1 || finished == total else { return }
        lastSubtitleUpdate = now
        task.updateTitle(task.title, subtitle: subtitle)
    }

    /// The run finished or was stopped. Safe to call more than once.
    func runEnded() {
        onExpire = nil
        if assertion != .invalid {
            UIApplication.shared.endBackgroundTask(assertion)
            assertion = .invalid
        }
        if let task = continuedTask {
            continuedTask = nil
            task.setTaskCompleted(success: true)
        } else if let identifier = requestIdentifier {
            // Submitted, not yet started: withdraw it.
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        }
        requestIdentifier = nil
    }

    private var subtitle: String {
        String(format: localized("已驗證 %1$d／%2$d"), finished, total)
    }

    private func assertionExpired() {
        let identifier = assertion
        assertion = .invalid
        if continuedTask != nil {
            AppLogger.network("source check: background grace ended; continued processing carries the run")
        } else {
            AppLogger.network("source check: background time expired; stopping", context: [
                "finished": finished, "total": total,
            ], level: .warning)
            expire()
        }
        if identifier != .invalid {
            UIApplication.shared.endBackgroundTask(identifier)
        }
    }

    private func expire() {
        let handler = onExpire
        onExpire = nil
        handler?()
    }

    // MARK: - iOS 26 continued processing

    @available(iOS 26.0, *)
    private func submitContinuedProcessing() {
        guard registerIfNeeded(), let prefix = Self.identifierPrefix else { return }
        let identifier = prefix + "." + UUID().uuidString
        requestIdentifier = identifier
        let title = localized("來源配置驗證")
        let subtitle = subtitle
        // `submit(_:)` is deprecated from iOS 27 in favour of the asynchronous form, which is
        // not to be called on the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            let request = BGContinuedProcessingTaskRequest(
                identifier: identifier, title: title, subtitle: subtitle
            )
            // Start now or not at all: a request queued behind others would start after the
            // user is long back, and the background task's grace covers the gap either way.
            request.strategy = .fail
            if #available(iOS 27.0, *) {
                BGTaskScheduler.shared.submitTaskRequest(request) { error in
                    guard let error else { return }
                    Task { @MainActor in self.submissionFailed(identifier, error) }
                }
            } else {
                do {
                    try BGTaskScheduler.shared.submit(request)
                } catch {
                    Task { @MainActor in self.submissionFailed(identifier, error) }
                }
            }
        }
    }

    /// Once per process: a second registration of the identifier ends the app.
    @available(iOS 26.0, *)
    private func registerIfNeeded() -> Bool {
        if registrationAttempted { return isRegistered }
        registrationAttempted = true
        guard let prefix = Self.identifierPrefix else {
            AppLogger.network("source check: no bundle identifier for continued processing", level: .error)
            return false
        }
        isRegistered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: prefix + ".*",
            using: .main
        ) { [weak self] task in
            // Delivered on the main queue, as registered.
            MainActor.assumeIsolated { self?.continuedTaskStarted(task) }
        }
        if !isRegistered {
            AppLogger.network("source check: continued processing identifier not permitted", context: [
                "identifier": prefix + ".*",
            ], level: .error)
        }
        return isRegistered
    }

    @available(iOS 26.0, *)
    private func continuedTaskStarted(_ task: BGTask) {
        guard let task = task as? BGContinuedProcessingTask, task.identifier == requestIdentifier else {
            // Its run ended before the system started it.
            task.setTaskCompleted(success: true)
            return
        }
        continuedTask = task
        task.progress.totalUnitCount = Int64(total)
        task.progress.completedUnitCount = Int64(finished)
        task.expirationHandler = { [weak self] in
            Task { @MainActor in self?.continuedTaskExpired() }
        }
    }

    private func continuedTaskExpired() {
        guard let task = continuedTask else { return }
        continuedTask = nil
        requestIdentifier = nil
        if UIApplication.shared.applicationState == .active {
            // Back in front: the run needs no background time.
            AppLogger.network("source check: continued processing ended while in the foreground")
        } else {
            AppLogger.network("source check: continued processing expired; stopping", context: [
                "finished": finished, "total": total,
            ], level: .warning)
            expire()
        }
        task.setTaskCompleted(success: false)
    }

    private func submissionFailed(_ identifier: String, _ error: Error) {
        // The system declined (busy, or background work turned off for the app): the run keeps
        // the background task's grace only.
        AppLogger.network("source check: continued processing not started", context: [
            "error": error.localizedDescription,
        ], level: .warning)
        if requestIdentifier == identifier {
            requestIdentifier = nil
        }
    }
}
