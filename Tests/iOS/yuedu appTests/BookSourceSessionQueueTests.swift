import Foundation
import Testing
@testable import yuedu_app

/// `BookSourceSession.withBridge` serves waiters by task priority: after a jump the reader
/// queues four neighbour prefetches that each hold a 段評 source's bridge for seconds, and
/// the chapter the reader is waiting on must not take its turn behind them.
@Suite("BookSourceSession bridge queue", .serialized)
struct BookSourceSessionQueueTests {
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []
        func append(_ entry: String) { lock.lock(); entries.append(entry); lock.unlock() }
        var values: [String] { lock.lock(); defer { lock.unlock() }; return entries }
    }

    private func makeSession() -> BookSourceSession {
        BookSourceSession.session(for: BookSource(
            bookSourceUrl: "https://\(UUID().uuidString).invalid", bookSourceName: "queue fixture"
        ))
    }

    /// Takes the bridge on its own thread at `.utility` and keeps it until `release` is signalled.
    private func holdBridge(
        of session: BookSourceSession, log: Log, release: DispatchSemaphore
    ) -> DispatchSemaphore {
        let held = DispatchSemaphore(value: 0)
        Thread {
            session.withBridge(priority: .utility) { _ in
                log.append("holder")
                held.signal()
                release.wait()
            }
        }.start()
        held.wait()
        return held
    }

    private func waitUntilQueued(_ count: Int, on session: BookSourceSession) async throws {
        let deadline = Date().addingTimeInterval(5)
        while session.queuedCallers < count {
            try #require(Date() < deadline, "bridge queue never reached \(count) callers")
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    @Test("a higher-priority caller goes before lower-priority callers that queued earlier")
    func priorityBeforeArrival() async throws {
        let session = makeSession()
        let log = Log()
        let release = DispatchSemaphore(value: 0)
        _ = holdBridge(of: session, log: log, release: release)

        let done = DispatchGroup()
        func queue(_ name: String, at priority: TaskPriority) {
            done.enter()
            Thread {
                session.withBridge(priority: priority) { _ in log.append(name) }
                done.leave()
            }.start()
        }
        queue("prefetch-1", at: .utility)
        try await waitUntilQueued(1, on: session)
        queue("reader", at: .userInitiated)
        try await waitUntilQueued(2, on: session)
        queue("prefetch-2", at: .utility)
        try await waitUntilQueued(3, on: session)

        release.signal()
        #expect(done.wait(timeout: .now() + 5) == .success)
        #expect(log.values == ["holder", "reader", "prefetch-1", "prefetch-2"])
        #expect(session.queuedCallers == 0)
    }

    @Test("a task cancelled while queued leaves without running its parse")
    func cancelledWaiterLeaves() async throws {
        let session = makeSession()
        let log = Log()
        let release = DispatchSemaphore(value: 0)
        _ = holdBridge(of: session, log: log, release: release)

        let waiter = Task(priority: .utility) {
            try await session.parse { _ in log.append("cancelled parse ran") }
        }
        try await waitUntilQueued(1, on: session)
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(session.queuedCallers == 0)

        release.signal()
        let answer = try await session.parse { _ in 42 }
        #expect(answer == 42)
        #expect(log.values == ["holder"])
    }
}
