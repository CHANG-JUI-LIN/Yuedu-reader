import UIKit

final class EPUBBookService {
    static let shared = EPUBBookService()

    private init() {}

    func localURL(for book: ReadingBook, using store: BookStore) -> URL {
        store.localEPUBURL(for: book)
    }

    func openSession(for book: ReadingBook, using store: BookStore) async throws -> PublicationSession {
        let url = localURL(for: book, using: store)
        return try await PublicationSession.open(sourceURL: url)
    }

    func extractCoverImage(from sourceURL: URL) async -> UIImage? {
        await PublicationSession.extractCoverImage(sourceURL: sourceURL)
    }
}
