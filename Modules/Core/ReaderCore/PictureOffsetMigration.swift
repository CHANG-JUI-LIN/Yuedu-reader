import Foundation
import YueduCoreText

/// Moves offsets saved before YueduCoreText 0.11 — when a picture had a place in a browser
/// chapter's source text but no extent — to 0.11's, where every picture takes one U+FFFC.
///
/// Nothing records which engine or version saved an offset, so each kind of record tells it
/// its own way:
/// - A bookmark carries its excerpt: the source text it was made from, starting at its
///   place. 0.10's never holds a U+FFFC; 0.11's keeps them, character for character (display
///   strips them). A bookmark moves only when its moved place reads the excerpt past the
///   pictures there, and its own place does not read it exactly; its excerpt then becomes the
///   source text at its new place, as a 0.11 excerpt is. Moving is so idempotent — an older
///   build that syncs back bookmarks it has not moved cannot make one move twice — and a
///   bookmark the legacy engine made, which reads at neither, stays. One case stays unresolved:
///   when no picture comes before a bookmark, both places start alike, and a picture inside it
///   past its excerpt's end leaves nothing to tell whether its length counts that picture.
/// - The reading position file is stamped by every save of a 0.11 build
///   (`ReadingPositionStore.countsPictures(for:)`); an unstamped one moves once, before the
///   reader restores it.
///
/// Offsets the legacy engine saved — a chapter it renders, or 整章翻譯 (`translationOffset`) —
/// have always counted every picture, and never move.
enum PictureOffsetMigration {
    /// The book's bookmarks with those in `spine` moved, or nil when none moves.
    static func moved(_ bookmarks: [Bookmark], spine: Int, sourceText: String,
                      pictures: BrowserPictureOffsets) -> [Bookmark]? {
        guard !pictures.offsets.isEmpty else { return nil }
        let text = sourceText as NSString
        var changed = false
        let result = bookmarks.map { bookmark -> Bookmark in
            guard bookmark.position.spineIndex == spine,
                  let moved = moved(bookmark, text: text, pictures: pictures) else { return bookmark }
            changed = true
            return moved
        }
        return changed ? result : nil
    }

    private static func moved(_ bookmark: Bookmark, text: NSString, pictures: BrowserPictureOffsets) -> Bookmark? {
        let position = bookmark.position
        // An empty excerpt cannot tell the two places apart. 0.10 wrote one for a page that
        // held only pictures — the page its place still names.
        guard position.translationOffset == nil, !bookmark.excerpt.isEmpty,
              position.charOffset >= 0, position.charOffset < text.length else { return nil }
        let saved = NSRange(location: position.charOffset, length: bookmark.length)
        let moved = pictures.migrated(saved)
        guard moved != saved,
              let span = spanPastPictures(bookmark.excerpt, at: moved.location, in: text),
              !reads(bookmark.excerpt, at: saved.location, in: text) else { return nil }
        // The excerpt becomes the source text it now starts, pictures and all, as a 0.11 excerpt
        // is: its place reads it exactly, so it never moves again. A highlight across a picture
        // keeps its start, and only its excerpt can tell that its length already counts it.
        return Bookmark(
            chapterIndex: bookmark.chapterIndex, chapterTitle: bookmark.chapterTitle,
            position: CoreTextReadingPosition(spineIndex: position.spineIndex, charOffset: moved.location),
            length: moved.length, kind: bookmark.kind, note: bookmark.note,
            excerpt: text.substring(with: NSRange(location: moved.location, length: span)),
            id: bookmark.id, date: bookmark.date,
            annotationStyle: bookmark.annotationStyle, annotationColor: bookmark.annotationColor
        )
    }

    /// Whether the source text at `offset` begins with `excerpt` exactly, pictures and all, as
    /// a 0.11 excerpt cut there does.
    private static func reads(_ excerpt: String, at offset: Int, in text: NSString) -> Bool {
        let length = (excerpt as NSString).length
        guard offset >= 0, offset + length <= text.length else { return false }
        return text.substring(with: NSRange(location: offset, length: length)) == excerpt
    }

    /// How much of the source text at `offset`, read past the pictures inside it, an excerpt
    /// cut from 0.10's source text, which had no picture characters, takes up; nil when it does
    /// not read there. A moved place never starts on a picture: `migrated` moves an offset past
    /// the pictures at its place.
    private static func spanPastPictures(_ excerpt: String, at offset: Int, in text: NSString) -> Int? {
        let expected = excerpt as NSString
        guard offset >= 0, expected.range(of: "\u{FFFC}").location == NSNotFound else { return nil }
        var source = offset
        var index = 0
        while index < expected.length {
            guard source < text.length else { return nil }
            let unit = text.character(at: source)
            if unit == expected.character(at: index) {
                index += 1
            } else if unit != 0xFFFC {
                return nil
            }
            source += 1
        }
        return source - offset
    }

    /// A reading position saved before 0.11, read against its chapter's pictures.
    ///
    /// A chapter's start stays its start: offset 0 is where a chapter opens (a table-of-contents
    /// jump, `chapterStart`), not the text after a picture the chapter begins with.
    static func moved(_ position: CoreTextReadingPosition, pictures: BrowserPictureOffsets) -> CoreTextReadingPosition {
        guard position.translationOffset == nil, position.charOffset > 0,
              position.charOffset != CoreTextReadingPosition.chapterEnd(position.spineIndex).charOffset else {
            return position
        }
        return CoreTextReadingPosition(spineIndex: position.spineIndex, charOffset: pictures.migrated(position.charOffset))
    }

    /// Moves a saved position the file does not stamp as 0.11's, once, and stamps it.
    /// `pictures` answers for a chapter the browser engine lays out, nil for the legacy
    /// engine's. Runs before the reader restores, as the TXT index migration does.
    /// - Returns: whether the saved position changed, so the reader reads it again.
    @MainActor
    static func migrateSavedPosition(
        bookId: String, positions: any ReadingPositionStore,
        pictures: @MainActor (_ spine: Int) async -> BrowserPictureOffsets?
    ) async -> Bool {
        guard let saved = positions.loadSync(for: bookId), !positions.countsPictures(for: bookId) else { return false }
        let start = SourcePerfTrace.now
        let moved: CoreTextReadingPosition
        if saved.translationOffset == nil, saved.charOffset > 0, let chapter = await pictures(saved.spineIndex) {
            moved = Self.moved(saved, pictures: chapter)
        } else {
            moved = saved
        }
        SourcePerfTrace.record("reader.pictureOffsets.position", "spine=\(saved.spineIndex)", since: start, thresholdMs: 0)
        // A save made meanwhile was a 0.11 build's, and stamped.
        guard positions.loadSync(for: bookId) == saved, !positions.countsPictures(for: bookId) else { return false }
        await positions.save(moved, for: bookId)
        AppLogger.cache("[PictureOffsets] position bookId=\(bookId) spine=\(saved.spineIndex) charOffset=\(saved.charOffset)→\(moved.charOffset)")
        return moved != saved
    }
}
