import Foundation

/// What 全書搜尋 looks for: the words as typed, or a regular expression.
struct ReaderBookSearchQuery: Equatable, Sendable {
    let text: String
    let isRegex: Bool
}

/// Why a search stopped without results. Shown to the reader as is — never retried.
enum ReaderBookSearchError: Error, Equatable, Sendable {
    /// The regular expression does not compile.
    case invalidPattern
    /// The regular expression ran past `ReaderBookSearchMatcher.regexDeadline` on one chapter.
    case timedOut
    /// The book has no text to search on this device in any chapter (`localChapterText`
    /// reported every chapter `.unsupported`).
    case unsupported
}

/// One match, in its chapter's own text as searched: rules applied (or not, as asked) and
/// converted to the reader's 繁簡 setting, in UTF-16 units.
struct ReaderBookSearchHit: Identifiable, Hashable, Sendable {
    let chapterIndex: Int
    let range: NSRange
    /// Which match this is in its chapter, from 0. Finds it again in the laid-out text when
    /// the two texts cannot be aligned (`ReaderView.locateSearchHit`).
    let ordinal: Int
    let matchedText: String
    let snippet: ReaderBookSearchSnippet

    var id: String { "\(chapterIndex):\(range.location):\(range.length)" }
}

/// The match with a little of the text either side, on one line.
struct ReaderBookSearchSnippet: Hashable, Sendable {
    let leading: String
    let match: String
    let trailing: String
    /// The text goes on before `leading` / after `trailing`.
    let continuesBefore: Bool
    let continuesAfter: Bool
}

/// The matching itself: plain functions of a chapter's text, run off the main actor.
enum ReaderBookSearchMatcher {
    /// Characters of context kept on each side of a match.
    static let snippetContext = 20
    /// How long one chapter may take to match a regular expression. A pattern that
    /// backtracks catastrophically on a chapter would otherwise hold the search forever.
    static let regexDeadline: Duration = .seconds(2)

    /// Plain words match ignoring case and diacritics — the comparison the reader's highlight
    /// uses to find them on the page (`ReaderPlaybackHighlight.occurrence`).
    static let plainOptions: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// Every match of `query` in `text`, in order and not overlapping. Empty matches (a
    /// pattern like `a*`) are dropped: there is nothing to show or highlight.
    static func ranges(of query: ReaderBookSearchQuery, in text: String) throws(ReaderBookSearchError) -> [NSRange] {
        let string = text as NSString
        guard string.length > 0, !query.text.isEmpty else { return [] }
        guard query.isRegex else {
            var found: [NSRange] = []
            var location = 0
            while location < string.length {
                let range = string.range(of: query.text, options: plainOptions,
                                         range: NSRange(location: location, length: string.length - location))
                guard range.location != NSNotFound, range.length > 0 else { break }
                found.append(range)
                location = NSMaxRange(range)
            }
            return found
        }
        let expression: NSRegularExpression
        do {
            expression = try NSRegularExpression(pattern: query.text, options: [.caseInsensitive])
        } catch {
            throw .invalidPattern
        }
        let deadline = ContinuousClock.now + regexDeadline
        var found: [NSRange] = []
        var timedOut = false
        // `.reportProgress` calls back during a long match too, not only on each result,
        // so the deadline also stops a pattern that never produces one.
        expression.enumerateMatches(in: text, options: [.reportProgress],
                                    range: NSRange(location: 0, length: string.length)) { match, _, stop in
            if ContinuousClock.now >= deadline {
                timedOut = true
                stop.pointee = true
                return
            }
            if Task.isCancelled {
                stop.pointee = true
                return
            }
            guard let match, match.range.location != NSNotFound, match.range.length > 0 else { return }
            found.append(match.range)
        }
        if timedOut { throw .timedOut }
        return found
    }

