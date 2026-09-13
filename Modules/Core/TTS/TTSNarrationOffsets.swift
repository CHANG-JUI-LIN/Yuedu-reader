import Foundation

/// Maps a position in narratable text back to the chapter string it was derived from.
///
/// `ReaderView.narratableText(from:)` deletes attachment markers, collapses runs of
/// spaces and blank lines, and trims — so a narration offset is **not** a chapter
/// offset, and the drift grows with every marker in the chapter. Playback highlight
/// used to sidestep this by searching the page for the spoken text, which picks the
/// wrong occurrence as soon as a line repeats (`「嗯。」`). Splitting segments per
/// speaker makes short repeated lines the common case, so the position has to be
/// derived rather than searched for.
///
/// The map is built by alignment rather than by rewriting `narratableText`: that
/// function is covered by tests describing exact behaviour, and re-deriving it as a
/// single pass would risk changing it. Alignment is possible because every narration
/// character still exists in the source in the same order — the transformation only
/// deletes characters or rewrites a whitespace run as a shorter one of the same kind.
struct TTSNarrationOffsetMap {
    /// `offsets[i]` is where narration UTF-16 offset `i` sits in the source string.
    /// One longer than the narration, so the end position maps too.
    private let offsets: [Int]

    private init(offsets: [Int]) {
        self.offsets = offsets
    }

    init(narration: String, source: String) {
        let narrationNS = narration as NSString
        let sourceNS = source as NSString
        var offsets: [Int] = []
        offsets.reserveCapacity(narrationNS.length + 1)

        var sourceIndex = 0
        for index in 0..<narrationNS.length {
            let character = narrationNS.character(at: index)
            // The source pointer only ever moves forward, so the whole alignment is
            // linear in the length of the chapter.
            while sourceIndex < sourceNS.length,
                  !Self.matches(narration: character, source: sourceNS.character(at: sourceIndex)) {
                sourceIndex += 1
            }
            offsets.append(min(sourceIndex, sourceNS.length))
            if sourceIndex < sourceNS.length { sourceIndex += 1 }
        }
        offsets.append(min(sourceIndex, sourceNS.length))
        self.offsets = offsets
    }

    /// Where `offset` in the narration sits in the source string. Out-of-range values
    /// clamp rather than trap: a caller working from a stale layout must land somewhere
    /// sane, not crash playback.
    func sourceOffset(forNarrationOffset offset: Int) -> Int {
        guard !offsets.isEmpty else { return 0 }
        return offsets[min(max(offset, 0), offsets.count - 1)]
    }

    /// The same map for a narration whose first `count` UTF-16 units have been dropped.
    ///
    /// Resuming mid-chapter hands the engine `narration[startCharOffset...]`, so every
    /// range the engine reports is short by that much. Re-aligning the slice against the
    /// chapter would be wrong, not just wasteful: alignment is greedy from the start of
    /// the source, so a slice would match its first occurrence rather than its real one.
    func droppingNarrationPrefix(_ count: Int) -> TTSNarrationOffsetMap {
        guard count > 0 else { return self }
        guard count < offsets.count else {
            // Nothing of the narration survives the slice; keep the end position so
            // conversions still clamp somewhere inside the chapter.
            return TTSNarrationOffsetMap(offsets: offsets.suffix(1).map { $0 })
        }
        return TTSNarrationOffsetMap(offsets: Array(offsets.dropFirst(count)))
    }

    /// The source range a narration range came from.
    func sourceRange(forNarrationRange range: NSRange) -> NSRange {
        let start = sourceOffset(forNarrationOffset: range.location)
        let end = sourceOffset(forNarrationOffset: NSMaxRange(range))
        return NSRange(location: start, length: max(0, end - start))
    }

    /// Whether a narration character may have come from this source character.
    ///
    /// Collapsing `[ \t]+` to a single space means a narration space can stand for a
    /// tab, so blanks match by class; everything else matches exactly. Deleted
    /// characters (`U+FFFC`, the surplus of a whitespace run, the trimmed ends) simply
    /// match nothing and are stepped over.
    private static func matches(narration: unichar, source: unichar) -> Bool {
        if narration == source { return true }
        let isBlank: (unichar) -> Bool = { $0 == 0x20 || $0 == 0x09 }
        return isBlank(narration) && isBlank(source)
    }
}
