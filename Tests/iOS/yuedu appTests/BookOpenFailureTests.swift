import Foundation
import Testing
@testable import yuedu_app

@Suite("Book open failure wording")
struct BookOpenFailureTests {
    @Test("A damaged EPUB reads as damaged, not as Readium's reason")
    func damagedArchive() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookOpenFailureTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("damaged.epub")
        // Not a ZIP archive at all, as a cut-off download or a corrupted copy leaves it.
        try Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }).write(to: file)

        let error = await openError(file, cacheDirectory: directory.appendingPathComponent("cache"))

        #expect(BookOpenFailure(error: error).message == localized("檔案可能已損毀，或不是支援的 EPUB 格式。"))
    }

    @Test("A book whose file is gone says so")
    func missingFile() async {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookOpenFailureTests-missing-\(UUID().uuidString).epub")

        let error = await openError(file, cacheDirectory: nil)

        #expect(BookOpenFailure(error: error).message == localized("找不到這本書的檔案。"))
    }

    @Test("A remote library's own message is kept")
    func remoteLibraryMessage() {
        let error = RemoteLibraryError.offlineContentMissing

        #expect(BookOpenFailure(error: error).message == error.localizedDescription)
    }

    private func openError(_ file: URL, cacheDirectory: URL?) async -> Error {
        do {
            _ = try await PublicationSession.open(sourceURL: file, cacheDirectory: cacheDirectory)
            Issue.record("Opening \(file.lastPathComponent) succeeded")
            return CancellationError()
        } catch {
            return error
        }
    }
}
