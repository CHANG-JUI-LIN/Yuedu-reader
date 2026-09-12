import Foundation

/// Splits a paragraph into alternating narration / speech runs, and works out who
/// speaks each quoted run.
///
/// This was private to `ReaderDialogueBubbleMarker`. 多角色朗讀 needs exactly the
/// same answer, but must not go through the bubble pass to get it: that pass
/// inserts paragraph breaks into the attributed string, and only runs when 對話氣泡
/// is switched on and the writing mode is horizontal. None of those should decide
/// how a chapter is read aloud, so the shared half moved here and both callers ask
/// the same code rather than keeping two drifting copies of the heuristic.
enum ReaderDialogueSegmentation {

    /// One run of a paragraph: either narration or a quoted utterance.
    struct Segment: Equatable {
        let range: NSRange
        let isDialogue: Bool
    }

    /// Characters allowed to sit between two quoted spans and still leave them
    /// one run (`「甲」，「乙」`).
    static let connectors = CharacterSet(charactersIn: "，。！？、；：…—－-·　 \t\u{3000}")
        .union(.whitespacesAndNewlines)

    /// Punctuation that leaves a sentence open.
    private static let continuations: Set<Character> = ["，", ",", "、", "；", ";", "：", ":"]

    // MARK: - Segmentation

    /// Splits one paragraph into alternating narration / speech runs.
    ///
    /// Narration that is only whitespace is dropped rather than becoming an empty
    /// run, and two quotes separated by nothing but punctuation merge into a single
    /// run when `mergesAdjacent` is set.
    static func segments(
        of paragraphRange: NSRange,
        dialogueRanges: [NSRange],
        in ns: NSString,
        mergesAdjacent: Bool
    ) -> [Segment] {
        let spans = dialogueRanges
            .filter {
                $0.location >= paragraphRange.location
                    && NSMaxRange($0) <= NSMaxRange(paragraphRange)
            }
            .sorted { $0.location < $1.location }
        guard !spans.isEmpty else { return [] }

        var merged: [NSRange] = []
        for span in spans {
            if mergesAdjacent, let last = merged.last {
                let gap = NSRange(
                    location: NSMaxRange(last),
                    length: span.location - NSMaxRange(last)
                )
                if gap.length >= 0, isConnective(ns.substring(with: gap)) {
                    merged[merged.count - 1] = NSUnionRange(last, span)
                    continue
                }
            }
            merged.append(span)
        }

        var result: [Segment] = []
        var cursor = paragraphRange.location
        for span in merged {
            if span.location > cursor {
                let narration = NSRange(
                    location: cursor,
                    length: span.location - cursor
                )
                if !isBlank(narration, in: ns) {
                    result.append(Segment(range: narration, isDialogue: false))
                }
            }
            result.append(Segment(range: span, isDialogue: true))
            cursor = NSMaxRange(span)
        }
        if cursor < NSMaxRange(paragraphRange) {
            let tail = NSRange(
                location: cursor,
                length: NSMaxRange(paragraphRange) - cursor
            )
            if !isBlank(tail, in: ns) {
                result.append(Segment(range: tail, isDialogue: false))
            }
        }
        return result
    }

    // MARK: - Attribution

    /// Who speaks the segment at `offset`, or `nil` when the narration around it
    /// stops looking like an attribution.
    ///
    /// Callers pass the index of a dialogue segment; a narration segment has no
    /// speaker and always answers `nil`.
    static func speaker(
        forSegmentAt offset: Int,
        in segments: [Segment],
        ns: NSString
    ) -> String? {
        guard segments.indices.contains(offset), segments[offset].isDialogue else {
            return nil
        }
        let sharedBeat = isSharedBeat(before: offset, in: segments, ns: ns)
        return ReaderDialogueSpeakerDetector.speaker(
            before: narration(
                before: offset,
                in: segments,
                ns: ns,
                includingSharedBeat: sharedBeat
            ),
            after: narration(after: offset, in: segments, ns: ns),
            beforeIsSharedBeat: sharedBeat,
            afterIsSharedBeat: isSharedBeat(before: offset + 2, in: segments, ns: ns)
        )
    }

    /// True when the narration before this segment sits between two quotes of the
    /// same paragraph *and* does not end a sentence — one speech interrupted by its
    /// own attribution (`「甲，」齊源老道面露無奈，「乙。」`). Both halves belong to
    /// that speaker.
    ///
    /// The trailing punctuation is what separates that from two people taking turns
    /// (`「甲。」張三道。「乙。」李四道。`), where the beat closes with a full stop and
    /// belongs only to the quote before it.
    static func isSharedBeat(
        before offset: Int,
        in segments: [Segment],
        ns: NSString
    ) -> Bool {
        // Called for the segment *after* the beat as well, so the index can run
        // past the end — both bounds have to be checked, not just the lower one.
        guard offset >= 2, offset - 1 < segments.count,
              !segments[offset - 1].isDialogue,
              segments[offset - 2].isDialogue else {
            return false
        }
        let beat = ns.substring(with: segments[offset - 1].range)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = beat.last else { return false }
        return continuations.contains(last)
    }

    // MARK: - Narration around a quote

    private static func narration(
        before offset: Int,
        in segments: [Segment],
        ns: NSString,
        includingSharedBeat: Bool
    ) -> String {
        guard offset > 0, !segments[offset - 1].isDialogue else { return "" }
        // A beat between two quotes attributes both of them, but only as a beat:
        // read as a plain lead-in it would hand the previous speaker's *verb* to
        // this line (`「甲。」張三道。「乙。」李四道。` must not make 張三 say 乙).
        if offset >= 2, segments[offset - 2].isDialogue, !includingSharedBeat {
            return ""
        }
        return ns.substring(with: segments[offset - 1].range)
    }

    private static func narration(
        after offset: Int,
        in segments: [Segment],
        ns: NSString
    ) -> String {
        let next = offset + 1
        guard next < segments.count, !segments[next].isDialogue else { return "" }
        return ns.substring(with: segments[next].range)
    }

    private static func isBlank(_ range: NSRange, in ns: NSString) -> Bool {
        ns.substring(with: range)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    private static func isConnective(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy(connectors.contains)
    }
}
