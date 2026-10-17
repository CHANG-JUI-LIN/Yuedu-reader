import Foundation

/// Sends the diagnostic log to the developer, at the user's request, and returns a report
/// number the user can quote.
///
/// The export (`DiagnosticReportBundle` through a share sheet) only helps when the person who
/// hit the problem knows where to send a file, and an App Store user has no TestFlight-style
/// channel. This sends the same redacted text through the Gateway to Firestore
/// `diagnosticReports/{id}` — create-only, nothing readable back (see `firestore.rules` and
/// `gateway/src/feedbackPolicy.ts`) — compressed, with the install's scale and identifiers
/// beside it, and ties it to this install's Crashlytics reports through the install id
/// (`CrashContext.installID`), so one number leads to the user's hangs and crashes as well.
/// Through the Gateway, like the rest of 回饋中心, because Firestore is unreachable from the
/// mainland.
///
/// Fetch a report: `python3 scripts/decode_diagnostic_report.py <report-id>` (see the script).
enum DiagnosticReportUploader {
    struct Receipt: Sendable, Equatable {
        let reportID: String
        let uploadedBytes: Int
        let keptEntries: Int
        let totalEntries: Int
    }

    enum UploadError: LocalizedError {
        case compressionFailed(Error)
        /// The Gateway refused or could not be reached; reads as 回饋中心's two sentences.
        case relay(GatewayAPIError)

        var errorDescription: String? {
            switch self {
            case .compressionFailed: localized("紀錄無法壓縮。")
            case .relay(let error): FeedbackService.userMessage(for: error)
            }
        }
    }

    /// Firestore caps a document at 1 MiB; the payload leaves room for the other fields.
    static let payloadLimit = 900_000
    static let noteLimit = 2_000

    /// Renders, compresses and writes the report. Rendering several thousand lines is real
    /// work, so it runs off the main thread; the caller awaits the result.
    static func upload(_ bundle: DiagnosticReportBundle, note: String) async throws -> Receipt {
        let reportID = makeReportID()
        let prepared = try await Task.detached(priority: .userInitiated) {
            try preparePayload(bundle, reportID: reportID)
        }.value

        let info = Bundle.main.infoDictionary
        let report = ReportBody(
            reportId: reportID,
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "",
            build: info?["CFBundleVersion"] as? String ?? "",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            device: deviceModel(),
            locale: Locale.current.identifier,
            installId: CrashContext.installID,
            scale: DiagnosticScale.lastSummary,
            note: String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(noteLimit)),
            payload: prepared.compressed.base64EncodedString(),
            payloadBytes: prepared.uncompressedBytes,
            payloadEncoding: "deflate-utf8",
            keptEntries: prepared.keptEntries,
            totalEntries: bundle.entries.count
        )
        do {
            try await GatewayAPIClient.shared.sendVoid(
                try GatewayRequest(method: "POST", path: "/v1/diagnostics/reports").jsonBody(report)
            )
        } catch let error as GatewayAPIError {
            throw UploadError.relay(error)
        }

        if let highest = bundle.entries.map(\.sequence).max() {
            DiagnosticLog.shared.acknowledgeReported(through: highest)
        }
        CrashContext.setKey("last_report_id", reportID)
        CrashContext.breadcrumb("diagnostic report \(reportID) sent (\(prepared.compressed.count) bytes)")
        return Receipt(
            reportID: reportID,
            uploadedBytes: prepared.compressed.count,
            keptEntries: prepared.keptEntries,
            totalEntries: bundle.entries.count
        )
    }

    /// What `POST /v1/diagnostics/reports` takes; the Gateway stores `payload` as Bytes.
    private struct ReportBody: Encodable {
        let reportId: String
        let appVersion: String
        let build: String
        let osVersion: String
        let device: String
        let locale: String
        let installId: String
        let scale: String
        let note: String
        let payload: String
        let payloadBytes: Int
        let payloadEncoding: String
        let keptEntries: Int
        let totalEntries: Int
    }

    struct Prepared: Sendable {
        let compressed: Data
        let uncompressedBytes: Int
        let keptEntries: Int
    }

    /// Keeps the newest entries that fit: a log too large for one document loses its oldest
    /// half until it fits, and says so in its first line.
    static func preparePayload(_ bundle: DiagnosticReportBundle, reportID: String) throws -> Prepared {
        // Newest first, as `DiagnosticLog.snapshot()` returns them.
        var entries = bundle.entries
        while true {
            var trimmed = DiagnosticReportBundle(
                filename: bundle.filename, entries: entries, session: bundle.session,
                uncleanSessions: bundle.uncleanSessions
            )
            trimmed.acknowledgesReport = false
            var text = "report \(reportID) · entries \(entries.count) of \(bundle.entries.count)\n"
            text += trimmed.render()
            let raw = Data(text.utf8)
            let compressed: Data
            do {
                compressed = try (raw as NSData).compressed(using: .zlib) as Data
            } catch {
                throw UploadError.compressionFailed(error)
            }
            if compressed.count <= payloadLimit || entries.count <= 1 {
                return Prepared(compressed: compressed, uncompressedBytes: raw.count, keptEntries: entries.count)
            }
            entries = Array(entries.prefix(entries.count / 2))
        }
    }

    /// `YD-` plus eight characters from an alphabet without look-alikes (no 0/O, 1/I/L).
    static func makeReportID() -> String {
        let alphabet = Array("23456789ABCDEFGHJKMNPQRSTUVWXYZ")
        let body = (0..<8).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] }
        return "YD-\(String(body.prefix(4)))-\(String(body.suffix(4)))"
    }

    private static func deviceModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
