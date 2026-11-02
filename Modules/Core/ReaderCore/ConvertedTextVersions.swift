import Foundation
import os

/// The text version of the EPUB this device reads each converted book from (MOBI plan,
/// "Positions across devices"), as `ConvertedBookRegenerator` read it from the EPUB's
/// manifest just before the book's reader opened. A converter version that changes a
/// chapter's text bumps it, and offsets saved against one text mean other words in another;
/// so from then on every reading position, bookmark and highlight saved for the book is
/// stamped with it, and a saved position stamped with another is not restored.
///
/// A cache of what the EPUB on disk says, filled per process. A book with no entry is
/// neither stamped nor checked: not converted, or not opened in a reader yet. MOBI books are
/// entered; Aozora books, converted the same way, are a follow-up.
final class ConvertedTextVersions: Sendable {
    static let shared = ConvertedTextVersions()

    /// What a MOBI book's record without a stamp indexes. Every build that converts MOBI
    /// stamps what its readers save, and the first text version is 1; only a save made
    /// outside a reader before one opened the book in this process goes unstamped.
    static let unstamped = 1

    private let versions = OSAllocatedUnfairLock<[String: Int]>(initialState: [:])

    func version(for bookId: String) -> Int? {
        versions.withLock { $0[bookId] }
    }

    func set(_ version: Int?, for bookId: String) {
        versions.withLock { $0[bookId] = version }
    }

    /// Whether a record stamped `stamp` (nil: unstamped) indexes the text this device reads
    /// the book from; always for a book with no entry.
    func indexesReadText(_ stamp: Int?, bookId: String) -> Bool {
        guard let version = version(for: bookId) else { return true }
        return (stamp ?? Self.unstamped) == version
    }
}
