import Foundation

/// A book converted from a MOBI or AZW3 file (`ReadingBook.mobi`). The converter's
/// version is not here but in the EPUB's own `yuedu-mobi.json`, for the reason
/// `ReadingBook.aozora` gives.
struct MOBIBookSource: Codable, Equatable, Sendable {
    /// The original, in the book files' folder next to the EPUB. Nil for a remote
    /// library's book, whose remote file is the original.
    var originalFilename: String?
    /// Which of the file's books was converted: a combination file holds both.
    var kind: MOBIFile.Kind

    init(originalFilename: String?, kind: MOBIFile.Kind) {
        self.originalFilename = originalFilename
        self.kind = kind
    }

    /// The 格式 chip's label: the format the reader brought, not the EPUB it reads.
    var formatLabel: String {
        switch kind {
        case .kf8: "AZW3"
        case .mobi6: "MOBI"
        }
    }
}
