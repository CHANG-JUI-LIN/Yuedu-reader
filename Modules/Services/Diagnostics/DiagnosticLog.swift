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
    /// Trace lines held in memory for the flight recorder. A page turn emits six to
    /// ten, so this is thirty-odd turns of run-up — enough to see what led to a bug
    /// without the ring itself becoming the thing that has to be paged through.
    /// ~300 x ~200 bytes = ~60 KB resident.
    private static let flightRecorderCapacity = 300

    static let verboseDefaultsKey = "yd_diagnostics_verbose"
    /// Highest sequence the user has already taken away (exported or copied).
    private static let acknowledgedKey = "yd_diagnostics_acknowledged_sequence"

    // MARK: - State

    private let lock = NSLock()
    private var pending: [DiagnosticEntry] = []
    private var nextSequence: UInt64 = 0
    private var sessionReportableCount = 0
    private var cachedVerbose: Bool

    /// Exactly what the verbose gate would otherwise have thrown away, kept in a
    /// fixed ring and attached to the next reportable entry.
    ///
    /// The reader's whole diagnostic narration — `[FlipTrace]`, `[FetchTrace]`, the
    /// 162 `ttsLog` lines — is `.trace`, so with verbose off a user who hit "翻頁卡在
    /// 載入中" exported a log containing the anomaly and nothing that explained it.
    /// Turning all of it on instead would burn the export's 6000-line window on page
    /// turns and rotate the anomaly away. So it is recorded, and released only when
    /// something worth reporting happens.
    ///
    /// Empty whenever verbose is on: nothing is being dropped then, the lines are
    /// already on disk in sequence, and duplicating them into a detail block would
    /// only make the export longer.
    private struct FlightEntry {
        let timestamp: Date
        let severity: DiagnosticSeverity
        let category: DiagnosticCategory
        let message: String
    }
    private var flightRing: [FlightEntry?]
    private var flightWriteIndex = 0
    private var flightCount = 0

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

    /// Everything at or below this has already been reported, so it no longer counts
    /// toward the banner. Persisted: a report the user has sent should not come back
    /// the next time they open the app.
    private var acknowledgedSequence: UInt64

    init(directory: URL? = nil, verboseOverride: Bool? = nil) {
        directoryOverride = directory
        flightRing = Array(repeating: nil, count: Self.flightRecorderCapacity)
        cachedVerbose = verboseOverride ?? UserDefaults.standard.bool(forKey: Self.verboseDefaultsKey)
        // A test instance starts with a clean slate rather than inheriting the device's.
        acknowledgedSequence = directory == nil
            ? UInt64(max(0, UserDefaults.standard.integer(forKey: Self.acknowledgedKey)))
            : 0
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

    // MARK: - Flight recorder
    //
    // Both of these must be called with `lock` already held: `NSLock` is not
    // recursive, and `record` does its whole decision inside one `withLock`.

    /// Writes one dropped line into the ring, overwriting the oldest once full.
    private func appendFlightLocked(_ entry: FlightEntry) {
        flightRing[flightWriteIndex] = entry
        flightWriteIndex = (flightWriteIndex + 1) % Self.flightRecorderCapacity
        flightCount = min(flightCount + 1, Self.flightRecorderCapacity)
    }

    /// The caller's own detail, followed by everything the ring holds, oldest first.
    ///
    /// Drains the ring: a run of anomalies during one stuck chapter would otherwise
    /// carry the same narration several times over, and the first one already has it.
    private func detailWithFlightRecorderLocked(_ detail: String?) -> String? {
        guard flightCount > 0 else { return detail }

        let start = (flightWriteIndex - flightCount + Self.flightRecorderCapacity)
            % Self.flightRecorderCapacity
        var lines: [String] = []
        lines.reserveCapacity(flightCount + 2)
        lines.append("--- flight recorder (\(flightCount) lines, oldest first) ---")
        for step in 0..<flightCount {
            let slot = (start + step) % Self.flightRecorderCapacity
            guard let entry = flightRing[slot] else { continue }
            lines.append(
                "\(Self.flightFormatter.string(from: entry.timestamp)) "
                + "\(entry.severity.exportTag) [\(entry.category.rawValue)] \(entry.message)"
            )
        }

        flightRing = Array(repeating: nil, count: Self.flightRecorderCapacity)
        flightWriteIndex = 0
        flightCount = 0

        let body = lines.joined(separator: "\n")
        guard let detail, !detail.isEmpty else { return body }
        return detail + "\n\n" + body
    }

    /// Matches `DiagnosticReportBundle`'s line format so the ring reads like the rest
    /// of the export rather than like a foreign blob pasted into it.
    private static let flightFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    /// Lines currently held but not yet attached to anything. For tests.
    var flightRecorderCount: Int { lock.withLock { flightCount } }

    /// Anomalies and faults seen since launch. Cheap — no disk read.
    var reportableCountThisSession: Int { lock.withLock { sessionReportableCount } }

    /// True for an entry the user has not already taken away in an export or a copy.
    /// The banner counts these, so sending a report silences it until something new
    /// happens.
    func isUnreported(_ entry: DiagnosticEntry) -> Bool {
        guard entry.severity.isReportable else { return false }
        return entry.sequence > lock.withLock { acknowledgedSequence }
    }

    /// Marks everything up to `sequence` as reported. Called when the log leaves the
    /// device — a `ShareLink` export or a copy to the clipboard.
    func acknowledgeReported(through sequence: UInt64) {
        let changed: Bool = lock.withLock {
            guard sequence > acknowledgedSequence else { return false }
            acknowledgedSequence = sequence
            return true
        }
        guard changed else { return }
        // The banner is computed from this, so it has to hear about the change. An
        // event, not a poll: the share sheet does not background the app, so there is
        // no lifecycle callback to hang the refresh on.
        NotificationCenter.default.post(name: Self.didAcknowledgeReported, object: nil)
        guard directoryOverride == nil else { return }
        UserDefaults.standard.set(Int(sequence), forKey: Self.acknowledgedKey)
    }

    /// Posted when the log has been exported or copied, so any open view can drop the
    /// "please report this" prompt.
    static let didAcknowledgeReported = Notification.Name("DiagnosticLog.didAcknowledgeReported")

    /// Clearing the log clears what was acknowledged too: there is nothing left to have
    /// reported, and a stale high-water mark would hide the next real anomaly.
    private func resetAcknowledged() {
        lock.withLock { acknowledgedSequence = 0 }
        guard directoryOverride == nil else { return }
        UserDefaults.standard.removeObject(forKey: Self.acknowledgedKey)
    }

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
            guard severity > .trace || cachedVerbose else {
                // Not discarded — held for whatever goes wrong next. See `flightRing`.
                appendFlightLocked(
                    FlightEntry(
                        timestamp: Date(),
                        severity: severity,
                        category: category,
                        message: message
                    )
                )
                return
            }

            let made = DiagnosticEntry(
                sequence: nextSequence,
                severity: severity,
                category: category,
                message: message,
                // An anomaly carries its own run-up, so the exported entry explains
                // itself without the reader having to reconstruct it from lines that
                // were never written down.
                detail: severity.isReportable ? detailWithFlightRecorderLocked(detail) : detail
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
            flightRing = Array(repeating: nil, count: Self.flightRecorderCapacity)
            flightWriteIndex = 0
            flightCount = 0
        }
        resetAcknowledged()
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
