import Foundation
import UIKit

/// 回饋中心's one service: sends reports and replies, uploads their attachments, and
/// keeps the inbox current. Views make one call each; everything that talks to the
/// backend is here.
///
/// Every call goes through the Gateway (`gateway/src/routes/feedback.ts`), never straight
/// to Firestore or Storage: those hosts are unreachable from the mainland, and one path
/// for everyone is simpler than choosing per network. The Gateway writes the same
/// `feedbackInboxes/{inbox}` documents and `feedback/{inbox}/…` objects firestore.rules and
/// storage.rules describe, so the developer side — `onFeedbackThreadCreated`, the AI 助手's
/// first reply, functions/tools/feedback.ts — is unchanged.
@MainActor
final class FeedbackService {
    static let shared = FeedbackService()

    enum FeedbackError: LocalizedError {
        case emptyReport
        case attachmentTooLarge
        case attachmentUnreadable

        var errorDescription: String? {
            switch self {
            case .emptyReport: localized("請先描述問題或建議。")
            case .attachmentTooLarge: localized("影片超過 50 MB，請剪短後再試。")
            case .attachmentUnreadable: localized("無法讀取這個附件。")
            }
        }
    }

    /// What a failed call says on screen. The Gateway's own error text is English and
    /// technical, so its errors read as one of two localized sentences; the caller logs
    /// the original. Other errors — ours, or the system's while preparing an attachment —
    /// are already localized and pass through.
    nonisolated static func userMessage(for error: Error) -> String {
        if let error = error as? GatewayAPIError {
            switch error {
            case .notConfigured:
                return localized("回報服務目前無法使用。")
            case _ where error.isConnectivityFailure:
                return localized("無法連線到回報服務，請檢查網路後再試。")
            default:
                return localized("回報服務暫時出了問題，請稍後再試。")
            }
        }
        if (error as NSError).domain == NSURLErrorDomain {
            return localized("無法連線到回報服務，請檢查網路後再試。")
        }
        return error.localizedDescription
    }

    /// What a submit is doing, for the form's progress line.
    enum SubmitStage: Equatable {
        case uploadingAttachment(Int, of: Int)
        case uploadingLog
        case sending
    }

    /// How often an open 我的回饋 or conversation asks for news. A screen refresh
    /// cadence, the Gateway's stand-in for Firestore's live listener — not a wait for
    /// state to settle. Own writes and returning to the foreground refresh at once.
    static let refreshInterval: Duration = .seconds(30)

    private let client: GatewayAPIClient
    private let inboxKey: () -> String
    private let imageCache = NSCache<NSString, UIImage>()
    /// One wake-up per open stream; poked by own writes and by the app coming back.
    private var wakeups: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var foregroundObserver: NSObjectProtocol?

