import FirebaseCore
import FirebaseFirestore
import FirebaseStorage
import Foundation
import UIKit

/// 回饋中心's one service: sends reports and replies, uploads their attachments, and
/// streams the inbox back. Views make one call each; everything that talks to Firebase is
/// here.
///
/// Storage layout and permissions are described in firestore.rules and storage.rules. The
/// developer side answers through functions (`onFeedbackThreadCreated`, the AI 助手's
/// first reply) and functions/tools/feedback.ts.
@MainActor
final class FeedbackService {
    static let shared = FeedbackService()

    enum FeedbackError: LocalizedError {
        case firebaseUnavailable
        case emptyReport
        case attachmentTooLarge
        case attachmentUnreadable

        var errorDescription: String? {
            switch self {
            case .firebaseUnavailable: localized("回報服務目前無法使用。")
            case .emptyReport: localized("請先描述問題或建議。")
            case .attachmentTooLarge: localized("影片超過 50 MB，請剪短後再試。")
            case .attachmentUnreadable: localized("無法讀取這個附件。")
            }
        }
    }

    /// What a failed call says on screen. Firebase's own error text is English and
    /// technical ("Missing or insufficient permissions."), so its errors read as one of two
    /// localized sentences; the caller logs the original. Other errors — ours, or the
    /// system's while preparing an attachment — are already localized and pass through.
    nonisolated static func userMessage(for error: Error) -> String {
        let nsError = error as NSError
        let unreachable = nsError.domain == NSURLErrorDomain
            || (nsError.domain == FirestoreErrorDomain && [
                FirestoreErrorCode.Code.unavailable.rawValue,
                FirestoreErrorCode.Code.deadlineExceeded.rawValue,
            ].contains(nsError.code))
            || (nsError.domain == StorageErrorDomain && nsError.code == StorageErrorCode.retryLimitExceeded.rawValue)
        if unreachable {
            return localized("無法連線到回報服務，請檢查網路後再試。")
        }
        if nsError.domain == FirestoreErrorDomain || nsError.domain == StorageErrorDomain {
            return localized("回報服務暫時出了問題，請稍後再試。")
        }
        return error.localizedDescription
    }

    /// What a submit is doing, for the form's progress line.
    enum SubmitStage: Equatable {
        case uploadingAttachment(Int, of: Int)
        case uploadingLog
        case sending
    }

    private let imageCache = NSCache<NSString, UIImage>()

    private init() {}

    private var inbox: DocumentReference {
        Firestore.firestore()
            .collection(FeedbackFirestoreSchema.inboxes)
            .document(FeedbackInbox.key)
    }

    private func threadRef(_ threadID: String) -> DocumentReference {
        inbox.collection(FeedbackFirestoreSchema.threads).document(threadID)
    }

    private func requireFirebase() throws {
        guard FirebaseApp.app() != nil else { throw FeedbackError.firebaseUnavailable }
    }

    // MARK: - Sending

    /// Sends a new report: attachments to Storage, the diagnostic log (when included) to
    /// `diagnosticReports`, then the thread and its first message in one batch so the
    /// first-reply function always finds the message. Returns the new thread's id.
    func submit(
        kind: FeedbackKind,
        text: String,
        attachments: [FeedbackDraftAttachment],
        diagnostics: DiagnosticReportBundle?,
        deviceInfo: FeedbackDeviceInfo,
        progress: (SubmitStage) -> Void
    ) async throws -> String {
        try requireFirebase()
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
        let now = FieldValue.serverTimestamp()
        let thread = threadRef(threadID)
        let batch = Firestore.firestore().batch()
        batch.setData([
            "kind": kind.rawValue,
            "title": FeedbackFirestoreSchema.provisionalTitle(of: body),
            "status": FeedbackStatus.received.rawValue,
            "createdAt": now,
            "updatedAt": now,
            "lastMessageAt": now,
            "lastMessagePreview": FeedbackFirestoreSchema.preview(of: body),
            "lastMessageAuthor": FeedbackAuthor.user.rawValue,
            "userLastReadAt": now,
            "appVersion": info?["CFBundleShortVersionString"] as? String ?? "",
            "build": info?["CFBundleVersion"] as? String ?? "",
            "osVersion": "iOS \(UIDevice.current.systemVersion)",
            "device": deviceInfo.modelIdentifier,
            "locale": Locale.preferredLanguages.first ?? Locale.current.identifier,
            "installId": CrashContext.installID,
            "diagnosticReportId": reportID,
            "deviceInfo": deviceInfo.fields,
        ], forDocument: thread)
        batch.setData(
            messageFields(text: body, attachments: uploaded),
            forDocument: thread.collection(FeedbackFirestoreSchema.messages).document(UUID().uuidString.lowercased())
        )
        try await batch.commit()
        CrashContext.breadcrumb("feedback \(threadID) sent (\(uploaded.count) attachments, log \(reportID))")
        return threadID
    }