    /// The chapter's hits, at most `limit`, with their snippets. Converts the text first, on
    /// the global executor, so a long chapter never blocks the main thread.
    @concurrent
    static func hits(
        of query: ReaderBookSearchQuery,
        chapterIndex: Int,
        text: String,
        conversion: TextConversion,
        limit: Int
    ) async throws(ReaderBookSearchError) -> [ReaderBookSearchHit] {
        let converted = text.converted(to: conversion)
        let found = try ranges(of: query, in: converted)
        let string = converted as NSString
        return found.prefix(limit).enumerated().compactMap { ordinal, range in
            guard let snippet = snippet(for: range, in: converted) else { return nil }
            return ReaderBookSearchHit(chapterIndex: chapterIndex, range: range, ordinal: ordinal,
                                       matchedText: string.substring(with: range), snippet: snippet)
        }
    }

    /// The match and `snippetContext` characters either side, cut on character boundaries so
    /// an emoji or a combining mark is never split, with line breaks folded into spaces.
    static func snippet(for range: NSRange, in text: String) -> ReaderBookSearchSnippet? {
        guard let match = Range(range, in: text) else { return nil }
        let start = text.index(match.lowerBound, offsetBy: -snippetContext, limitedBy: text.startIndex)
            ?? text.startIndex
        let end = text.index(match.upperBound, offsetBy: snippetContext, limitedBy: text.endIndex)
            ?? text.endIndex
        return ReaderBookSearchSnippet(
            leading: oneLine(text[start..<match.lowerBound]).trimmingPrefixWhitespace(),
            match: oneLine(text[match]),
            trailing: oneLine(text[match.upperBound..<end]).trimmingSuffixWhitespace(),
            continuesBefore: start > text.startIndex,
            continuesAfter: end < text.endIndex
        )
    }

    /// Where `hit` sits in the laid-out chapter, in its UTF-16 units — the space reading
    /// positions and the page highlight count in.
    ///
    /// The hit was found in `sourceText` (`localChapterText`); the page shows `laidOutText`
    /// (`laidOutChapterText`), which can add a rendered title and differ in whitespace. Both
    /// are compared converted, since a browser-laid-out EPUB chapter keeps its own script;
    /// conversion keeps every UTF-16 offset, so the result holds for the text as drawn.
    @concurrent
    static func locate(
        _ hit: ReaderBookSearchHit,
        query: ReaderBookSearchQuery,
        sourceText: String?,
        laidOutText: String,
        conversion: TextConversion
    ) async -> NSRange? {
        guard let sourceText else { return nil }
        let laidOut = laidOutText.converted(to: conversion)
        let source = sourceText.converted(to: conversion)
        if let mapped = AITextCoordinates.mappedRange(hit.range, from: source, to: laidOut) {
            return mapped
        }
        // Fallback: the same match by its ordinal among the matches in the laid-out text.
        // Taken when the alignment above has no map — the two texts differ beyond whitespace
        // and a title, as an EPUB chapter laid out with image placeholders, list markers or
        // ruby its plain text has not. Trusted only when both texts hold the same number of
        // matches: where they differ (替換規則 off in a chapter a rule changed) the n-th match
        // on the page is another sentence, and washing it would be a confident wrong answer.
        // Can go once search reads every chapter in laid-out coordinates.
        let inSource: [NSRange], onPage: [NSRange]
        do {
            inSource = try Self.ranges(of: query, in: source)
            onPage = try Self.ranges(of: query, in: laidOut)
        } catch {
            AppLogger.parse("全書搜尋 locate: re-matching chapter \(hit.chapterIndex) failed: \(error)")
            return nil
        }
        guard inSource.count == onPage.count, onPage.indices.contains(hit.ordinal) else {
            AppLogger.parse("全書搜尋 locate: chapter \(hit.chapterIndex) has \(inSource.count) matches in its text, \(onPage.count) on the page")
            return nil
        }
        return onPage[hit.ordinal]
    }

    private static func oneLine(_ text: Substring) -> String {
        String(text.map { $0.isNewline ? " " : $0 })
    }
}

private extension String {
    func trimmingPrefixWhitespace() -> String {
        String(drop { $0.isWhitespace })
    }

    func trimmingSuffixWhitespace() -> String {
        guard let last = lastIndex(where: { !$0.isWhitespace }) else { return "" }
        return String(self[...last])
    }
}
