import Foundation
import os

/// The device-readable half of this app's diagnostics.
///
/// Everything already flowed to `os_log`, which is the right sink for a developer
/// with the phone plugged into a Mac and useless for the person actually hitting
/// the bug. This keeps a bounded copy on disk so 設定 → 診斷與回報 can show it, and
/// so the tail of a session survives the crash that ended it.
///
/// **Ownership.** `AppLogger` is the only thing that should call `record` for
/// ordinary lines — it is the single funnel every one of the app's log call sites
/// already passes through, so tapping it there costs no call-site changes.
/// `CrashContext` and `MetricKitDiagnosticReporter` call in directly because their
/// payloads (breadcrumbs, call-stack trees) are not `AppLogger` shaped.
///
/// **Re-entrancy.** This type must never log through `AppLogger`: `AppLogger` calls
/// `record`, so its own failures would recurse. Its private `Logger` below is
/// deliberate, not an oversight — leave it.
final class DiagnosticLog: @unchecked Sendable {

    static let shared = DiagnosticLog()

    // MARK: - Tuning

    /// Flush after this many buffered entries. Page turns emit several lines each,
    /// and a `write` per line would put file I/O on the reader's hot path.
    private static let flushThreshold = 64
    /// `current.jsonl` rotates once it passes this.
    private static let rotateBytes = 2 * 1024 * 1024
    /// How many lines `snapshot()` will decode. Well past what the screen can show;
    /// it exists so a pathological file cannot stall the page.
    private static let snapshotLimit = 6000
    /// Sessions kept in `sessions.json`.
    private static let sessionHistoryLimit = 10

    static let verboseDefaultsKey = "yd_diagnostics_verbose"

    // MARK: - State

    private let lock = NSLock()
    private var pending: [DiagnosticEntry] = []
    private var nextSequence: UInt64 = 0
    private var sessionReportableCount = 0
    private var cachedVerbose: Bool

    /// Serialises every filesystem touch. Directory resolution happens here too, so
    /// `record` never blocks a caller on disk.
    private let ioQueue = DispatchQueue(label: "com.yuedu.diagnosticLog", qos: .utility)
    /// Marks `ioQueue` so `record` can recognise a line that came from inside our
    /// own write path. See `isInsideWritePath`.
    private static let ioQueueKey = DispatchSpecificKey<Void>()

    /// This type's own failures. Never `AppLogger` — see the re-entrancy note above.
    private let selfLog = Logger(subsystem: "com.yuedu.app", category: "DiagnosticLog")

    private var session = DiagnosticSession.current()

    /// Set only by tests, which need their own directory so a test run neither reads
    /// nor destroys the real device log.
    private let directoryOverride: URL?

    init(directory: URL? = nil, verboseOverride: Bool? = nil) {
        directoryOverride = directory
        cachedVerbose = verboseOverride ?? UserDefaults.standard.bool(forKey: Self.verboseDefaultsKey)
        ioQueue.setSpecific(key: Self.ioQueueKey, value: ())
    }

    /// True when the caller is already inside our own file-writing path.
    ///
    /// Writing the log touches `StorageLocations`, and `StorageLocations` reports
    /// its failures through `AppLogger` — which calls straight back into `record`.
    /// Without this the first disk failure would ping-pong: each recursion buffers
    /// one more entry and schedules one more drain. Dropping those lines is the
    /// right trade: they describe the log failing to write itself, which is exactly
    /// what cannot be written down. `selfLog` still carries them to os_log.
    private var isInsideWritePath: Bool {
        DispatchQueue.getSpecific(key: Self.ioQueueKey) != nil
    }

    // MARK: - Verbose gate

    /// When off, `.trace` lines are dropped at the door. Everything `.info` and
    /// above is always kept: the point of the feature is that a user who hits a bug
    /// already has the evidence, without having been told to turn something on first.
    var isVerboseEnabled: Bool {
        get { lock.withLock { cachedVerbose } }
        set {
            lock.withLock { cachedVerbose = newValue }
            guard directoryOverride == nil else { return }
            UserDefaults.standard.set(newValue, forKey: Self.verboseDefaultsKey)
        }
    }

    /// Anomalies and faults seen since launch. Cheap — no disk read.
    var reportableCountThisSession: Int { lock.withLock { sessionReportableCount } }

    var currentSession: DiagnosticSession { lock.withLock { session } }

    // MARK: - Recording

    func record(
        severity: DiagnosticSeverity,
        category: DiagnosticCategory,
        message: String,
        detail: String? = nil
    ) {
        guard !isInsideWritePath else { return }

        var entry: DiagnosticEntry?
        var shouldFlushNow = false

        lock.withLock {
            guard severity > .trace || cachedVerbose else { return }

            let made = DiagnosticEntry(
                sequence: nextSequence,
                severity: severity,
                category: category,
                message: message,
                detail: detail
            )
            nextSequence += 1
            pending.append(made)
            entry = made

            if severity.isReportable { sessionReportableCount += 1 }
            // A fault or anomaly is often the last thing that happens before the
            // process dies, so it does not get to wait in the buffer.
            shouldFlushNow = severity.isReportable || pending.count >= Self.flushThreshold
        }

        guard entry != nil else { return }
        if shouldFlushNow { flush() }
    }

    /// Writes whatever is buffered. Safe to call from anywhere, including
    /// `willTerminate`, where `wait: true` makes it synchronous.
    func flush(wait: Bool = false) {
        let work: () -> Void = { [weak self] in self?.drainPending() }
        if wait {
            ioQueue.sync(execute: work)
        } else {
            ioQueue.async(execute: work)
        }
    }

    // MARK: - Session lifecycle

