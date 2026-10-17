import Foundation

/// Why the reader could not open a book, worded for the person reading it.
///
/// `ReaderView` keeps one of these from the moment a local EPUB fails to open until the
/// next load starts, and `BookOpenFailureView` shows it. The error itself goes to the log
/// where it was caught: Readium's reasons are written for developers, not for readers.
struct BookOpenFailure: Equatable {
    let message: String

    init(error: Error) {
        if let remote = error as? RemoteLibraryError {
            // Already written for readers, in every language.
            message = remote.localizedDescription
        } else if case .fileNotFound? = error as? PublicationSessionError {
            message = localized("找不到這本書的檔案。")
        } else {
            // Readium's reasons, such as an archive with no central directory, all come to
            // this for the reader.
            message = localized("檔案可能已損毀，或不是支援的 EPUB 格式。")
        }
    }
}
