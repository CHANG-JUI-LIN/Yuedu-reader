import UIKit

final class EPUBBookService {
    static let shared = EPUBBookService()

    private init() {}

    func localURL(for book: ReadingBook, using store: BookStore) -> URL {
        store.localEPUBURL(for: book)
    }

    @MainActor
    func openSession(for book: ReadingBook, using store: BookStore, remoteLibrary: any RemoteLibraryServing = RemoteLibraryService.shared) async throws -> PublicationSession {
        if book.remoteSource != nil {
            _ = try await remoteLibrary.prepare(bookID: book.id, store: store)
            guard let session = remoteLibrary.publication(bookID: book.id) else {
                throw RemoteLibraryError.missingBook
            }
            return session
        }
        let url = localURL(for: book, using: store)
        return try await PublicationSession.open(sourceURL: url)
    }

    func extractCoverImage(from sourceURL: URL) async -> UIImage? {
        await PublicationSession.extractCoverImage(sourceURL: sourceURL)
    }
}