    /// Records this launch as in-progress. Called once at startup.
    func beginSession() {
        let started = lock.withLock { session }
        ioQueue.async { [weak self] in
            guard let self else { return }
            var history = self.readSessions()
            history.removeAll { $0.id == started.id }
            history.append(started)
            self.writeSessions(Array(history.suffix(Self.sessionHistoryLimit)))
        }
        record(
            severity: .info,
            category: .general,
            message: "session start \(started.appVersion) (\(started.build)) \(started.deviceModel) \(started.osVersion)"
        )
    }

    /// The app reached the background intact, so anything that kills it from here is
    /// the OS reclaiming a suspended process — not a crash the user experienced.
    ///
    /// Marking clean here rather than in `applicationWillTerminate` is deliberate:
    /// iOS almost never calls `willTerminate`, so keying off it would label every
    /// ordinary session a crash and the crash section would be pure noise.
    func noteEnteredBackground() {
        setSessionClean(true)
        flush()
    }

    /// Running in the foreground again. A death from here on is a real crash, so the
    /// session goes back to being unclean until it next reaches the background.
    func noteBecameActive() {
        setSessionClean(false)
    }

    private func setSessionClean(_ clean: Bool) {
        let updated: DiagnosticSession = lock.withLock {
            session.endedCleanly = clean
            return session
        }
        ioQueue.async { [weak self] in
            guard let self else { return }
            var history = self.readSessions()
            if let index = history.firstIndex(where: { $0.id == updated.id }) {
                history[index].endedCleanly = clean
            } else {
                history.append(updated)
            }
            self.writeSessions(Array(history.suffix(Self.sessionHistoryLimit)))
        }
    }

    /// Sessions from earlier launches that died while the user was looking at them.
    func uncleanPreviousSessions() -> [DiagnosticSession] {
        let currentID = lock.withLock { session.id }
        return ioQueue.sync {
            readSessions().filter { !$0.endedCleanly && $0.id != currentID }
        }
    }

    // MARK: - Reading

    /// Everything on disk plus anything still buffered, newest first.
    ///
    /// Flushes first so the caller always sees its own most recent lines — opening
    /// the screen right after hitting a bug is the whole use case.
    func snapshot() -> [DiagnosticEntry] {
        ioQueue.sync {
            drainPending()
            var entries = readEntries(from: previousFileURL)
            entries.append(contentsOf: readEntries(from: currentFileURL))
            if entries.count > Self.snapshotLimit {
                entries.removeFirst(entries.count - Self.snapshotLimit)
            }
            return entries.sorted { $0.sequence > $1.sequence }
        }
    }

    func clear() {
        lock.withLock {
            pending.removeAll()
            sessionReportableCount = 0
        }
        ioQueue.sync {
            for url in [currentFileURL, previousFileURL, sessionsFileURL] {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Bytes currently on disk, for 快取管理.
    func diskUsageBytes() -> Int64 {
        ioQueue.sync {
            [currentFileURL, previousFileURL, sessionsFileURL].reduce(into: Int64(0)) { total, url in
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                total += Int64(size)
            }
        }
    }

    // MARK: - Disk

    private var directoryURL: URL { directoryOverride ?? StorageLocations.diagnostics }
    private var currentFileURL: URL { directoryURL.appendingPathComponent("current.jsonl") }
    private var previousFileURL: URL { directoryURL.appendingPathComponent("previous.jsonl") }
    private var sessionsFileURL: URL { directoryURL.appendingPathComponent("sessions.json") }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Must only run on `ioQueue`.
    private func drainPending() {
        let batch: [DiagnosticEntry] = lock.withLock {
            defer { pending.removeAll(keepingCapacity: true) }
            return pending
        }
        guard !batch.isEmpty else { return }

        var blob = Data()
        for entry in batch {
            guard let line = try? Self.encoder.encode(entry) else { continue }
            blob.append(line)
            blob.append(0x0A)
        }
        guard !blob.isEmpty else { return }

        rotateIfNeeded()
        append(blob, to: currentFileURL)
    }

    private func append(_ data: Data, to url: URL) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else {
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                selfLog.error("could not create \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            return
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            selfLog.error("could not append to \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Two generations, so a crash never costs the whole history and the total on
    /// disk stays bounded at twice `rotateBytes`.
    private func rotateIfNeeded() {
        let size = (try? currentFileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size >= Self.rotateBytes else { return }
        let manager = FileManager.default
        try? manager.removeItem(at: previousFileURL)
        do {
            try manager.moveItem(at: currentFileURL, to: previousFileURL)
        } catch {
            selfLog.error("rotate failed: \(error.localizedDescription, privacy: .public)")
            try? manager.removeItem(at: currentFileURL)
        }
    }

    private func readEntries(from url: URL) -> [DiagnosticEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        var entries: [DiagnosticEntry] = []
        // A crash mid-append can leave a half-written final line. Decoding per line
        // and skipping what does not parse keeps the rest readable — the truncated
        // line is precisely the one least worth recovering.
        for line in data.split(separator: 0x0A) {
            guard let entry = try? Self.decoder.decode(DiagnosticEntry.self, from: Data(line)) else { continue }
            entries.append(entry)
        }
        return entries
    }

    private func readSessions() -> [DiagnosticSession] {
        guard let data = try? Data(contentsOf: sessionsFileURL),
              let sessions = try? Self.decoder.decode([DiagnosticSession].self, from: data)
        else { return [] }
        return sessions
    }

    private func writeSessions(_ sessions: [DiagnosticSession]) {
        guard let data = try? Self.encoder.encode(sessions) else { return }
        do {
            try data.write(to: sessionsFileURL, options: .atomic)
        } catch {
            selfLog.error("could not write sessions: \(error.localizedDescription, privacy: .public)")
        }
    }
}
