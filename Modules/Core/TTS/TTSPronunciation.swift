import YueduCoreText
import Foundation

struct TTSNarrationUnit {
    let text: String
    let pronunciationHints: [TTSPronunciationHint]
    /// Maps offsets in `text` back to the chapter string the reader lays out, so the
    /// playback highlight can be positioned rather than searched for.
    ///
    /// `nil` when the narration did not come from the laid-out chapter — the joined
    /// page text and the raw chapter content are fallbacks for paths the CoreText
    /// reader is not driving, and an offset derived from them would point somewhere
    /// arbitrary. Highlighting falls back to searching for the spoken text there.
    let sourceOffsets: TTSNarrationOffsetMap?

    init(
        text: String,
        pronunciationHints: [TTSPronunciationHint] = [],
        sourceOffsets: TTSNarrationOffsetMap? = nil
    ) {
        self.text = text
        self.pronunciationHints = pronunciationHints
        self.sourceOffsets = sourceOffsets
    }
}

struct TTSChunkRange: Equatable {
    let text: String
    let sourceRange: NSRange
}

/// One unit of speech, with everything the engines need about it in one value.
///
/// Both engines used to hold the text in `chunks: [String]` and everything else
/// in a second array indexed in parallel (`chunkPronunciationHints`,
/// `speechChunks`). Nothing enforced that the two stayed the same length, and a
/// per-speaker voice would have added a third. One array of segments removes the
/// whole class of index-desync bug instead of extending it.
struct TTSSpeakableSegment: Equatable {
    let text: String
    /// Where this segment came from in the narration unit, in UTF-16. Carried all
    /// the way to playback so the reader can highlight this exact span rather than
    /// searching for `text` — a short or repeated line (`「嗯。」`) matches the wrong
    /// occurrence when searched.
    let sourceRange: NSRange
    /// Who speaks it. `nil` for narration, and for quoted speech whose attribution
    /// the detector would not commit to.
    let speaker: String?
    /// Hints already rebased into this segment's own coordinates, so callers never
    /// re-project against the narration unit.
    let pronunciationHints: [TTSPronunciationHint]

    init(
        text: String,
        sourceRange: NSRange,
        speaker: String? = nil,
        pronunciationHints: [TTSPronunciationHint] = []
    ) {
        self.text = text
        self.sourceRange = sourceRange
        self.speaker = speaker
        self.pronunciationHints = pronunciationHints
    }
}

enum TTSPronunciationProjector {
    /// The single place a narration unit becomes the segments an engine plays.
    ///
    /// Chunking, hint projection and (later) speaker attribution all land here so
    /// that the two engines share one definition of "a segment" instead of each
    /// assembling its own parallel arrays.
    /// - Parameter multiRole: when set, quoted speech is attributed and chunks are
    ///   cut at every quote boundary so one chunk carries one voice. Off by default:
    ///   single-voice playback must keep the coarser paragraph chunks, which are
    ///   fewer, cheaper on the network engine, and gap-free on the system one.
    /// - Parameter aliases: alias → canonical character name, so the same person
    ///   under several names gets one voice.
    static func segments(
        _ text: String,
        targetLength: Int,
        hints: [TTSPronunciationHint],
        multiRole: Bool = false,
        aliases: [String: String] = [:]
    ) -> [TTSSpeakableSegment] {
        let attributions = multiRole
            ? TTSSpeakerAnnotator.attributions(in: text, aliases: aliases)
            : []
        var chunkRanges = chunks(text, targetLength: targetLength, hints: hints)
        if !attributions.isEmpty {
            chunkRanges = TTSSpeakerAnnotator.splitting(
                chunkRanges,
                at: attributions,
                protecting: hints.filter { $0.reading != nil }.map(\.range),
                in: text
            )
        }
        return chunkRanges.map { chunk in
            TTSSpeakableSegment(
                text: chunk.text,
                sourceRange: chunk.sourceRange,
                speaker: TTSSpeakerAnnotator.speaker(for: chunk.sourceRange, in: attributions),
                pronunciationHints: project(hints, into: chunk.sourceRange)
            )
        }
    }

    /// Keep an orthographic ruby base in one chunk, even when the ordinary
    /// length/punctuation boundary lands inside it.
    static func chunks(_ text: String, targetLength: Int, hints: [TTSPronunciationHint]) -> [TTSChunkRange] {
        let initial = TTSTextChunker.splitWithRanges(text, targetChunkLength: targetLength)
        var result: [TTSChunkRange] = []
        let source = text as NSString
        for chunk in initial {
            var range = chunk.sourceRange
            for hint in hints where hint.reading != nil && hint.range.location >= 0
                && NSMaxRange(hint.range) <= source.length
                && NSIntersectionRange(hint.range, chunk.sourceRange).length > 0 {
                range = NSUnionRange(range, hint.range)
            }
            if let previous = result.last, range.location < NSMaxRange(previous.sourceRange) {
                result.removeLast()
                range = NSUnionRange(previous.sourceRange, range)
                result.append(TTSChunkRange(text: source.substring(with: range), sourceRange: range))
            } else if range != chunk.sourceRange {
                result.append(TTSChunkRange(text: source.substring(with: range), sourceRange: range))
            } else { result.append(chunk) }
        }
        return result
    }

