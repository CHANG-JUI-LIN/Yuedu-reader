import Foundation
import Testing
@testable import yuedu_app

@Suite("Reader resource ownership", .serialized)
@MainActor
struct ReadingResourceUsageTests {
    @Test("repeated appearance and multiple readers cannot release another owner's resource")
    func ownerLifetime() {
        let usage = ReadingResourceUsage()
        let book = UUID(), first = UUID(), second = UUID()
        usage.retain(bookID: book, ownerID: first)
        usage.retain(bookID: book, ownerID: first)
        usage.retain(bookID: book, ownerID: second)
        #expect(!usage.release(bookID: book, ownerID: first))
        #expect(usage.isInUse(bookID: book))
        #expect(!usage.release(bookID: book, ownerID: first))
        #expect(usage.isInUse(bookID: book))
        #expect(usage.release(bookID: book, ownerID: second))
        #expect(!usage.isInUse(bookID: book))
        #expect(!usage.release(bookID: book, ownerID: second))
    }
}
