import Foundation

/// What the reader wants washed while something is being read aloud.
///
/// This used to be a bare `String?` that every render path searched for with
/// `NSString.range(of:)`, which returns the **first** occurrence. That is the wrong one
/// as soon as a chapter says `「嗯。」` twice, and 多角色朗讀 splits a chapter at quote
/// boundaries — so short repeated lines went from rare to ordinary and the wash started
/// landing on a line the listener was not hearing.
///
/// The text is still what identifies the words, because two of the four narration sources
/// do not share a coordinate space with the laid-out chapter. `expectedChapterOffset` is a
/// hint, not a replacement: when the reader could derive where the segment ought to be, the
/// search picks the occurrence nearest that offset; when it could not, every path behaves
/// exactly as it did before.
struct ReaderPlaybackHighlight: Equatable {
    /// The spoken words, trimmed. Never empty — the failable initialiser rejects that.
    let text: String
    /// Where the reader expects `text` to sit in chapter UTF-16 coordinates, or `nil` when
    /// the narration unit carried no usable mapping back to the chapter.
    let expectedChapterOffset: Int?
    /// The chapter being read, so a page from a different chapter can ignore the hint
    /// rather than measure distances between unrelated coordinate spaces.
    let chapterIndex: Int?

    init?(text: String?, expectedChapterOffset: Int? = nil, chapterIndex: Int? = nil) {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        self.text = trimmed
        self.expectedChapterOffset = expectedChapterOffset
        self.chapterIndex = chapterIndex
    }

    /// The chapter-space range to wash, searched inside `searchRange` of `haystack`.
    ///
    /// `haystack` is addressed in chapter coordinates, so `searchRange` is the slice the
    /// caller can actually draw (one page, one scroll chunk) and the returned range is
    /// already in the caller's own space.
    ///
    /// - Parameter chapterIndex: the chapter `haystack` belongs to, when the caller knows
    ///   it. A mismatch drops the hint instead of trusting an offset from another chapter.
    func occurrence(
        in haystack: NSString,
        searchRange: NSRange,
        chapterIndex: Int? = nil
    ) -> NSRange? {
        guard searchRange.location >= 0,
              searchRange.length > 0,
              NSMaxRange(searchRange) <= haystack.length
        else { return nil }

        let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let first = haystack.range(of: text, options: options, range: searchRange)
        guard first.location != NSNotFound, first.length > 0 else { return nil }

        let sameChapter = chapterIndex == nil || self.chapterIndex == nil
            || chapterIndex == self.chapterIndex
        guard let expected = expectedChapterOffset, sameChapter else { return first }

        // Matches come back in increasing order, so the distance to `expected` falls and
        // then rises. Stop at the turn rather than scanning the rest of the page.
        var best = first
        var bestDistance = abs(first.location - expected)
        var cursor = first.location + 1
        while cursor < NSMaxRange(searchRange) {
            let remaining = NSRange(location: cursor, length: NSMaxRange(searchRange) - cursor)
            let next = haystack.range(of: text, options: options, range: remaining)
            guard next.location != NSNotFound, next.length > 0 else { break }
            let distance = abs(next.location - expected)
            if distance >= bestDistance { break }
            best = next
            bestDistance = distance
            cursor = next.location + 1
        }
        return best
    }
}
