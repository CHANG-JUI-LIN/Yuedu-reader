import StoreKitTest
import XCTest

/// One `SKTestSession` per configuration file for the whole UI-test run.
///
/// Creating another session in the same runner process is slow on iOS 17.5, and slower each
/// time, even with the earlier ones released: `SKTestSession(contentsOf:)` took 0.005 s,
/// then 36 s, then 92 s, and the runner was killed during the third test
/// (DetailReaderBackSwipeUITests, 2026-10-14). Resetting the one session takes under 1 ms.
@MainActor
enum StoreKitTestSessions {
    private static var sessions: [URL: SKTestSession] = [:]

    /// The run's session for `configuration`, back to the file's state with no transactions
    /// and no purchase dialogs.
    static func fresh(_ configuration: URL) throws -> SKTestSession {
        let session = try sessions[configuration] ?? SKTestSession(contentsOf: configuration)
        sessions[configuration] = session
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        return session
    }

    /// `Configuration/YueduPro.storekit`, from a file in `Tests/iOS-UI`.
    static func yueduPro(testFile: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(testFile)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Configuration/YueduPro.storekit")
    }
}
