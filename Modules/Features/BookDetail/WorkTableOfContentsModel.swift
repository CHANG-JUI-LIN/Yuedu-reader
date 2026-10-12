import Combine
import Foundation

/// 作品詳情's 目錄 for the version shown: its reading copy's chapters (`WorkTableOfContents`).
@MainActor
final class WorkTableOfContentsModel: ObservableObject {
    enum State: Equatable {
        /// No 目錄: a version read on its source's page, or a copy with no chapters to list.
        case none
        case loading
        /// `bookID` is the copy the chapters open in.
        case loaded(bookID: UUID, chapters: [OnlineChapterRef])
        case failed(String)
    }

    @Published private(set) var state: State = .none
    /// The latest load: one the version has since moved on from never sets the state.
    private var generation = UUID()

    /// Reads the chapters of the copy `copy` gives; with no copy, the version has no 目錄.
    func load(copy: (() async throws -> ReadingBook)?, store: BookStore, remoteLibrary: any RemoteLibraryServing,
              positions: any ReadingPositionStore) async {
        let generation = UUID()
        self.generation = generation
        guard let copy else {
            state = .none
            return
        }
        state = .loading
        let result: State
        do {
            let book = try await copy()
            let chapters = try await WorkTableOfContents.chapters(of: book, store: store, remoteLibrary: remoteLibrary,
                                                                  positions: positions)
            result = chapters.map { .loaded(bookID: book.id, chapters: $0) } ?? .none
        } catch is CancellationError {
            // The version changed or the page went: the next load, if any, sets the state.
            return
        } catch {
            AppLogger.network("Work TOC failed", error: SourceFailure.loggable(error))
            result = .failed(error.localizedDescription)
        }
        guard self.generation == generation, !Task.isCancelled else { return }
        state = result
    }
}
