import Foundation
import os
import Testing
import UIKit
@testable import yuedu_app

/// 回饋中心 over the Gateway: what the app sends, and how it reads the answers. The
/// Gateway's own rules are tested in gateway/test/feedback.test.ts.
@Suite("Feedback through the Gateway", .serialized)
@MainActor
struct FeedbackGatewayTests {
    private nonisolated static let inbox = String(repeating: "A", count: 42) + "b"

    private func service() -> FeedbackService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FeedbackGatewayStub.self]
        let client = GatewayAPIClient(
            session: URLSession(configuration: configuration),
            baseURLProvider: { URL(string: "https://gateway.test") }
        )
        return FeedbackService(client: client, inboxKey: { Self.inbox })
    }

    @Test("a report goes to the Gateway with the inbox key in Authorization, never in the URL")
    func submitRequest() async throws {
        FeedbackGatewayStub.reset { request in
            // PUT /v1/feedback/threads/{thread}/attachments
            let components = request.url?.pathComponents ?? []
            if components.last == "attachments", components.count == 6 {
                let path = "feedback/\(Self.inbox)/\(components[4])/7c9e6679-7425-40de-944b-e07fc1f90ae7.jpg"
                return (201, ["path": path, "kind": "image", "contentType": "image/jpeg", "bytes": 4])
            }
            return (201, ["threadId": "ok"])
        }
        let attachment = try FeedbackDraftAttachment.image(UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in })
        defer { attachment.discard() }

        let threadID = try await service().submit(
            kind: .bug,
            text: "翻頁卡住\n第二行",
            attachments: [attachment],
            diagnostics: nil,
            deviceInfo: FeedbackDeviceInfo(rows: []),
            progress: { _ in }
        )

        let requests = FeedbackGatewayStub.recorded
        #expect(requests.count == 2)
        let upload = try #require(requests.first)
        #expect(upload.method == "PUT")
        #expect(upload.path == "/v1/feedback/threads/\(threadID)/attachments")
        #expect(upload.query == "extension=jpg")
        #expect(upload.headers["Content-Type"] == "image/jpeg")

        let create = try #require(requests.last)
        #expect(create.method == "POST")
        #expect(create.path == "/v1/feedback/threads")
        for request in requests {
            #expect(request.headers["Authorization"] == "Inbox \(Self.inbox)")
            #expect(!request.url.contains(Self.inbox))
        }
        let body = try #require(create.json)
        #expect(body["threadId"] as? String == threadID)
        #expect(body["kind"] as? String == "bug")
        #expect(body["title"] as? String == "翻頁卡住")
        #expect(body["preview"] as? String == "翻頁卡住 第二行")
        let cited = try #require((body["attachments"] as? [[String: Any]])?.first)
        #expect((cited["path"] as? String)?.hasPrefix("feedback/\(Self.inbox)/\(threadID)/") == true)
        #expect(cited["width"] as? Int == 4 * Int(UIScreen.main.scale))
    }

    @Test("the inbox list decodes the Gateway's ISO dates and refreshes after an own write")
    func threadPolling() async throws {
        FeedbackGatewayStub.reset { request in
            if request.url?.path == "/v1/feedback/threads", request.httpMethod == "GET" {
                return (200, ["threads": [[
                    "id": "0f8fad5b-d9cb-469f-a165-70867728950e", "kind": "bug", "status": "needsInfo",
                    "title": "模塊錯位", "number": 25_743,
                    "createdAt": "2026-10-17T01:02:03.000Z",
                    "lastReplyAt": "2026-10-17T02:00:00.000Z",
                    "userLastReadAt": "2026-10-17T01:02:03.000Z",
                ]]])
            }
            return (200, ["read": []])
        }
        let service = service()
        var iterator = service.threadUpdates().makeAsyncIterator()
        let first = try #require(try await iterator.next())
        let thread = try #require(first.first)
        #expect(thread.number == 25_743)
        #expect(thread.createdAt == Date(timeIntervalSince1970: 1_792_198_923))
        #expect(thread.isUnread)

        try await service.markRead(thread)
        // The write wakes the open stream at once, without waiting the refresh interval.
        _ = try #require(try await iterator.next())
        let gets = FeedbackGatewayStub.recorded.filter { $0.method == "GET" }
        #expect(gets.count == 2)
        let read = try #require(FeedbackGatewayStub.recorded.first { $0.path == "/v1/feedback/read" })
        #expect(read.json?["threadIds"] as? [String] == [thread.id])
    }

    @Test("a first load that fails ends the stream with the error")
    func firstLoadFailure() async {
        FeedbackGatewayStub.reset { _ in (503, ["error": ["code": "upstream-unavailable", "message": "down"]]) }
        let updates = service().threadUpdates()
        await #expect(throws: GatewayAPIError.self) {
            // Made inside: the macro sends its closure, so it cannot mutate an outer iterator.
            var iterator = updates.makeAsyncIterator()
            _ = try await iterator.next()
        }
    }

    @Test("an attachment is fetched by thread and file name, not by its storage path")
    func attachmentAddress() async throws {
        FeedbackGatewayStub.reset { _ in (200, [:]) }
        let attachment = FeedbackAttachment(
            path: "feedback/\(Self.inbox)/0f8fad5b-d9cb-469f-a165-70867728950e/7c9e6679-7425-40de-944b-e07fc1f90ae7.jpg",
            kind: .image, contentType: "image/jpeg", bytes: 2, width: 1, height: 1
        )
        _ = try? await service().image(for: attachment)
        let request = try #require(FeedbackGatewayStub.recorded.first)
        #expect(request.path == "/v1/feedback/threads/0f8fad5b-d9cb-469f-a165-70867728950e/attachments/7c9e6679-7425-40de-944b-e07fc1f90ae7.jpg")
        #expect(!request.url.contains(Self.inbox))
    }

    @Test("Gateway errors read as the two localized sentences, never the server's English")
    func errorText() {
        let unreachable = FeedbackService.userMessage(for: GatewayAPIError.transport(URLError(.timedOut)))
        #expect(unreachable == localized("無法連線到回報服務，請檢查網路後再試。"))
        let upstream = FeedbackService.userMessage(
            for: GatewayAPIError.server(code: "upstream-unavailable", message: "down", status: 503, details: [:])
        )
        #expect(upstream == unreachable)
        let refused = FeedbackService.userMessage(
            for: GatewayAPIError.server(code: "invalid-argument", message: "title is too long.", status: 400, details: [:])
        )
        #expect(refused == localized("回報服務暫時出了問題，請稍後再試。"))
        #expect(FeedbackService.userMessage(for: GatewayAPIError.notConfigured) == localized("回報服務目前無法使用。"))
    }

    @Test("ISO dates with and without a server value decode; garbage is nil")
    func dates() {
        #expect(FeedbackService.date("2026-10-17T01:02:03.000Z") == Date(timeIntervalSince1970: 1_792_198_923))
        #expect(FeedbackService.date(NSNull()) == nil)
        #expect(FeedbackService.date("yesterday") == nil)
    }
}

/// Answers every request from a closure and records what was sent.
private final class FeedbackGatewayStub: URLProtocol {
    struct Recorded {
        let method: String
        let url: String
        let path: String
        let query: String?
        let headers: [String: String]
        let json: [String: Any]?
    }

    typealias Responder = @Sendable (URLRequest) -> (Int, [String: Any])

    private static let state = OSAllocatedUnfairLock<(responder: Responder?, recorded: [Recorded])>(
        uncheckedState: (nil, [])
    )

    static func reset(_ responder: @escaping Responder) {
        state.withLockUnchecked { $0 = (responder, []) }
    }

    static var recorded: [Recorded] {
        state.withLockUnchecked { $0.recorded }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read)
        let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let recorded = Recorded(
            method: request.httpMethod ?? "GET",
            url: url.absoluteString,
            path: url.path,
            query: URLComponents(url: url, resolvingAgainstBaseURL: false)?.query,
            headers: request.allHTTPHeaderFields ?? [:],
            json: json
        )
        let responder = Self.state.withLockUnchecked { state -> Responder? in
            state.recorded.append(recorded)
            return state.responder
        }
        let (status, object) = responder?(request) ?? (500, [:])
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