    static func project(
        _ hints: [TTSPronunciationHint],
        into chunkSourceRange: NSRange
    ) -> [TTSPronunciationHint] {
        hints.compactMap { hint in
            let intersection = NSIntersectionRange(hint.range, chunkSourceRange)
            guard intersection.length > 0 else { return nil }
            // An orthographic reading owns its complete base. A split must not
            // pronounce the complete ruby twice across neighbouring chunks.
            if hint.reading != nil, intersection != hint.range { return nil }
            return hint.rebased(to: NSRange(
                location: intersection.location - chunkSourceRange.location,
                length: intersection.length
            ))
        }
    }
}

enum TTSPronunciationAnnotator {
    static func hints(
        in text: String,
        authoredHints: [TTSPronunciationHint],
        lexicons: [PLSLexicon],
        bookLanguage: String?
    ) -> [TTSPronunciationHint] {
        let lexiconHints = hints(in: NSAttributedString(string: text), lexicons: lexicons, bookLanguage: bookLanguage)
        return (authoredHints + lexiconHints.filter { candidate in
            !authoredHints.contains { NSIntersectionRange($0.range, candidate.range).length > 0 }
        }).sorted { $0.range.location < $1.range.location }
    }

    static func hints(
        in attributedString: NSAttributedString,
        lexicons: [PLSLexicon],
        bookLanguage: String?
    ) -> [TTSPronunciationHint] {
        var hints = AuthoredPronunciation.hints(in: attributedString)
        var occupiedRanges = hints.map(\.range)

        let language = bookLanguage?.lowercased()
        let text = attributedString.string as NSString
        for lexicon in lexicons where lexicon.matches(language: language) {
            for lexeme in lexicon.lexemes where !lexeme.grapheme.isEmpty && !lexeme.phoneme.isEmpty {
                var searchRange = NSRange(location: 0, length: text.length)
                while searchRange.length > 0 {
                    let found = text.range(of: lexeme.grapheme, options: [], range: searchRange)
                    guard found.location != NSNotFound else { break }
                    if !occupiedRanges.contains(where: { NSIntersectionRange($0, found).length > 0 }) {
                        hints.append(TTSPronunciationHint(range: found, ipa: lexeme.phoneme))
                        occupiedRanges.append(found)
                    }
                    let nextLocation = found.location + max(found.length, 1)
                    let end = searchRange.location + searchRange.length
                    guard nextLocation < end else { break }
                    searchRange = NSRange(location: nextLocation, length: end - nextLocation)
                }
            }
        }

        return hints.sorted {
            if $0.range.location != $1.range.location {
                return $0.range.location < $1.range.location
            }
            return $0.range.length < $1.range.length
        }
    }
}

private extension PLSLexicon {
    func matches(language: String?) -> Bool {
        guard alphabet == nil || alphabet == "ipa" else { return false }
        guard let lexiconLanguage = self.language?.lowercased(), !lexiconLanguage.isEmpty else {
            return true
        }
        guard let language, !language.isEmpty else { return true }
        return language == lexiconLanguage
            || language.hasPrefix("\(lexiconLanguage)-")
            || lexiconLanguage.hasPrefix("\(language)-")
    }
}

/// Speech-only ruby substitution. Source text remains untouched for highlighting,
/// seek and persisted reading positions; synthesizer offsets map back to UTF-16.
struct TTSPronunciationSpeechText {
    let text: String
    let ipaHints: [TTSPronunciationHint]
    private let sourceOffsets: [Int]

    init(text: String, hints: [TTSPronunciationHint]) {
        let source = text as NSString
        var output = ""
        var offsets: [Int] = []
        var cursor = 0
        var replacements: [(source: NSRange, speech: NSRange)] = []
        for hint in hints.sorted(by: { $0.range.location < $1.range.location }) {
            guard let reading = hint.reading, !reading.isEmpty,
                  hint.range.location >= cursor, hint.range.length > 0,
                  NSMaxRange(hint.range) <= source.length else { continue }
            output += source.substring(with: NSRange(location: cursor, length: hint.range.location - cursor))
            offsets.append(contentsOf: cursor..<hint.range.location)
            let start = (output as NSString).length
            output += reading
            offsets.append(contentsOf: repeatElement(hint.range.location, count: (reading as NSString).length))
            replacements.append((hint.range, NSRange(location: start, length: (reading as NSString).length)))
            cursor = NSMaxRange(hint.range)
        }
        output += source.substring(from: cursor)
        offsets.append(contentsOf: cursor..<source.length)
        offsets.append(source.length)
        self.text = output
        self.sourceOffsets = offsets
        self.ipaHints = hints.compactMap { hint in
            guard hint.reading == nil, hint.range.length > 0,
                  hint.range.location >= 0, NSMaxRange(hint.range) <= source.length,
                  !replacements.contains(where: { NSIntersectionRange($0.source, hint.range).length > 0 }) else { return nil }
            let delta = replacements.filter { NSMaxRange($0.source) <= hint.range.location }
                .reduce(0) { $0 + $1.speech.length - $1.source.length }
            return hint.rebased(to: NSRange(location: hint.range.location + delta, length: hint.range.length))
        }
    }

    func sourceOffset(forSpeechOffset offset: Int) -> Int {
        sourceOffsets[min(max(0, offset), sourceOffsets.count - 1)]
    }
}
