import Foundation
import Testing
@testable import yuedu_app

/// 閱讀設定 › 自動接續閱讀: which book, if any, a cold launch reopens.
@MainActor
struct AutoResumeReadingTests {
    private func makeDefaults() -> UserDefaults {
        let name = "AutoResumeReadingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// A process that had `bookID`'s reader on screen (or none) when it was backgrounded.
    private func leaveApp(reading bookID: UUID?, closingFirst: Bool = false, defaults: UserDefaults) {
        let session = AutoResumeReading(defaults: defaults, notificationCenter: nil)
        if let bookID {
            session.readerAppeared(bookID: bookID)
            if closingFirst { session.readerDisappeared(bookID: bookID) }
        }
        session.appLeftForeground()
    }

    private func launch(isEnabled: Bool, defaults: UserDefaults, bookExists: Bool = true) -> AutoResumeReading {
        let session = AutoResumeReading(defaults: defaults, notificationCenter: nil)
        session.resumeAtLaunch(isEnabled: isEnabled, bookExists: { _ in bookExists })
        return session
    }

    @Test("leaving the app while reading reopens that book at the next launch")
    func reopensTheBookLeftOpen() {
        let defaults = makeDefaults()
        let book = UUID()
        leaveApp(reading: book, defaults: defaults)
        #expect(launch(isEnabled: true, defaults: defaults).request?.bookID == book)
    }

    @Test("closing the reader before leaving opens nothing")
    func staysOnTheLaunchScreenAfterClosingTheReader() {
        let defaults = makeDefaults()
        leaveApp(reading: UUID(), closingFirst: true, defaults: defaults)
        #expect(launch(isEnabled: true, defaults: defaults).request == nil)
    }

    @Test("the setting off opens nothing")
    func offOpensNothing() {
        let defaults = makeDefaults()
        leaveApp(reading: UUID(), defaults: defaults)
        #expect(launch(isEnabled: false, defaults: defaults).request == nil)
    }

    @Test("a book no longer in the library opens nothing")
    func deletedBookOpensNothing() {
        let defaults = makeDefaults()
        leaveApp(reading: UUID(), defaults: defaults)
        #expect(launch(isEnabled: true, defaults: defaults, bookExists: false).request == nil)
    }

    /// A book whose reader takes the app down as it opens must not hold every launch.
    @Test("a launch that never reaches the background is not resumed again")
    func aLaunchThatDiesIsNotRepeated() {
        let defaults = makeDefaults()
        let book = UUID()
        leaveApp(reading: book, defaults: defaults)
        let crashed = launch(isEnabled: true, defaults: defaults)
        crashed.readerAppeared(bookID: book)
        // It never left the foreground: the process died with the reader up.
        #expect(launch(isEnabled: true, defaults: defaults).request == nil)
    }

    @Test("closing a reader shown above another leaves the one underneath")
    func closingTheTopReaderKeepsTheOneUnderneath() {
        let defaults = makeDefaults()
        let under = UUID(), over = UUID()
        let session = AutoResumeReading(defaults: defaults, notificationCenter: nil)
        session.readerAppeared(bookID: under)
        session.readerAppeared(bookID: over)
        session.readerDisappeared(bookID: over)
        session.appLeftForeground()
        #expect(launch(isEnabled: true, defaults: defaults).request?.bookID == under)
    }

    @Test("a launch asks once, and another reader replacing the one that closed is the one kept")
    func asksOnceAndTracksTheReaderOnScreen() {
        let defaults = makeDefaults()
        let first = UUID(), second = UUID()
        let session = AutoResumeReading(defaults: defaults, notificationCenter: nil)
        session.readerAppeared(bookID: first)
        session.readerAppeared(bookID: second)
        session.readerDisappeared(bookID: first)
        session.appLeftForeground()
        let next = launch(isEnabled: true, defaults: defaults)
        #expect(next.request?.bookID == second)
        let requestID = next.request?.id
        next.resumeAtLaunch(isEnabled: true, bookExists: { _ in true })
        #expect(next.request?.id == requestID)
    }
}
