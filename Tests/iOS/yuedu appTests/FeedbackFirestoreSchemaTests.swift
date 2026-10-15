import Foundation
import Testing
@testable import yuedu_app

/// 回饋中心: what the app writes must be exactly what firestore.rules accepts, and what the
/// developer side writes back must read as the right thread state.
@Suite("Feedback center schema and state")
struct FeedbackFirestoreSchemaTests {
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // yuedu appTests
            .deletingLastPathComponent() // iOS
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent()
    }

    /// The `hasOnly([...])` lists inside the feedback block of firestore.rules, in file
    /// order: thread create, thread update, message create.
    private func ruleFieldLists() throws -> [Set<String>] {
        let rules = try String(contentsOf: Self.repositoryRoot.appendingPathComponent("firestore.rules"), encoding: .utf8)
        let block = try #require(rules.range(of: "match /feedbackInboxes/").map { String(rules[$0.lowerBound...]) })
        let pattern = try Regex(#"hasOnly\(\[([^\]]*)\]\)"#)
        return block.matches(of: pattern).map { match in
            let body = String(block[match.range]).replacingOccurrences(of: "\n", with: " ")
            return Set(body.matches(of: try! Regex(#""([A-Za-z]+)""#)).map { m in
                String(body[m.range]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            })
        }
    }

    @Test("the client writes exactly the fields the rules whitelist")
    func fieldsMatchRules() throws {
        let lists = try ruleFieldLists()
        try #require(lists.count == 3)
        #expect(lists[0] == FeedbackFirestoreSchema.threadCreateFields)
        #expect(lists[1] == FeedbackFirestoreSchema.threadUpdateFields)
        #expect(lists[2] == FeedbackFirestoreSchema.messageFields)
    }

    @Test("inbox keys are 43 base64url characters, as the rules require")
    func inboxKeyFormat() throws {
        let pattern = try Regex("^[A-Za-z0-9_-]{43}$")
        for _ in 0..<200 {
            let key = FeedbackInbox.makeKey()
            #expect(key.wholeMatch(of: pattern) != nil)
            #expect(FeedbackInbox.isValid(key))
        }
        #expect(!FeedbackInbox.isValid("short"))
    }

    @Test("a reply newer than the last read is unread; reading it clears it")
    func unreadState() throws {
        let reply = Date(timeIntervalSince1970: 2_000)
        let unread = try #require(FeedbackService.thread(id: "a", data: [
            "kind": "bug", "status": "needsInfo", "title": "模塊錯位",
            "createdAt": Date(timeIntervalSince1970: 1_000),
            "lastReplyAt": reply,
            "userLastReadAt": Date(timeIntervalSince1970: 1_000),
            "number": NSNumber(value: 25_743),
        ]))
        #expect(unread.isUnread)
        #expect(unread.status.group == .needsInfo)

        let read = try #require(FeedbackService.thread(id: "a", data: [
            "kind": "bug", "status": "needsInfo",
            "createdAt": Date(timeIntervalSince1970: 1_000),
            "lastReplyAt": reply,
            "userLastReadAt": Date(timeIntervalSince1970: 3_000),
        ]))
        #expect(!read.isUnread)

        let noReply = try #require(FeedbackService.thread(id: "b", data: ["kind": "suggestion", "status": "received"]))
        #expect(!noReply.isUnread)
        #expect(noReply.status.group == .queued)
    }

    @Test("statuses fall into the four groups; an unknown one reads as queued")
    func statusGroups() {
        #expect(FeedbackStatus(serverValue: "processing").group == .processing)
        #expect(FeedbackStatus(serverValue: "queued").group == .queued)
        #expect(FeedbackStatus(serverValue: "received").group == .queued)
        #expect(FeedbackStatus(serverValue: "done").group == .done)
        #expect(FeedbackStatus(serverValue: "somethingNew") == .queued)
        #expect(FeedbackStatus(serverValue: nil) == .queued)
    }

    @Test("a thread without a valid kind is dropped, not shown half-empty")
    func invalidThreadDropped() {
        #expect(FeedbackService.thread(id: "x", data: ["status": "queued"]) == nil)
        #expect(FeedbackService.message(id: "x", data: ["text": "hi"]) == nil)
    }

    @Test("messages read their author and attachments")
    func messageDecoding() throws {
        let message = try #require(FeedbackService.message(id: "m", data: [
            "author": "assistant",
            "text": "已收到你的回報。",
            "attachments": [[
                "path": "feedback/k/t/1.jpg", "kind": "image", "contentType": "image/jpeg",
                "bytes": NSNumber(value: 1_234), "width": NSNumber(value: 800), "height": NSNumber(value: 600),
            ]],
            "createdAt": Date(timeIntervalSince1970: 5),
        ]))
        #expect(message.author == .assistant)
        #expect(message.attachments.count == 1)
        #expect(message.attachments.first?.kind == .image)
        #expect(message.attachments.first?.bytes == 1_234)
    }

    @Test("a report's provisional title is its first line; the preview joins its lines")
    func titleAndPreview() {
        let text = "\n  海報牆資源顯示有問題  \n點進去後是繁體\n\n名字依舊是簡體"
        #expect(FeedbackFirestoreSchema.provisionalTitle(of: text) == "海報牆資源顯示有問題")
        #expect(FeedbackFirestoreSchema.preview(of: text) == "海報牆資源顯示有問題 點進去後是繁體 名字依舊是簡體")
        #expect(FeedbackFirestoreSchema.preview(of: String(repeating: "字", count: 500)).count
            == FeedbackFirestoreSchema.previewLimit)
    }

    @Test("the shared log file leads with the report")
    func shareFilePreface() {
        var bundle = DiagnosticReportBundle(
            filename: "t.txt", entries: [], session: DiagnosticLog.shared.currentSession,
            uncleanSessions: [], acknowledgesReport: false
        )
        bundle.preface = "[問題回報]\n閃退"
        let text = bundle.render()
        let report = text.range(of: "--- report ---\n[問題回報]\n閃退")
        let log = text.range(of: "--- full log")
        #expect(report != nil)
        if let report, let log { #expect(report.lowerBound < log.lowerBound) }
    }
}