    init(client: GatewayAPIClient = .shared, inboxKey: @escaping () -> String = { FeedbackInbox.key }) {
        self.client = client
        self.inboxKey = inboxKey
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshOpenStreams() }
        }
    }

    // MARK: - Requests

    /// The inbox key rides in Authorization, never in a URL: access logs keep URLs, and
    /// the Gateway's proxy redacts Authorization.
    private func request(_ method: String, _ path: String, query: [URLQueryItem] = []) -> GatewayRequest {
        var request = GatewayRequest(method: method, path: "/v1/feedback" + path, query: query)
        request.headers["Authorization"] = "Inbox \(inboxKey())"
        return request
    }

    private func json(_ request: GatewayRequest) async throws -> [String: Any] {
        let data = try await client.sendForData(request)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            AppLogger.network("Feedback response is not a JSON object", context: ["path": request.path])
            throw GatewayAPIError.invalidResponse
        }
        return object
    }

    // MARK: - Sending

    /// Sends a new report: attachments first, the diagnostic log (when included) to
    /// `diagnosticReports`, then the thread and its first message, which the Gateway
    /// writes in one batch so the first-reply function always finds the message.
    /// Returns the new thread's id.
    func submit(
        kind: FeedbackKind,
        text: String,
        attachments: [FeedbackDraftAttachment],
        diagnostics: DiagnosticReportBundle?,
        deviceInfo: FeedbackDeviceInfo,
        progress: (SubmitStage) -> Void
    ) async throws -> String {
        let body = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(FeedbackFirestoreSchema.textLimit))
        guard !body.isEmpty else { throw FeedbackError.emptyReport }

        let threadID = UUID().uuidString.lowercased()
        let uploaded = try await upload(attachments, threadID: threadID, progress: progress)

        var reportID = ""
        if let diagnostics {
            progress(.uploadingLog)
            reportID = try await DiagnosticReportUploader.upload(
                diagnostics,
                note: "\(kind.rawValue) feedback \(threadID)"
            ).reportID
        }

        progress(.sending)
        let info = Bundle.main.infoDictionary
        let report = NewThreadBody(
            threadId: threadID,
            kind: kind.rawValue,
            title: FeedbackFirestoreSchema.provisionalTitle(of: body),
            preview: FeedbackFirestoreSchema.preview(of: body),
            text: body,
            attachments: uploaded.map(AttachmentBody.init),
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "",
            build: info?["CFBundleVersion"] as? String ?? "",
            osVersion: "iOS \(UIDevice.current.systemVersion)",
            device: deviceInfo.modelIdentifier,
            locale: Locale.preferredLanguages.first ?? Locale.current.identifier,
            installId: CrashContext.installID,
            diagnosticReportId: reportID,
            deviceInfo: deviceInfo.fields
        )
        try await client.sendVoid(try request("POST", "/threads").jsonBody(report))
        CrashContext.breadcrumb("feedback \(threadID) sent (\(uploaded.count) attachments, log \(reportID))")
        refreshOpenStreams()
        FeedbackPushRegistration.shared.inboxInUse()
        return threadID
    }

    /// A follow-up in an existing thread. Answering a 待補充 request puts the thread
    /// back in the queue; the Gateway decides that from the stored status.
    func reply(to thread: FeedbackThread, text: String, attachments: [FeedbackDraftAttachment]) async throws {
        let body = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(FeedbackFirestoreSchema.textLimit))
        guard !body.isEmpty || !attachments.isEmpty else { throw FeedbackError.emptyReport }
        let uploaded = try await upload(attachments, threadID: thread.id, progress: { _ in })
        let reply = ReplyBody(
            text: body,
            preview: body.isEmpty ? localized("〔附件〕") : FeedbackFirestoreSchema.preview(of: body),
            attachments: uploaded.map(AttachmentBody.init)
        )
        try await client.sendVoid(try request("POST", "/threads/\(thread.id)/messages").jsonBody(reply))
        refreshOpenStreams()
    }

    func markResolved(_ thread: FeedbackThread) async throws {
        try await client.sendVoid(try request("POST", "/threads/\(thread.id)/resolve").jsonBody(EmptyBody()))
        refreshOpenStreams()
    }

    func markRead(_ thread: FeedbackThread) async throws {
        try await markAllRead([thread])
    }

    func markAllRead(_ threads: [FeedbackThread]) async throws {
        let unread = threads.filter(\.isUnread).map(\.id)
        guard !unread.isEmpty else { return }
        // The Gateway takes 200 ids a request.
        for start in stride(from: 0, to: unread.count, by: 200) {
            let ids = Array(unread[start..<min(start + 200, unread.count)])
            try await client.sendVoid(try request("POST", "/read").jsonBody(ReadBody(threadIds: ids)))
        }
        refreshOpenStreams()
    }

    private func upload(
        _ attachments: [FeedbackDraftAttachment],
        threadID: String,
        progress: (SubmitStage) -> Void
    ) async throws -> [FeedbackAttachment] {
        var uploaded: [FeedbackAttachment] = []
        for (index, attachment) in attachments.prefix(FeedbackFirestoreSchema.attachmentLimit).enumerated() {
            progress(.uploadingAttachment(index + 1, of: attachments.count))
            var put = request(
                "PUT",
                "/threads/\(threadID)/attachments",
                query: [URLQueryItem(name: "extension", value: attachment.fileExtension.lowercased())]
            )
            put.headers["Content-Type"] = attachment.contentType
            let data = try await client.upload(put, fromFile: attachment.fileURL)
            let stored: UploadedAttachment
            do {
                stored = try JSONDecoder().decode(UploadedAttachment.self, from: data)
            } catch {
                AppLogger.network("Feedback upload response did not decode", error: error)
                throw GatewayAPIError.invalidResponse
            }
            uploaded.append(FeedbackAttachment(
                path: stored.path,
                kind: FeedbackAttachment.Kind(rawValue: stored.kind) ?? attachment.kind,
                contentType: stored.contentType,
                bytes: stored.bytes,
                width: Int(attachment.pixelSize.width),
                height: Int(attachment.pixelSize.height)
            ))
        }
        return uploaded
    }

    // MARK: - Reading

    /// The inbox's threads, kept current. Ends with an error the view shows when the
    /// first load fails.
    func threadUpdates() -> AsyncThrowingStream<[FeedbackThread], Error> {
        polling { [self] in
            let object = try await json(request("GET", "/threads"))
            let rows = object["threads"] as? [[String: Any]] ?? []
            // An inbox shared over iCloud Keychain may have reports this device never sent.
            if !rows.isEmpty { FeedbackPushRegistration.shared.inboxInUse() }
            return rows.compactMap { row in
                (row["id"] as? String).flatMap { Self.thread(id: $0, data: row) }
            }
        }
    }

    /// One thread, read once: what a tapped notification opens.
    func thread(id: String) async throws -> FeedbackThread? {
        let object = try await json(request("GET", "/threads"))
        let rows = object["threads"] as? [[String: Any]] ?? []
        guard let row = rows.first(where: { $0["id"] as? String == id }) else { return nil }
        return Self.thread(id: id, data: row)
    }

    /// Files this device's APNs token under the inbox, keyed by the install id so a new
    /// token replaces the old one (`FeedbackPushRegistration` decides when).
    func registerPushDevice(token: String, environment: String) async throws {
        let deviceID = CrashContext.installID.lowercased()
        try await client.sendVoid(
            try request("PUT", "/push-devices/\(deviceID)").jsonBody(PushDeviceBody(token: token, environment: environment))
        )
    }

    /// One thread's messages, oldest first, kept current.
    func messageUpdates(threadID: String) -> AsyncThrowingStream<[FeedbackMessage], Error> {
        polling { [self] in
            let object = try await json(request("GET", "/threads/\(threadID)/messages"))
            let rows = object["messages"] as? [[String: Any]] ?? []
            return rows.compactMap { row in
                (row["id"] as? String).flatMap { Self.message(id: $0, data: row) }
            }
        }
    }

    /// Loads at once, then again on every wake-up: the refresh interval, an own write,
    /// or the app returning to the foreground. A failed first load ends the stream with
    /// the error, as the listener did; a failed refresh after that keeps what is on
    /// screen and is logged, and the next wake-up tries again.
    private func polling<Value: Sendable>(
        _ load: @escaping @MainActor () async throws -> Value
    ) -> AsyncThrowingStream<Value, Error> {
        let (stream, continuation) = AsyncThrowingStream<Value, Error>.makeStream()
        let (signals, wake) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        wakeups[id] = wake
        wake.yield()

        let ticker = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.refreshInterval)
                } catch {
                    return
                }
                wake.yield()
            }
        }
        let worker = Task { @MainActor in
            var delivered = false
            for await _ in signals {
                do {
                    continuation.yield(try await load())
                    delivered = true
                } catch is CancellationError {
                    break
                } catch {
                    if !delivered {
                        AppLogger.network("Feedback inbox failed to load", error: error)
                        continuation.finish(throwing: error)
                        break
                    }
                    AppLogger.network("Feedback refresh failed; keeping the last result", error: error)
                }
            }
        }
        continuation.onTermination = { [weak self] _ in
            ticker.cancel()
            worker.cancel()
            wake.finish()
            Task { @MainActor in self?.wakeups[id] = nil }
        }
        return stream
    }

    /// Also called when a 回饋中心 notification arrives while the app is open.
    func refreshOpenStreams() {
        for wake in wakeups.values { wake.yield() }
    }

    /// An attachment image, from memory after the first load.
    func image(for attachment: FeedbackAttachment) async throws -> UIImage {
        if let cached = imageCache.object(forKey: attachment.path as NSString) { return cached }
        let file = try await client.download(try attachmentRequest(attachment))
        defer { removeTemporary(file) }
        let data = try Data(contentsOf: file)
        guard let image = UIImage(data: data) else { throw FeedbackError.attachmentUnreadable }
        imageCache.setObject(image, forKey: attachment.path as NSString)
        return image
    }

    /// A video attachment as a local file the system player can open: the player cannot
    /// send the inbox key, so the file comes down through the Gateway first. Kept in the
    /// caches directory, so opening it again does not download it again.
    func playableFile(for attachment: FeedbackAttachment) async throws -> URL {
        let directory = URL.cachesDirectory.appending(path: "FeedbackAttachments", directoryHint: .isDirectory)
        let destination = directory.appending(path: (attachment.path as NSString).lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        let file = try await client.download(try attachmentRequest(attachment))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: file, to: destination)
        return destination
    }

    /// `feedback/{inbox}/{thread}/{file}` is addressed by thread and file alone; the
    /// Gateway rebuilds the path from the inbox it is given.
    private func attachmentRequest(_ attachment: FeedbackAttachment) throws -> GatewayRequest {
        let components = attachment.path.split(separator: "/")
        guard components.count == 4, components[0] == "feedback" else {
            AppLogger.parse("Feedback attachment path is not feedback/{inbox}/{thread}/{file}", context: ["path": attachment.path])
            throw FeedbackError.attachmentUnreadable
        }
        return request("GET", "/threads/\(components[2])/attachments/\(components[3])")
    }

    private func removeTemporary(_ file: URL) {
        do {
            try FileManager.default.removeItem(at: file)
        } catch {
            AppLogger.error("Feedback download could not be removed", error: error)
        }
    }

    // MARK: - Request bodies

    private struct NewThreadBody: Encodable {
        let threadId: String
        let kind: String
        let title: String
        let preview: String
        let text: String
        let attachments: [AttachmentBody]
        let appVersion: String
        let build: String
        let osVersion: String
        let device: String
        let locale: String
        let installId: String
        let diagnosticReportId: String
        let deviceInfo: [String: String]
    }

    private struct PushDeviceBody: Encodable {
        let token: String
        let environment: String
    }

    private struct ReplyBody: Encodable {
        let text: String
        let preview: String
        let attachments: [AttachmentBody]
    }

    /// An uploaded attachment cited by a message. Kind, type and size are read back from
    /// Storage by the Gateway; only the picture's dimensions come from here.
    private struct AttachmentBody: Encodable {
        let path: String
        let width: Int
        let height: Int

        init(_ attachment: FeedbackAttachment) {
            path = attachment.path
            width = attachment.width
            height = attachment.height
        }
    }

    private struct ReadBody: Encodable {
        let threadIds: [String]
    }

    private struct EmptyBody: Encodable {}

    private struct UploadedAttachment: Decodable {
        let path: String
        let kind: String
        let contentType: String
        let bytes: Int
    }

    // MARK: - Decoding

    /// From the Gateway's JSON, as dictionaries so tests can feed them directly.
    nonisolated static func thread(id: String, data: [String: Any]) -> FeedbackThread? {
        guard let kind = (data["kind"] as? String).flatMap(FeedbackKind.init(rawValue:)) else {
            AppLogger.parse("Feedback thread has no valid kind", context: ["thread": id])
            return nil
        }
        let created = date(data["createdAt"]) ?? Date()
        return FeedbackThread(
            id: id,
            number: (data["number"] as? NSNumber)?.intValue,
            kind: kind,
            title: data["title"] as? String ?? "",
            status: FeedbackStatus(serverValue: data["status"] as? String),
            createdAt: created,
            updatedAt: date(data["updatedAt"]) ?? created,
            lastMessagePreview: data["lastMessagePreview"] as? String ?? "",
            lastMessageAuthor: (data["lastMessageAuthor"] as? String).flatMap(FeedbackAuthor.init(rawValue:)) ?? .user,
            lastReplyAt: date(data["lastReplyAt"]),
            userLastReadAt: date(data["userLastReadAt"])
        )
    }

    nonisolated static func message(id: String, data: [String: Any]) -> FeedbackMessage? {
        guard let author = (data["author"] as? String).flatMap(FeedbackAuthor.init(rawValue:)) else {
            AppLogger.parse("Feedback message has no valid author", context: ["message": id])
            return nil
        }
        let attachments = (data["attachments"] as? [[String: Any]] ?? []).compactMap { field -> FeedbackAttachment? in
            guard let path = field["path"] as? String,
                  let kind = (field["kind"] as? String).flatMap(FeedbackAttachment.Kind.init(rawValue:)) else { return nil }
            return FeedbackAttachment(
                path: path,
                kind: kind,
                contentType: field["contentType"] as? String ?? "",
                bytes: (field["bytes"] as? NSNumber)?.intValue ?? 0,
                width: (field["width"] as? NSNumber)?.intValue ?? 0,
                height: (field["height"] as? NSNumber)?.intValue ?? 0
            )
        }
        return FeedbackMessage(
            id: id,
            author: author,
            text: data["text"] as? String ?? "",
            attachments: attachments,
            createdAt: date(data["createdAt"])
        )
    }

    /// The Gateway sends ISO 8601 with milliseconds (`Date.toISOString()`).
    nonisolated static func date(_ value: Any?) -> Date? {
        switch value {
        case let date as Date: return date
        case let text as String:
            do {
                return try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text)
            } catch {
                AppLogger.parse("Feedback date is not ISO 8601", error: error, context: ["value": text])
                return nil
            }
        default: return nil
        }
    }
}
