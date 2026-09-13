import Foundation

/// Finds every character who speaks in a book, ranked by how much they speak.
///
/// Character cards are a **book-level** thing — who someone is does not change between
/// chapters — so scanning only the chapter being listened to was wrong twice over: it hid
/// everyone who had not spoken recently, and it made the list change under the reader as
/// playback moved on.
///
/// Ranking by line count also does the noise filtering for free. The dialogue heuristic
/// occasionally reads a manner adverb or a fragment as a name; those appear once or twice
/// across a whole book, while a real character appears constantly.
enum AIBookSpeakerScan {

    struct Speaker: Identifiable, Equatable, Sendable {
        var id: String { name }
        let name: String
        /// How many attributed lines this speaker has in the book.
        let lineCount: Int
        /// Prose around the first attribution, so the model can judge the candidate in
        /// context rather than from the bare word.
        let sample: String

        init(name: String, lineCount: Int, sample: String = "") {
            self.name = name
            self.lineCount = lineCount
            self.sample = sample
        }
    }

    /// Speakers with at least this many attributed lines are offered first. Below it a name
    /// is far more likely to be a misread than a character.
    static let confidentLineCount = 3

    /// - Parameter aliases: alias → canonical name, so a character already known under
    ///   several names is counted once.
    static func scan(
        sections: [AIChunkableSection],
        aliases: [String: String] = [:]
    ) -> [Speaker] {
        var counts: [String: Int] = [:]
        var samples: [String: String] = [:]
        for section in sections where !section.text.isEmpty {
            let text = section.text as NSString
            for attribution in TTSSpeakerAnnotator.attributions(in: section.text, aliases: aliases) {
                guard let speaker = attribution.speaker else { continue }
                counts[speaker, default: 0] += 1
                if samples[speaker] == nil {
                    samples[speaker] = excerpt(around: attribution.range, in: text)
                }
            }
        }
        return counts
            .map { Speaker(name: $0.key, lineCount: $0.value, sample: samples[$0.key] ?? "") }
            .sorted {
                if $0.lineCount != $1.lineCount { return $0.lineCount > $1.lineCount }
                return $0.name < $1.name
            }
    }

    /// One line of prose around an attribution, for the model to judge the candidate in
    /// context. 一邊 alone could be a name; `他一邊道：「…」` obviously is not.
    static let sampleLength = 40

    private static func excerpt(around range: NSRange, in text: NSString) -> String {
        let start = max(0, range.location - sampleLength / 2)
        let end = min(text.length, NSMaxRange(range) + sampleLength)
        guard end > start else { return "" }
        return text.substring(with: NSRange(location: start, length: end - start))
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
