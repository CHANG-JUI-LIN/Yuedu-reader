import Foundation

/// Works out which spans of a narration unit are spoken by whom, so 多角色朗讀 can
/// give each character its own voice.
///
/// It asks `ReaderDialogueSegmentation` — the same code 對話氣泡 uses — rather than
/// running the bubble pass, which rewrites the attributed string and only applies
/// when that setting is on and the writing mode is horizontal. Reading a chapter
/// aloud must not depend on either.
///
/// The heuristic is deliberately conservative: it answers `nil` the moment the
/// narration stops looking like an attribution, and an unattributed line simply
/// keeps the narrator's voice.
enum TTSSpeakerAnnotator {

    /// A quoted run and who says it, in the narration unit's own UTF-16 coordinates.
    struct Attribution: Equatable {
        let range: NSRange
        /// `nil` when the line is quoted speech whose speaker could not be read off
        /// the surrounding narration.
        let speaker: String?
    }

    /// Quoted runs of `text`, in ascending order, each with its speaker if one
    /// could be determined. Narration is everything these ranges do not cover.
    ///
    /// - Parameter aliases: maps an alias to the canonical character name, so
    ///   `若塵` and `塵哥` resolve to the same voice as `張若塵`. Built from the AI
    ///   character roster; empty until that lands, in which case each written name
    ///   is its own speaker.
    static func attributions(in text: String, aliases: [String: String] = [:]) -> [Attribution] {
        let ns = text as NSString
        guard ns.length > 0 else { return [] }
        let dialogueRanges = DialogueHighlighter.dialogueRanges(in: ns)
        guard !dialogueRanges.isEmpty else { return [] }

        var result: [Attribution] = []
        ns.enumerateSubstrings(
            in: NSRange(location: 0, length: ns.length),
            options: [.byParagraphs]
        ) { _, paragraphRange, _, _ in
            guard paragraphRange.length > 0 else { return }
            let segments = ReaderDialogueSegmentation.segments(
                of: paragraphRange,
                dialogueRanges: dialogueRanges,
                in: ns,
                // Two quotes separated by nothing but punctuation are one person
                // continuing, so they stay one run and get one voice.
                mergesAdjacent: true
            )
            for (offset, segment) in segments.enumerated() where segment.isDialogue {
                let name = ReaderDialogueSegmentation.speaker(
                    forSegmentAt: offset,
                    in: segments,
                    ns: ns
                )
                result.append(Attribution(
                    range: segment.range,
                    speaker: name.map { aliases[$0] ?? $0 }
                ))
            }
        }
        return result.sorted { $0.range.location < $1.range.location }
    }

    /// The speaker covering `range`, if one quoted run contains it.
    ///
    /// Containment, not overlap: a segment that only partly covers a quoted run is
    /// part narration, so it keeps the narrator's voice rather than borrowing a
    /// character's. `splitting(_:at:protecting:)` normally removes those, but it
    /// leaves one behind whenever a quote edge sits inside a ruby base it may not
    /// cut — reading that stretch as narration is the harmless answer.
    static func speaker(for range: NSRange, in attributions: [Attribution]) -> String? {
        attributions.first {
            $0.range.location <= range.location && NSMaxRange(range) <= NSMaxRange($0.range)
        }?.speaker
    }

    /// Cuts `chunks` so no chunk straddles the edge of a quoted run, which is what
    /// lets one chunk carry one voice.
    ///
    /// - Parameter protected: ranges that must not be cut through — ruby bases,
    ///   whose reading is substituted whole. A quote boundary landing inside one is
    ///   rare, but cutting there would make the synthesizer speak the ruby twice.
    static func splitting(
        _ chunks: [TTSChunkRange],
        at attributions: [Attribution],
        protecting protected: [NSRange],
        in text: String
    ) -> [TTSChunkRange] {
        guard !attributions.isEmpty else { return chunks }
        let ns = text as NSString

        // Every quoted-run edge is a candidate cut point.
        var edges: Set<Int> = []
        for attribution in attributions {
            edges.insert(attribution.range.location)
            edges.insert(NSMaxRange(attribution.range))
        }

        var result: [TTSChunkRange] = []
        for chunk in chunks {
            let interior = edges
                .filter { $0 > chunk.sourceRange.location && $0 < NSMaxRange(chunk.sourceRange) }
                .filter { edge in
                    !protected.contains { $0.location < edge && edge < NSMaxRange($0) }
                }
                .sorted()
            guard !interior.isEmpty else {
                result.append(chunk)
                continue
            }

            var cursor = chunk.sourceRange.location
            for edge in interior + [NSMaxRange(chunk.sourceRange)] {
                let piece = NSRange(location: cursor, length: edge - cursor)
                cursor = edge
                guard piece.length > 0 else { continue }
                let body = ns.substring(with: piece)
                // A cut can leave a run of punctuation or spaces on its own. There
                // is nothing to speak there, and an empty utterance would still cost
                // a network request on the HTTP engine.
                guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                result.append(TTSChunkRange(text: body, sourceRange: piece))
            }
        }
        return result
    }
}
