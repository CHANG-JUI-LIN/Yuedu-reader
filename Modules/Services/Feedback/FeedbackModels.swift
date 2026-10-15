import Foundation

// MARK: - 回饋中心 data model
//
// One thread per report, stored at `feedbackInboxes/{inbox}/threads/{id}` with its
// messages beneath it (see `FeedbackService` and firestore.rules). The developer side —
// the thread number, the AI 助手's first reply, developer replies and most statuses — is
// written with admin credentials (functions/src/feedbackTriage.ts, functions/tools/feedback.ts).

enum FeedbackKind: String, CaseIterable, Identifiable, Sendable {
    case bug
    case suggestion

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .bug: localized("問題回報")
        case .suggestion: localized("改進建議")
        }
    }

    var placeholder: String {
        switch self {
        case .bug: localized("請描述遇到的問題：在哪個頁面、做了什麼操作、看到了什麼…")
        case .suggestion: localized("請描述希望新增或改進的功能，以及想在什麼情境下使用…")
        }
    }
}

/// A thread's state. Shown text always comes from here, never from the server, so the
/// label follows the app's language whoever set the status.
enum FeedbackStatus: String, Sendable {
    /// Just sent; the first reply has not run yet.
    case received
    case queued
    case processing
    case needsInfo
    case done

    /// Unknown values (a status added on the server later) read as queued rather than
    /// hiding the thread.
    init(serverValue: String?) {
        self = serverValue.flatMap(FeedbackStatus.init(rawValue:)) ?? .queued
    }

    var group: FeedbackStatusGroup {
        switch self {
        case .processing: .processing
        case .received, .queued: .queued
        case .needsInfo: .needsInfo
        case .done: .done
        }
    }

    var badgeTitle: String {
        switch self {
        case .received, .queued: localized("已收到，排隊處理中")
        case .processing: localized("開發者處理中")
        case .needsInfo: localized("需要你補充資訊")
        case .done: localized("已完成")
        }
    }
}

/// The four groups 我的回饋 filters by, in the order its bar shows them.
enum FeedbackStatusGroup: String, CaseIterable, Identifiable, Sendable {
    case processing
    case queued
    case needsInfo
    case done

    var id: String { rawValue }

    var title: String {
        switch self {
        case .processing: localized("處理中")
        case .queued: localized("排隊中")
        case .needsInfo: localized("待補充")
        case .done: localized("已完成")
        }
    }

    var systemImage: String {
        switch self {
        case .processing: "gearshape"
        case .queued: "clock"
        case .needsInfo: "text.bubble"
        case .done: "checkmark.circle"
        }
    }
}

enum FeedbackAuthor: String, Sendable {
    case user
    case assistant
    case developer
}

struct FeedbackAttachment: Hashable, Sendable {
    enum Kind: String, Sendable {
        case image
        case video
    }

    /// Storage path, `feedback/{inbox}/{thread}/{file}`.
    let path: String
    let kind: Kind
    let contentType: String
    let bytes: Int
    let width: Int
    let height: Int
}

struct FeedbackMessage: Identifiable, Hashable, Sendable {
    let id: String
    let author: FeedbackAuthor
    let text: String
    let attachments: [FeedbackAttachment]
    /// Nil only for a message whose server timestamp has not come back yet.
    let createdAt: Date?
}

struct FeedbackThread: Identifiable, Hashable, Sendable {
    let id: String
    let number: Int?
    let kind: FeedbackKind
    let title: String
    let status: FeedbackStatus
    let createdAt: Date
    let updatedAt: Date
    let lastMessagePreview: String
    let lastMessageAuthor: FeedbackAuthor
    let lastReplyAt: Date?
    let userLastReadAt: Date?

    /// A reply the user has not opened: something from the assistant or the developer
    /// newer than the last time the thread was read.
    var isUnread: Bool {
        guard let lastReplyAt else { return false }
        guard let userLastReadAt else { return true }
        return lastReplyAt > userLastReadAt
    }

    /// 「回饋 #25,743」, or plain 「回饋」 until the server has numbered it.
    var displayTitle: String {
        guard let number else { return localized("回饋") }
        let formatted = number.formatted(.number.grouping(.automatic))
        return String(format: localized("回饋 #%@"), formatted)
    }
}

enum FeedbackSortOrder: String, CaseIterable, Identifiable, Sendable {
    case newestFirst
    case oldestFirst

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newestFirst: localized("最新的在前")
        case .oldestFirst: localized("最早的在前")
        }
    }
}

/// Field names the client writes. firestore.rules whitelists exactly these;
/// `FeedbackFirestoreSchemaTests` reads the rules file to keep them in step.
enum FeedbackFirestoreSchema {
    static let inboxes = "feedbackInboxes"
    static let threads = "threads"
    static let messages = "messages"

    static let threadCreateFields: Set<String> = [
        "kind", "title", "status", "createdAt", "updatedAt", "lastMessageAt",
        "lastMessagePreview", "lastMessageAuthor", "userLastReadAt", "appVersion", "build",
        "osVersion", "device", "locale", "installId", "diagnosticReportId", "deviceInfo",
    ]

    static let threadUpdateFields: Set<String> = [
        "userLastReadAt", "status", "updatedAt", "lastMessageAt", "lastMessagePreview",
        "lastMessageAuthor",
    ]

    static let messageFields: Set<String> = ["author", "text", "attachments", "createdAt"]

    static let titleLimit = 200
    static let previewLimit = 120
    static let textLimit = 5000
    static let attachmentLimit = 5
    static let imageByteLimit = 15 * 1024 * 1024
    static let videoByteLimit = 50 * 1024 * 1024

    /// The list's preview: the message's lines joined on one line, bounded.
    static func preview(of text: String) -> String {
        let joined = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(joined.prefix(previewLimit))
    }

    /// A new thread's title until the AI 助手 names it: the first line of the report.
    static func provisionalTitle(of text: String) -> String {
        let firstLine = text
            .split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return String(firstLine.prefix(titleLimit))
    }
}
