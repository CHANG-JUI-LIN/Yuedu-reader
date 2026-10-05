import Foundation

/// Maps UTF-16 offsets between an Aozora document's source text and its
/// displayed text (header, body and colophon blocks joined by "\n"; ruby
/// readings and annotations left out; gaiji, accents and くの字点 replaced).
///
/// The runs cover both texts in order and without gaps. A run either copies
/// its source (identity), or replaces it: markup deleted (displayed length 0),
/// a gaiji annotation shown as its character, "e'" shown as "é", a line break
/// standing in for an annotation, or text inserted where the source has none
/// (source length 0). Inside a replaced run every offset maps to the run's
/// start, so both directions are monotonic.
struct AozoraSourceMap: Equatable, Sendable {
    struct Run: Equatable, Sendable {
        var displayedStart: Int
        var sourceStart: Int
        var displayedLength: Int
        var sourceLength: Int
        /// The displayed text is the source text, unit for unit.
        var isIdentity: Bool
    }

    /// A stretch of displayed text and the source it stands for.
    struct Segment: Equatable, Sendable {
        var text: String
        var source: Range<Int>
    }

    let runs: [Run]
    let displayedLength: Int
    let sourceLength: Int

    /// Builds the map from displayed segments in source order. Source between
    /// segments is deleted markup.
    init(segments: [Segment], source: [UInt16]) {
        var runs: [Run] = []
        var displayed = 0
        var position = 0
        func append(_ run: Run) {
            if let last = runs.last, last.isIdentity, run.isIdentity,
               last.displayedStart + last.displayedLength == run.displayedStart,
               last.sourceStart + last.sourceLength == run.sourceStart {
                runs[runs.count - 1].displayedLength += run.displayedLength
                runs[runs.count - 1].sourceLength += run.sourceLength
            } else if run.displayedLength > 0 || run.sourceLength > 0 {
                runs.append(run)
            }
        }
        for segment in segments {
            let start = max(segment.source.lowerBound, position)
            let end = max(segment.source.upperBound, start)
            if start > position {
                append(Run(displayedStart: displayed, sourceStart: position, displayedLength: 0,
                           sourceLength: start - position, isIdentity: false))
            }
            let units = Array(segment.text.utf16)
            let isIdentity = start == segment.source.lowerBound && units.elementsEqual(source[start..<end])
            append(Run(displayedStart: displayed, sourceStart: start, displayedLength: units.count,
                       sourceLength: end - start, isIdentity: isIdentity))
            displayed += units.count
            position = end
        }
        if position < source.count {
            append(Run(displayedStart: displayed, sourceStart: position, displayedLength: 0,
                       sourceLength: source.count - position, isIdentity: false))
        }
        self.runs = runs
        self.displayedLength = displayed
        self.sourceLength = source.count
    }

    /// Where a source offset shows: its own place inside copied text, the start
    /// of what replaced it otherwise. Deleted markup maps to where the next
    /// displayed text begins.
    func displayedOffset(forSource offset: Int) -> Int {
        guard offset < sourceLength else { return displayedLength }
        guard offset > 0, let run = run(containing: offset, start: \.sourceStart, length: \.sourceLength) else {
            return 0
        }
        return run.isIdentity ? run.displayedStart + (offset - run.sourceStart) : run.displayedStart
    }

    /// Where a displayed offset comes from: its own place inside copied text,
    /// the start of the source a replacement stands for otherwise.
    func sourceOffset(forDisplayed offset: Int) -> Int {
        guard offset < displayedLength else { return sourceLength }
        guard offset > 0, let run = run(containing: offset, start: \.displayedStart, length: \.displayedLength) else {
            return runs.first(where: { $0.displayedLength > 0 })?.sourceStart ?? 0
        }
        return run.isIdentity ? run.sourceStart + (offset - run.displayedStart) : run.sourceStart
    }

    /// The run whose [start, start + length) holds `offset`; runs of length 0
    /// in that space hold nothing.
    private func run(containing offset: Int, start: KeyPath<Run, Int>, length: KeyPath<Run, Int>) -> Run? {
        var low = 0
        var high = runs.count - 1
        var found: Int?
        while low <= high {
            let middle = (low + high) / 2
            if runs[middle][keyPath: start] <= offset {
                found = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        // Several runs can share a start when the earlier ones are empty in
        // this space; the last of them is the one with length.
        guard var index = found else { return nil }
        while index >= 0 {
            let candidate = runs[index]
            if candidate[keyPath: length] > 0 {
                return offset < candidate[keyPath: start] + candidate[keyPath: length] ? candidate : nil
            }
            index -= 1
        }
        return nil
    }
}
