import Testing
@testable import yuedu_app

@MainActor
@Suite("WebView navigation wait", .serialized)
struct WebViewNavigationWaitTests {
    @Test("cancelling a suspended navigation wait resumes it with cancellation")
    func cancellationResumesSuspendedWait() async {
        let wait = WebViewNavigationWait()
        var didStart = false

        let task = Task { @MainActor in
            try await wait.value {
                didStart = true
            }
        }

        while !didStart {
            await Task.yield()
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test("a navigation result resumes the registered waiter once")
    func resultResumesWaiter() async throws {
        let wait = WebViewNavigationWait()
        var didStart = false

        let task = Task { @MainActor in
            try await wait.value {
                didStart = true
            }
        }

        while !didStart {
            await Task.yield()
        }
        wait.resume(returning: "loaded")

        #expect(try await task.value == "loaded")
        #expect(!wait.isWaiting)
    }
}