    /// A follow-up in an existing thread. Answering a 待補充 request puts the thread
    /// back in the queue (the one status change besides 已解決 a client may make).
    func reply(to thread: FeedbackThread, text: String, attachments: [FeedbackDraftAttachment]) async throws {
        try requireFirebase()
        let body = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(FeedbackFirestoreSchema.textLimit))
        guard !body.isEmpty || !attachments.isEmpty else { throw FeedbackError.emptyReport }
        let uploaded = try await upload(attachments, threadID: thread.id, progress: { _ in })

        let ref = threadRef(thread.id)
        let now = FieldValue.serverTimestamp()
        var update: [String: Any] = [
            "updatedAt": now,
            "lastMessageAt": now,
            "lastMessagePreview": body.isEmpty
                ? localized("〔附件〕")
                : FeedbackFirestoreSchema.preview(of: body),
            "lastMessageAuthor": FeedbackAuthor.user.rawValue,
            "userLastReadAt": now,
        ]
        if thread.status == .needsInfo { update["status"] = FeedbackStatus.queued.rawValue }

        let batch = Firestore.firestore().batch()
        batch.setData(
            messageFields(text: body, attachments: uploaded),
            forDocument: ref.collection(FeedbackFirestoreSchema.messages).document(UUID().uuidString.lowercased())
        )
        batch.updateData(update, forDocument: ref)
        try await batch.commit()
    }

    func markResolved(_ thread: FeedbackThread) async throws {
        try requireFirebase()
        try await threadRef(thread.id).updateData([
            "status": FeedbackStatus.done.rawValue,
            "updatedAt": FieldValue.serverTimestamp(),
        ])
    }

    func markRead(_ thread: FeedbackThread) async throws {
        guard thread.isUnread else { return }
        try requireFirebase()
        try await threadRef(thread.id).updateData(["userLastReadAt": FieldValue.serverTimestamp()])
    }

    func markAllRead(_ threads: [FeedbackThread]) async throws {
        let unread = threads.filter(\.isUnread)
        guard !unread.isEmpty else { return }
        try requireFirebase()
        let batch = Firestore.firestore().batch()
        for thread in unread {
            batch.updateData(["userLastReadAt": FieldValue.serverTimestamp()], forDocument: threadRef(thread.id))
        }
        try await batch.commit()
    }

    private func messageFields(text: String, attachments: [FeedbackAttachment]) -> [String: Any] {
        [
            "author": FeedbackAuthor.user.rawValue,
            "text": text,
            "attachments": attachments.map { attachment in
                [
                    "path": attachment.path,
                    "kind": attachment.kind.rawValue,
                    "contentType": attachment.contentType,
                    "bytes": attachment.bytes,
                    "width": attachment.width,
                    "height": attachment.height,
                ] as [String: Any]
            },
            "createdAt": FieldValue.serverTimestamp(),
        ]
    }

    private func upload(
        _ attachments: [FeedbackDraftAttachment],
        threadID: String,
        progress: (SubmitStage) -> Void
    ) async throws -> [FeedbackAttachment] {
        var uploaded: [FeedbackAttachment] = []
        let storage = Storage.storage()
        for (index, attachment) in attachments.prefix(FeedbackFirestoreSchema.attachmentLimit).enumerated() {
            progress(.uploadingAttachment(index + 1, of: attachments.count))
            let path = "feedback/\(FeedbackInbox.key)/\(threadID)/\(UUID().uuidString.lowercased()).\(attachment.fileExtension)"
            let metadata = StorageMetadata()
            metadata.contentType = attachment.contentType
            _ = try await storage.reference(withPath: path).putFileAsync(from: attachment.fileURL, metadata: metadata)
            uploaded.append(FeedbackAttachment(
                path: path,
                kind: attachment.kind,
                contentType: attachment.contentType,
                bytes: attachment.bytes,
                width: Int(attachment.pixelSize.width),
                height: Int(attachment.pixelSize.height)
            ))
        }
        return uploaded
    }

    // MARK: - Reading

    /// The inbox's threads, live. Ends with an error the view shows when the listener fails.
    func threadUpdates() -> AsyncThrowingStream<[FeedbackThread], Error> {
        AsyncThrowingStream { continuation in
            guard FirebaseApp.app() != nil else {
                continuation.finish(throwing: FeedbackError.firebaseUnavailable)
                return
            }
            let registration = inbox.collection(FeedbackFirestoreSchema.threads)
                .addSnapshotListener { snapshot, error in
                    if let error {
                        AppLogger.network("Feedback threads listener failed", error: error)
                        continuation.finish(throwing: error)
                        return
                    }
                    guard let snapshot else { return }
                    continuation.yield(snapshot.documents.compactMap(Self.thread(from:)))
                }
            continuation.onTermination = { _ in registration.remove() }
        }
    }

    /// One thread's messages, oldest first, live.
    func messageUpdates(threadID: String) -> AsyncThrowingStream<[FeedbackMessage], Error> {
        AsyncThrowingStream { continuation in
            guard FirebaseApp.app() != nil else {
                continuation.finish(throwing: FeedbackError.firebaseUnavailable)
                return
            }
            let registration = threadRef(threadID).collection(FeedbackFirestoreSchema.messages)
                .order(by: "createdAt")
                .addSnapshotListener { snapshot, error in
                    if let error {
                        AppLogger.network("Feedback messages listener failed", error: error)
                        continuation.finish(throwing: error)
                        return
                    }
                    guard let snapshot else { return }
                    continuation.yield(snapshot.documents.compactMap(Self.message(from:)))
                }
            continuation.onTermination = { _ in registration.remove() }
        }
    }

    /// An attachment image, from memory after the first load.
    func image(for attachment: FeedbackAttachment) async throws -> UIImage {
        if let cached = imageCache.object(forKey: attachment.path as NSString) { return cached }
        let data = try await Storage.storage().reference(withPath: attachment.path)
            .data(maxSize: Int64(FeedbackFirestoreSchema.imageByteLimit))
        guard let image = UIImage(data: data) else { throw FeedbackError.attachmentUnreadable }
        imageCache.setObject(image, forKey: attachment.path as NSString)
        return image
    }

    func downloadURL(for attachment: FeedbackAttachment) async throws -> URL {
        try await Storage.storage().reference(withPath: attachment.path).downloadURL()
    }

    // MARK: - Decoding

    nonisolated static func thread(from document: DocumentSnapshot) -> FeedbackThread? {
        guard let data = document.data(with: .estimate) else { return nil }
        return thread(id: document.documentID, data: data)
    }

    /// Separate from the snapshot so tests can feed it dictionaries.
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

    nonisolated static func message(from document: DocumentSnapshot) -> FeedbackMessage? {
        guard let data = document.data(with: .estimate) else { return nil }
        return message(id: document.documentID, data: data)
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

    nonisolated private static func date(_ value: Any?) -> Date? {
        switch value {
        case let timestamp as Timestamp: timestamp.dateValue()
        case let date as Date: date
        default: nil
        }
    }
}
